/// Uploads session files and JSON documents to S3.
///
/// The service maps captured sessions to S3 object keys, obtains temporary AWS
/// credentials through Cognito, and uploads images and JSON with presigned S3
/// PUT URLs. In guest mode only, uploads are sent to a public bucket through
/// explicit unauthenticated code paths.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/captured_session.dart';
import '../models/site.dart';
import '../models/telemetry_event.dart';
import '../models/telemetry_pivots.dart';
import '../services/local_session_storage.dart';
import '../services/auth_service.dart';
import '../services/s3_signer_service.dart';
import '../services/telemetry_service.dart';
import '../config/app_config.dart';
import '../exceptions/auth_exceptions.dart';
import '../utils/log.dart';
import '../utils/file_bytes.dart';

/// Fine-grained phases within a single session upload.
enum UploadPhase { portrait, landscape, sessionJson }

/// Number of phases per session (portrait, landscape, sessionJson).
/// Update this if phases are added/removed in the future.
const int numPhasesPerSession = 3;

/// Indicates that a conditional S3 write failed because the remote object changed.
class ConditionalWriteConflictException implements Exception {
  /// Creates a conditional write conflict for [s3Key].
  const ConditionalWriteConflictException({required this.s3Key, this.etag});

  /// The S3 object key that rejected the conditional write.
  final String s3Key;

  /// The ETag used in the failed `If-Match` request.
  final String? etag;

  @override
  String toString() {
    return 'ConditionalWriteConflictException(s3Key: $s3Key, etag: $etag)';
  }
}

/// Uploads captured session artifacts to S3.
class UploadService {
  // UploadService is a singleton
  UploadService._privateConstructor();
  static final UploadService instance = UploadService._privateConstructor();

  AuthService authService = AuthService.instance;
  final S3SignerService _s3SignerService = S3SignerService.instance;
  String get _region => AppConfig.region;

  /// Uploads every un-uploaded session in [sites] order.
  ///
  /// The [sites] argument provides the canonical site metadata used to derive
  /// bucket roots and object keys. The [onProgress], [onPhaseProgress], and
  /// [onSessionError] callbacks are optional UI hooks.
  ///
  /// Returns when all sessions and telemetry flushes have completed.
  ///
  /// Throws an [Exception] if one or more sessions failed to upload.
  Future<void> uploadAllSessions({
    required List<Site> sites,
    required VoidCallback? onProgress,
    void Function(CapturedSession session, UploadPhase phase)? onPhaseProgress,
    void Function(CapturedSession session, Object error)? onSessionError,
  }) async {
    final sessions = await LocalSessionStorage.loadAllSessions();
    final unuploaded = sessions.where((s) => !s.isUploaded);

    final List<String> errors = [];

    for (final session in unuploaded) {
      try {
        await _uploadSession(session, sites, onPhaseProgress);
        // Persist full session state including uploaded image URLs so that
        // SiteSyncService can later use them to build ghost images.
        await LocalSessionStorage.markUploadedWithUrls(session);
        onProgress?.call();
        TelemetryService.instance.log(
          TelemetryLevel.info,
          TelemetryPivot.sessionUploaded,
          'Session uploaded from ${session.siteId}',
          context: {'siteId': session.siteId, 'sessionId': session.sessionId},
        );
      } catch (e) {
        if (onSessionError != null) {
          onSessionError(session, e);
        }
        final errorMessage =
            "Failed to upload session ${session.sessionId}: $e";
        dLog("upload_service: $errorMessage");
        errors.add(errorMessage);
        // AuthSessionExpiredException means the Cognito token could not be
        // refreshed — distinct from a generic upload failure.
        if (e is AuthSessionExpiredException) {
          TelemetryService.instance.log(
            TelemetryLevel.warning,
            TelemetryPivot.tokenRefreshFailed,
            'Session expired during upload for ${session.siteId}',
            error: e,
            context: {'siteId': session.siteId, 'sessionId': session.sessionId},
          );
        } else {
          TelemetryService.instance.log(
            TelemetryLevel.error,
            TelemetryPivot.sessionUploadFailed,
            'Session upload failed for ${session.siteId}',
            error: e,
            context: {'siteId': session.siteId, 'sessionId': session.sessionId},
          );
        }
        // Continue with next session instead of stopping
      }
    }

    // Flush telemetry buffer to S3, piggybacking on this upload moment.
    // Derive userId from first session; fall back to 'unknown' if no sessions.
    // flush() handles its own errors internally and never throws.
    final flushUserId = sessions.isNotEmpty ? sessions.first.userId : 'unknown';
    final flushOrg = AppConfig.org ?? 'unknown';
    await TelemetryService.instance.flush(
      flushUserId,
      flushOrg,
      TelemetryService.currentPlatform,
    );

    // If there were any errors, throw a combined error
    if (errors.isNotEmpty) {
      throw Exception("Upload completed with errors:\n${errors.join('\n')}");
    }
  }

