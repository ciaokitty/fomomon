/// Fetches public URLs and authenticated S3 objects.
///
/// Use [fetchUnauthenticated] for public resources such as `auth_config.json`
/// and [fetch] or [fetchWithMetadata] for authenticated S3 reads via presigned
/// GET URLs.
library;

import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 's3_signer_service.dart';

/// Stores an authenticated S3 response and selected response metadata.
class FetchResponseWithMetadata {
  /// Creates a fetched S3 response wrapper.
  const FetchResponseWithMetadata({required this.response, required this.etag});

  /// The HTTP response body and headers.
  final http.Response response;

  /// The S3 ETag header when present.
  final String? etag;
}

class FetchService {
  FetchService._privateConstructor();
  static final FetchService instance = FetchService._privateConstructor();

  /// Fetches [url] without authentication.
  ///
  /// Use this for public resources such as `auth_config.json`.
  ///
  /// Returns the HTTP response.
  ///
  /// Throws an [Exception] if the request cannot be issued.
  Future<http.Response> fetchUnauthenticated(String url) {
    return http.get(Uri.parse(url));
  }

  /// Fetches the S3 object at [s3Key] from [bucketName].
  ///
  /// The object is fetched with a presigned GET URL generated from the current
  /// Cognito-backed AWS credentials.
  ///
  /// Returns the HTTP response.
  ///
  /// Throws an [Exception] if credentials cannot be loaded or the request
  /// cannot be issued.
  Future<http.Response> fetch(String bucketName, String s3Key) async {
    final result = await fetchWithMetadata(bucketName, s3Key);
    return result.response;
  }

  /// Fetches the S3 object at [s3Key] from [bucketName] with response metadata.
  ///
  /// The object is fetched with a presigned GET URL generated from the current
  /// Cognito-backed AWS credentials.
  ///
  /// Returns the HTTP response along with the S3 ETag when present.
  ///
  /// Throws an [Exception] if credentials cannot be loaded or the request
  /// cannot be issued.
  Future<FetchResponseWithMetadata> fetchWithMetadata(
    String bucketName,
    String s3Key,
  ) async {
    final credentials = await AuthService.instance.getUploadCredentials();
    final presignedUrl = await S3SignerService.instance.createPresignedGetUrl(
      bucketName: bucketName,
      s3Key: s3Key,
      credentials: credentials,
    );
    final response = await http.get(Uri.parse(presignedUrl));
    return FetchResponseWithMetadata(
      response: response,
      etag: response.headers['etag'],
    );
  }

  /// Derives the S3 object key from [fullS3Url].
  ///
  /// For example, a URL ending in `/t4gc/foo/bar.jpg` becomes
  /// `t4gc/foo/bar.jpg`.
  ///
  /// Returns the object key without a leading slash.
  static String s3KeyFromUrl(String fullS3Url) {
    final path = Uri.parse(fullS3Url).path;
    return path.startsWith('/') ? path.substring(1) : path;
  }
}
