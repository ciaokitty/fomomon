/// Synchronizes locally created sites into the remote `sites.json`.
///
/// The sync flow always fetches the latest remote `sites.json`, merges
/// field-owned local changes into that snapshot, and writes the result back
/// with an S3 `If-Match` precondition. This prevents stale read-modify-write
/// overwrites when multiple users in the same org upload around the same time.
library;

import 'dart:convert';

import '../config/app_config.dart';
import '../models/captured_session.dart';
import '../models/site.dart';
import '../models/telemetry_event.dart';
import '../models/telemetry_pivots.dart';
import '../services/fetch_service.dart';
import '../services/local_session_storage.dart';
import '../services/local_site_storage.dart';
import '../services/sites_cache_storage.dart';
import '../services/telemetry_service.dart';
import '../services/upload_service.dart';
import '../utils/log.dart';

const String _kSitesCacheKey = 'sites_cache';
const int _kMaxSyncAttempts = 2;

/// Describes the high-level outcome of a `sites.json` sync attempt.
enum SiteSyncStatus { success, conflictRetryable, failureRetryable }

/// Stores the result of `SiteSyncService.syncSitesToRemote()`.
class SiteSyncResult {
  /// Creates a site sync result with the given [status].
  const SiteSyncResult({required this.status, this.message});

  /// The final sync outcome.
  final SiteSyncStatus status;

  /// A user-facing message when sync did not succeed.
  final String? message;

  /// Returns whether the sync completed successfully.
  bool get isSuccess => status == SiteSyncStatus.success;

  /// Returns whether the sync failed due to a write conflict.
  bool get isConflict => status == SiteSyncStatus.conflictRetryable;
}

/// Stores a parsed `sites.json` snapshot fetched from S3.
class RemoteSitesSnapshot {
  /// Creates a remote snapshot wrapper.
  const RemoteSitesSnapshot({
    required this.bucketRoot,
    required this.sites,
    required this.etag,
  });

  /// The remote `bucket_root`.
  final String bucketRoot;

  /// The parsed remote sites list.
  final List<Site> sites;

  /// The S3 ETag for the fetched `sites.json`.
  final String etag;
}

/// Stores a local-to-remote reconciliation discovered during merge.
class _MatchedLocalSite {
  /// Creates a matched local-site record.
  const _MatchedLocalSite({
    required this.localSiteId,
    required this.remoteSiteId,
  });

  /// The local site ID stored on the device.
  final String localSiteId;

  /// The matching remote site ID.
  final String remoteSiteId;
}

/// Stores the result of merging local sites into a remote snapshot.
class _SiteMergeResult {
  /// Creates a site merge result.
  const _SiteMergeResult({
    required this.updatedData,
    required this.matchedLocalSites,
    required this.promotedLocalSiteIds,
    required this.promotedSiteCount,
    required this.filledHeadingCount,
    required this.remoteChanged,
  });

  /// The merged `sites.json` payload ready to upload or cache.
  final Map<String, dynamic> updatedData;

  /// Local sites that were reconciled against existing remote sites.
  final List<_MatchedLocalSite> matchedLocalSites;

  /// Local site IDs that were promoted into new remote site entries.
  final List<String> promotedLocalSiteIds;

  /// The number of new remote sites created by this merge.
  final int promotedSiteCount;

  /// The number of remote sites whose `reference_heading` was filled.
  final int filledHeadingCount;

  /// Whether the remote `sites.json` body changed and needs an upload.
  final bool remoteChanged;
}