  /// Uploads a single [session] using metadata from [sites].
  ///
  /// The [onPhaseProgress] callback, when provided, is invoked after each
  /// portrait, landscape, and session-JSON upload phase.
  ///
  /// Returns the uploaded session JSON URL.
  ///
  /// Throws an [Exception] if any phase fails.
  Future<String> _uploadSession(
    CapturedSession session,
    List<Site> sites,
    void Function(CapturedSession session, UploadPhase phase)? onPhaseProgress,
  ) async {
    Site? site;
    try {
      site = sites.firstWhere((s) => s.id == session.siteId);
    } catch (e) {
      dLog(
        "upload_service: Site with ID '${session.siteId}' not found, creating fallback site",
      );
      site = LocalSessionStorage.createSiteForSession(session, sites.first);
    }

    dLog(
      "upload_service: found site: ${site.id}, bucketRoot: ${site.bucketRoot}",
    );

    final timestampStr = _sanitizeTimestamp(session.timestamp);
    final portraitRemotePath =
        '${site.id}/${session.userId}_${timestampStr}_portrait.jpg';
    final landscapeRemotePath =
        '${site.id}/${session.userId}_${timestampStr}_landscape.jpg';

    final portraitUrl = await uploadFile(
      session.portraitImagePath,
      site.bucketRoot,
      portraitRemotePath,
    );
    onPhaseProgress?.call(session, UploadPhase.portrait);

    final landscapeUrl = await uploadFile(
      session.landscapeImagePath,
      site.bucketRoot,
      landscapeRemotePath,
    );
    onPhaseProgress?.call(session, UploadPhase.landscape);

    session.portraitImageUrl = portraitUrl;
    session.landscapeImageUrl = landscapeUrl;

    final sessionJsonPath = 'sessions/${session.userId}_$timestampStr.json';
    final sessionUrl = await uploadJson(
      session.toJson(),
      site.bucketRoot,
      sessionJsonPath,
    );
    onPhaseProgress?.call(session, UploadPhase.sessionJson);
    dLog(
      'upload_service: Session URL: $sessionUrl, portrait: $portraitUrl, landscape: $landscapeUrl',
    );
    return sessionUrl;
  }

  /// Uploads the local file at [localPath] to [bucketRoot]/[remotePath].
  ///
  /// In guest mode, the file is uploaded through the explicit unauthenticated
  /// code path. In authenticated mode, the upload always uses Cognito-backed
  /// credentials and never falls back to an unauthenticated write.
  ///
  /// Returns the final non-presigned object URL.
  ///
  /// Throws an [Exception] if validation, signing, or upload fails.
  Future<String> uploadFile(
    String localPath,
    String bucketRoot,
    String remotePath,
  ) async {
    if (!_isValidLocalPath(localPath) ||
        !_isValidPath(bucketRoot) ||
        !_isValidPath(remotePath)) {
      return '';
    }

    // Strip query/fragment from bucket root so stored URLs never contain ?#
    final cleanRoot = _stripQueryAndFragment(bucketRoot);
    final fullUrl = _joinUrls(cleanRoot, remotePath);
    dLog("upload_service: constructed fullUrl: $fullUrl");

    if (AppConfig.isGuestMode) {
      return await _uploadFileNoAuth(localPath, fullUrl);
    }
    return await _uploadFileAuth(localPath, fullUrl);
  }