/// Synchronizes local-site changes into the remote `sites.json`.
class SiteSyncService {
  /// Synchronizes locally created sites into the remote `sites.json`.
  ///
  /// The method fetches the latest remote snapshot, merges local-site changes,
  /// writes the update with `If-Match`, and retries once if another writer won
  /// the race first.
  ///
  /// Returns a [SiteSyncResult] describing whether the sync succeeded, failed
  /// due to a conflict, or failed for another retryable reason.
  ///
  /// Throws nothing. All errors are converted into a [SiteSyncResult] and
  /// telemetry events.
  static Future<SiteSyncResult> syncSitesToRemote() async {
    if (AppConfig.isGuestMode) {
      dLog('site_sync: Skipping sync in guest mode');
      return const SiteSyncResult(status: SiteSyncStatus.success);
    }

    try {
      final localSites = await LocalSiteStorage.loadLocalSites();
      final allSessions = await LocalSessionStorage.loadAllSessions();
      final uploadedSessions = _uploadedSessionsWithImages(allSessions);

      if (localSites.isEmpty && uploadedSessions.isEmpty) {
        dLog('site_sync: No local sites or uploaded sessions to sync');
        return const SiteSyncResult(status: SiteSyncStatus.success);
      }

      for (var attempt = 1; attempt <= _kMaxSyncAttempts; attempt++) {
        final snapshot = await _fetchRemoteSitesSnapshot();
        final mergeResult = _mergeRemoteAndLocalSites(
          snapshot: snapshot,
          localSites: localSites,
          uploadedSessions: uploadedSessions,
        );

        final cleanupResult = await _finalizeMergedSites(
          snapshot: snapshot,
          mergeResult: mergeResult,
          allSessions: allSessions,
        );

        if (cleanupResult.isSuccess) {
          return cleanupResult;
        }

        if (!cleanupResult.isConflict || attempt == _kMaxSyncAttempts) {
          return cleanupResult;
        }

        dLog(
          'site_sync: Conflict detected while writing sites.json; refetching and retrying',
        );
      }

      return _failureResult(
        message: 'Sync failed, please retry',
        telemetryMessage: 'syncSitesToRemote() exhausted retries unexpectedly',
      );
    } on Exception catch (e) {
      dLog('site_sync: Failed to sync sites.json: $e');
      return _failureResult(
        message: 'Sync failed, please retry',
        telemetryMessage: 'syncSitesToRemote() failed',
        error: e,
      );
    }
  }

  /// Returns uploaded sessions whose image URLs are available for sync.
  static List<CapturedSession> _uploadedSessionsWithImages(
    List<CapturedSession> sessions,
  ) {
    // A note on the inclusion of isDeleted here.  isDeleted is set in
    // site_service when a site is deleted. Consider the following scenario:
    // A site is created and used, then deleted in admin panel. The preferred
    // behavior is that the first image they take on the re-added site is set
    // as the ghost, not any carry over from the first image taken on the
    // original deleted site. We can't guarantee this behavior however, since
    // the site delete-readd might have happened while the user is offline,
    // and without site UUIDs we won't know how to tell the difference. So
    // this is really just a stop gap, the real solution is to use site
    // UUIDs. 
    return sessions.where((session) {
      return session.isUploaded &&
          !session.isDeleted &&
          (session.portraitImageUrl?.isNotEmpty ?? false) &&
          (session.landscapeImageUrl?.isNotEmpty ?? false);
    }).toList();
  }

  /// Fetches the latest remote `sites.json` snapshot from S3.
  ///
  /// Returns the parsed remote sites, raw payload, and S3 ETag.
  ///
  /// Throws an [Exception] if the file cannot be fetched or parsed.
  static Future<RemoteSitesSnapshot> _fetchRemoteSitesSnapshot() async {
    final org = AppConfig.org;
    if (org == null || org.isEmpty) {
      throw Exception('AppConfig.org is not set');
    }

    final response = await FetchService.instance.fetchWithMetadata(
      AppConfig.bucketName,
      '$org/sites.json',
    );

    if (response.response.statusCode != 200) {
      throw Exception(
        'Failed to fetch sites.json: HTTP ${response.response.statusCode}',
      );
    }

    final etag = response.etag;
    if (etag == null || etag.isEmpty) {
      throw Exception('Fetched sites.json without an ETag');
    }

    final rawData = jsonDecode(response.response.body) as Map<String, dynamic>;
    final bucketRoot =
        (rawData['bucket_root'] as String?) ??
        AppConfig.getResolvedBucketRoot();
    final sites =
        ((rawData['sites'] as List?) ?? const <dynamic>[])
            .map(
              (siteJson) =>
                  Site.fromJson(siteJson as Map<String, dynamic>, bucketRoot),
            )
            .toList();

    dLog(
      'site_sync: Fetched ${sites.length} remote sites from S3 with etag $etag',
    );

    return RemoteSitesSnapshot(
      bucketRoot: bucketRoot,
      sites: sites,
      etag: etag,
    );
  }

  /// Merges [localSites] into [snapshot] using uploaded session metadata.
  ///
  /// Remote sites remain authoritative. A local site is treated as already
  /// represented remotely if the remote snapshot has the same site ID or the
  /// same exact latitude and longitude. In matched cases, the remote
  /// `reference_heading` is filled only if it is currently empty.
  ///
  /// Returns the merged payload plus the local sites that can be reconciled or
  /// promoted after a successful write.
  static _SiteMergeResult _mergeRemoteAndLocalSites({
    required RemoteSitesSnapshot snapshot,
    required List<Site> localSites,
    required List<CapturedSession> uploadedSessions,
  }) {
    final mergedSites = <Site>[];
    final matchedLocalSites = <_MatchedLocalSite>[];
    final promotedLocalSiteIds = <String>[];
    var promotedSiteCount = 0;
    var filledHeadingCount = 0;
    var remoteChanged = false;

    for (final remoteSite in snapshot.sites) {
      final uploadedSession = _findFirstUploadedSessionForSite(
        remoteSite.id,
        uploadedSessions,
      );

      if (remoteSite.referenceHeading == null &&
          uploadedSession?.heading != null) {
        mergedSites.add(
          _copySiteWithReferenceHeading(remoteSite, uploadedSession!.heading),
        );
        remoteChanged = true;
        filledHeadingCount++;
      } else {
        mergedSites.add(remoteSite);
      }
    }

    for (final localSite in localSites) {
      final uploadedSession = _findFirstUploadedSessionForSite(
        localSite.id,
        uploadedSessions,
      );
      final remoteMatch = _findRemoteMatch(mergedSites, localSite);

      if (remoteMatch != null) {
        matchedLocalSites.add(
          _MatchedLocalSite(
            localSiteId: localSite.id,
            remoteSiteId: remoteMatch.site.id,
          ),
        );

        if (remoteMatch.site.referenceHeading == null &&
            uploadedSession?.heading != null) {
          mergedSites[remoteMatch.index] = _copySiteWithReferenceHeading(
            remoteMatch.site,
            uploadedSession!.heading,
          );
          remoteChanged = true;
          filledHeadingCount++;
        }
        continue;
      }

      if (uploadedSession == null) {
        dLog(
          'site_sync: No uploaded session found with image URLs for local site ${localSite.id}, skipping',
        );
        continue;
      }

      final portraitRel = _extractRelativePath(
        uploadedSession.portraitImageUrl!,
        snapshot.bucketRoot,
      );
      final landscapeRel = _extractRelativePath(
        uploadedSession.landscapeImageUrl!,
        snapshot.bucketRoot,
      );

      if (portraitRel == null || landscapeRel == null) {
        dLog(
          'site_sync: Failed to extract relative paths for site ${localSite.id}, skipping',
        );
        continue;
      }

      mergedSites.add(
        Site(
          id: localSite.id,
          lat: localSite.lat,
          lng: localSite.lng,
          referencePortrait: portraitRel,
          referenceLandscape: landscapeRel,
          referenceHeading: uploadedSession.heading,
          bucketRoot: snapshot.bucketRoot,
          surveyQuestions: localSite.surveyQuestions,
          isLocalSite: false,
        ),
      );
      promotedLocalSiteIds.add(localSite.id);
      promotedSiteCount++;
      remoteChanged = true;
    }

    final updatedData = {
      'bucket_root': snapshot.bucketRoot,
      'sites': mergedSites.map((site) => site.toJson()).toList(),
    };

    return _SiteMergeResult(
      updatedData: updatedData,
      matchedLocalSites: matchedLocalSites,
      promotedLocalSiteIds: promotedLocalSiteIds,
      promotedSiteCount: promotedSiteCount,
      filledHeadingCount: filledHeadingCount,
      remoteChanged: remoteChanged,
    );
  }