  /// Uploads [localPath] to [fullUrl] with authenticated S3 access.
  ///
  /// Returns the final non-presigned object URL.
  ///
  /// Throws an [AuthSessionExpiredException], [AuthCredentialsException], or
  /// other [Exception] if signing or upload fails.
  Future<String> _uploadFileAuth(String localPath, String fullUrl) async {
    final credentials = await authService.getUploadCredentials();
    final parsed = _parseS3Url(fullUrl);
    final bucket = parsed['bucket']!;
    final key = parsed['key']!;
    final bytes = await readFileBytes(localPath);
    final contentType = _getContentType(localPath);

    final presignedUrl = await _s3SignerService.createPresignedPutUrl(
      bucketName: bucket,
      s3Key: key,
      credentials: credentials,
      contentType: contentType,
    );

    dLog("upload_service: uploading authenticated file to presigned URL");
    final response = await http.put(
      Uri.parse(presignedUrl),
      headers: {'Content-Type': contentType},
      body: bytes,
    );

    if (response.statusCode == 200) {
      dLog(
        'upload_service: Successfully uploaded $localPath using presigned URL',
      );
      return fullUrl;
    }

    dLog('upload_service: Upload failed with status ${response.statusCode}');
    dLog('upload_service: Response body: ${response.body}');
    dLog('upload_service: Response headers: ${response.headers}');
    throw Exception('File upload failed: ${response.statusCode}');
  }

  /// Uploads [jsonData] to [bucketRoot]/[remotePath].
  ///
  /// When [ifMatch] is provided, the remote object is updated only if its ETag
  /// still matches [ifMatch]. In guest mode, conditional writes are rejected
  /// because guest uploads are intentionally unauthenticated and best effort.
  ///
  /// Returns the final non-presigned object URL.
  ///
  /// Throws a [ConditionalWriteConflictException] when the `If-Match`
  /// precondition fails, or another [Exception] if signing or upload fails.
  Future<String> uploadJson(
    Map<String, dynamic> jsonData,
    String bucketRoot,
    String remotePath, {
    String? ifMatch,
  }) async {
    final fullUrl = _joinUrls(bucketRoot, remotePath);

    if (AppConfig.isGuestMode) {
      if (ifMatch != null) {
        throw Exception(
          'Conditional writes are not supported in guest mode for $remotePath',
        );
      }
      return await _uploadJsonNoAuth(jsonData, fullUrl);
    }
    return await _uploadJsonAuth(jsonData, fullUrl, ifMatch: ifMatch);
  }

  /// Uploads [jsonData] to [fullUrl] with authenticated S3 access.
  ///
  /// When [ifMatch] is provided, the remote object is updated only if its ETag
  /// still matches [ifMatch].
  ///
  /// Returns the final non-presigned object URL.
  ///
  /// Throws a [ConditionalWriteConflictException] when the `If-Match`
  /// precondition fails, or another [Exception] if signing or upload fails.
  Future<String> _uploadJsonAuth(
    Map<String, dynamic> jsonData,
    String fullUrl, {
    String? ifMatch,
  }) async {
    final credentials = await authService.getUploadCredentials();
    final parsed = _parseS3Url(fullUrl);
    final bucket = parsed['bucket']!;
    final key = parsed['key']!;

    final jsonString = jsonEncode(jsonData);
    final jsonBytes = const Utf8Codec().encode(jsonString);
    final signedHeaders =
        ifMatch == null ? const <String, String>{} : {'if-match': ifMatch};

    final presignedUrl = await _s3SignerService.createPresignedJsonPutUrl(
      bucketName: bucket,
      s3Key: key,
      credentials: credentials,
      signedHeaders: signedHeaders,
    );

    final response = await http.put(
      Uri.parse(presignedUrl),
      headers: {
        'Content-Type': 'application/json',
        if (ifMatch != null) 'If-Match': ifMatch,
      },
      body: jsonBytes,
    );

    if (response.statusCode == 200) {
      dLog('upload_service: Successfully uploaded JSON using presigned URL');
      return fullUrl;
    }

    if (response.statusCode == 412) {
      throw ConditionalWriteConflictException(s3Key: key, etag: ifMatch);
    }

    throw Exception('JSON upload failed: ${response.statusCode}');
  }