  /// Finalizes [mergeResult] by uploading, caching, and cleaning up local sites.
  ///
  /// The [snapshot] provides the S3 ETag for conditional writes, and
  /// [allSessions] is used to avoid deleting local sites that still have
  /// un-uploaded sessions.
  ///
  /// Returns a [SiteSyncResult] describing whether the write or cleanup
  /// succeeded.
  static Future<SiteSyncResult> _finalizeMergedSites({
    required RemoteSitesSnapshot snapshot,
    required _SiteMergeResult mergeResult,
    required List<CapturedSession> allSessions,
  }) async {
    if (mergeResult.remoteChanged) {
      try {
        await UploadService.instance.uploadJson(
          mergeResult.updatedData,
          snapshot.bucketRoot,
          'sites.json',
          ifMatch: snapshot.etag,
        );
      } on ConditionalWriteConflictException catch (e) {
        dLog('site_sync: Conflict writing sites.json with etag ${e.etag}');
        return _conflictResult(e);
      }
    }

    // This relies on having 2 stores: one for newly created local sites and
    // one for sites.json. When a site is new, it is "promoted" into the
    // sites.json by syncing it with s3, and then the local copy of that site
    // is deleted. This prevents future reconciliation logic from firing.
    // However if a site that should be deleted still has un-uploaded
    // sessions it is not deleted, and will naturally get deleted on the next
    // reconcile attempt. 
    await _writeCacheSitesJson(mergeResult.updatedData);
    await _deleteReconciledLocalSites(
      mergeResult: mergeResult,
      allSessions: allSessions,
    );

    for (final localSiteId in mergeResult.promotedLocalSiteIds) {
      TelemetryService.instance.log(
        TelemetryLevel.info,
        TelemetryPivot.siteSynced,
        'New site written to sites.json: $localSiteId',
        context: {'siteId': localSiteId},
      );
    }

    dLog(
      'site_sync: Sync succeeded with '
      '${mergeResult.promotedSiteCount} promoted site(s) and '
      '${mergeResult.filledHeadingCount} heading update(s)',
    );

    return const SiteSyncResult(status: SiteSyncStatus.success);
  }

  /// Deletes reconciled local sites that no longer need device-local ownership.
  ///
  /// A local site is preserved if it still has an un-uploaded session, because
  /// future retries may still need the local site metadata.
  ///
  /// Returns when all eligible local sites have been removed.
  static Future<void> _deleteReconciledLocalSites({
    required _SiteMergeResult mergeResult,
    required List<CapturedSession> allSessions,
  }) async {
    final unuploadedSiteIds =
        allSessions
            .where((session) => !session.isUploaded && !session.isDeleted)
            .map((session) => session.siteId)
            .toSet();

    for (final promotedSiteId in mergeResult.promotedLocalSiteIds) {
      if (unuploadedSiteIds.contains(promotedSiteId)) {
        dLog(
          'site_sync: Keeping local site $promotedSiteId because uploads are still pending',
        );
        continue;
      }

      await LocalSiteStorage.deleteLocalSite(promotedSiteId);
      dLog(
        'site_sync: Removed promoted site $promotedSiteId from local storage',
      );
    }

    for (final match in mergeResult.matchedLocalSites) {
      if (unuploadedSiteIds.contains(match.localSiteId)) {
        dLog(
          'site_sync: Keeping local site ${match.localSiteId} because uploads are still pending',
        );
        continue;
      }

      await LocalSiteStorage.deleteLocalSite(match.localSiteId);
      dLog(
        'site_sync: Removed reconciled local site ${match.localSiteId} in favor of remote site ${match.remoteSiteId}',
      );
    }
  }

  /// Finds the first uploaded session for [siteId], ordered by timestamp.
  ///
  /// Returns the oldest uploaded session whose image URLs are already known, or
  /// `null` when no such session exists.
  static CapturedSession? _findFirstUploadedSessionForSite(
    String siteId,
    List<CapturedSession> sessions,
  ) {
    CapturedSession? candidate;
    for (final session in sessions) {
      if (session.siteId != siteId) continue;
      if (candidate == null ||
          session.timestamp.isBefore(candidate.timestamp)) {
        candidate = session;
      }
    }
    return candidate;
  }

  /// Finds the remote site in [remoteSites] that matches [localSite].
  ///
  /// A remote site matches when it has the same site ID or the same exact
  /// latitude and longitude.
  ///
  /// Returns the matching remote site plus its index and match rule, or `null`
  /// when the local site is unique.
  static ({int index, Site site})? _findRemoteMatch(
    List<Site> remoteSites,
    Site localSite,
  ) {
    for (var index = 0; index < remoteSites.length; index++) {
      final remoteSite = remoteSites[index];
      if (remoteSite.id == localSite.id) {
        return (index: index, site: remoteSite);
      }
    }

    for (var index = 0; index < remoteSites.length; index++) {
      final remoteSite = remoteSites[index];
      if (remoteSite.lat == localSite.lat && remoteSite.lng == localSite.lng) {
        return (index: index, site: remoteSite);
      }
    }

    return null;
  }

  /// Returns a copy of [site] with [referenceHeading] filled in.
  static Site _copySiteWithReferenceHeading(
    Site site,
    double? referenceHeading,
  ) {
    return Site(
      id: site.id,
      lat: site.lat,
      lng: site.lng,
      referencePortrait: site.referencePortrait,
      referenceLandscape: site.referenceLandscape,
      referenceHeading: referenceHeading,
      localPortraitPath: site.localPortraitPath,
      localLandscapePath: site.localLandscapePath,
      bucketRoot: site.bucketRoot,
      surveyQuestions: site.surveyQuestions,
      isLocalSite: site.isLocalSite,
    );
  }

  /// Writes [data] into the local sites cache.
  ///
  /// Returns when the cache write completes.
  ///
  /// Throws an [Exception] if the cache cannot be written.
  static Future<void> _writeCacheSitesJson(Map<String, dynamic> data) async {
    await SitesCacheStorage.write(_kSitesCacheKey, jsonEncode(data));
  }

  /// Extracts the path below [bucketRoot] from [fullUrl].
  ///
  /// Returns the relative path used inside `sites.json`, or `null` when the
  /// URL does not live under [bucketRoot].
  static String? _extractRelativePath(String fullUrl, String bucketRoot) {
    try {
      final normalizedRoot =
          bucketRoot.endsWith('/')
              ? bucketRoot.substring(0, bucketRoot.length - 1)
              : bucketRoot;
      final urlWithoutQuery = fullUrl.split('#').first.split('?').first;
      final index = urlWithoutQuery.indexOf(normalizedRoot);
      if (index == -1) {
        dLog(
          'site_sync: Bucket root $normalizedRoot not found in URL $urlWithoutQuery',
        );
        return null;
      }

      var start = index + normalizedRoot.length;
      if (start < urlWithoutQuery.length && urlWithoutQuery[start] == '/') {
        start++;
      }
      if (start >= urlWithoutQuery.length) {
        dLog(
          'site_sync: Computed empty relative path for URL $urlWithoutQuery',
        );
        return null;
      }
      return urlWithoutQuery.substring(start);
    } catch (e) {
      dLog('site_sync: Failed to extract relative path from $fullUrl: $e');
      return null;
    }
  }

  /// Returns a conflict result and emits telemetry for [error].
  static SiteSyncResult _conflictResult(
    ConditionalWriteConflictException error,
  ) {
    TelemetryService.instance.log(
      TelemetryLevel.error,
      TelemetryPivot.siteSyncFailed,
      'sync conflict - someone else modified file ${error.etag ?? 'unknown'}',
      error: error,
      context: {'kind': 'conflict', 'etag': error.etag, 's3Key': error.s3Key},
    );
    return const SiteSyncResult(
      status: SiteSyncStatus.conflictRetryable,
      message: 'Sync conflict, please retry',
    );
  }

  /// Returns a generic failure result and emits telemetry.
  static SiteSyncResult _failureResult({
    required String message,
    required String telemetryMessage,
    Object? error,
  }) {
    TelemetryService.instance.log(
      TelemetryLevel.error,
      TelemetryPivot.siteSyncFailed,
      telemetryMessage,
      error: error,
      context: {'kind': 'failure', 'details': error?.toString()},
    );
    return SiteSyncResult(
      status: SiteSyncStatus.failureRetryable,
      message: message,
    );
  }
}