  /// Uploads [localPath] to [fullUrl] without authentication.
  ///
  /// This code path is reserved for explicit guest-mode uploads only.
  ///
  /// Returns the final object URL.
  ///
  /// Throws an [Exception] if the upload fails.
  Future<String> _uploadFileNoAuth(String localPath, String fullUrl) async {
    dLog("upload_service: uploading NOAUTH FILE to $fullUrl");
    final bytes = await readFileBytes(localPath);
    final contentType = _getContentType(localPath);

    final response = await http.put(
      Uri.parse(fullUrl),
      headers: {'Content-Type': contentType},
      body: bytes,
    );

    if (response.statusCode == 200) {
      return fullUrl;
    } else {
      dLog("upload_service: Upload failed with status ${response.statusCode}");
      dLog("upload_service: Response body: ${response.body}");
      throw Exception('File upload failed: ${response.statusCode}');
    }
  }

  /// Uploads [jsonData] to [fullUrl] without authentication.
  ///
  /// This code path is reserved for explicit guest-mode uploads only.
  ///
  /// Returns the final object URL.
  ///
  /// Throws an [Exception] if the upload fails.
  Future<String> _uploadJsonNoAuth(
    Map<String, dynamic> jsonData,
    String fullUrl,
  ) async {
    dLog("upload_service: uploading NOAUTH JSON to $fullUrl");
    final jsonString = jsonEncode(jsonData);
    final response = await http.put(
      Uri.parse(fullUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonString,
    );

    if (response.statusCode == 200) {
      return fullUrl;
    } else {
      throw Exception('JSON upload failed: ${response.statusCode}');
    }
  }

  /// Returns the HTTP content type for [filePath].
  ///
  /// Returns `application/octet-stream` for unknown extensions.
  String _getContentType(String filePath) {
    final extension = filePath.split('.').last.toLowerCase();
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'json':
        return 'application/json';
      default:
        return 'application/octet-stream';
    }
  }

  /// Parses the bucket and object key from [fullUrl].
  ///
  /// Returns a map containing the bucket, key, and region.
  ///
  /// Throws a [FormatException] if [fullUrl] is not a valid URL.
  Map<String, String> _parseS3Url(String fullUrl) {
    final uri = Uri.parse(fullUrl);
    final hostParts = uri.host.split('.');
    final bucket = hostParts.first;
    final key = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
    return {'bucket': bucket, 'key': key, 'region': _region};
  }

  /// Removes query and fragment components from [url].
  ///
  /// Returns the normalized URL string.
  String _stripQueryAndFragment(String url) {
    return url.split('#').first.split('?').first;
  }

  /// Joins [baseUrl] and [path] into a normalized URL.
  ///
  /// Returns the combined URL with exactly one slash at the join point.
  String _joinUrls(String baseUrl, String path) {
    final cleanBase =
        baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return '$cleanBase/$cleanPath';
  }

  /// Converts [timestamp] into a filename-safe string.
  ///
  /// Returns the ISO timestamp with colons replaced by underscores.
  String _sanitizeTimestamp(DateTime timestamp) {
    return timestamp.toIso8601String().replaceAll(':', '_');
  }

  /// Returns whether [localPath] points at an existing local file.
  bool _isValidLocalPath(String localPath) {
    if (localPath.isEmpty) return false;
    return fileExists(localPath);
  }

  /// Returns whether [remotePath] is safe to use as an S3 path fragment.
  bool _isValidPath(String remotePath) {
    return remotePath.isNotEmpty && !remotePath.contains('..');
  }
}
