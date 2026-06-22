import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../services/upload_service.dart';
import '../services/local_session_storage.dart';
import '../services/local_site_storage.dart';
import '../services/site_sync_service.dart';
import '../models/site.dart';
import '../exceptions/auth_exceptions.dart';
import '../screens/login_screen.dart';
import '../models/captured_session.dart';
import '../utils/log.dart';

/// Displays the upload dial and runs the session-upload workflow.
class UploadDialWidget extends StatefulWidget {
  /// Creates an upload dial for the current [sites] list.
  const UploadDialWidget({super.key, required this.sites});
  final List<Site> sites;

  @override
  State<UploadDialWidget> createState() => _UploadDialWidgetState();
}

// Upload files counters are managed via flutter notifications.
// This needs to happen when this widget becomes visible (didChangeDependencies).
class _UploadDialWidgetState extends State<UploadDialWidget>
    with WidgetsBindingObserver {
  int uploaded = 0;
  int total = 0;
  // hasError is set to true when an upload error occurs and triggers UI /
  // error surfacing to the user.
  bool hasError = false;
  bool _isUploading = false;
  bool _noNetwork = false;
  bool _isPressed = false; // For tap feedback
  int _completedSubsteps =
      0; // counts portrait/landscape/json across all sessions
  UploadPhase? _currentPhase;
  // Set via formatSessionLabel(), eg 'siteId - date time'
  String? _currentSessionLabel;
  // _lastErrorLabel is only for debug logging, not shown to user
  String? _lastErrorLabel;
  String? _errorMessage;

  /// After all session uploads, while syncing sites.json and telemetry.
  bool _isSyncingMetadata = false;
  bool _hasPendingMetadataSync = false;

  // Number of phases per session (matches UploadService.numPhasesPerSession)
  static const int numPhasesPerSession = 3;

  static const Map<UploadPhase, String> _phaseShortLabel = {
    UploadPhase.portrait: 'P',
    UploadPhase.landscape: 'L',
    UploadPhase.sessionJson: 'S',
  };

  static const Map<UploadPhase, String> _phaseLongLabel = {
    UploadPhase.portrait: 'Portrait',
    UploadPhase.landscape: 'Landscape',
    UploadPhase.sessionJson: 'Session',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSessions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh when widget becomes visible
    _loadSessions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh when app comes to foreground
      _loadSessions();
    }
  }

  Future<void> _loadSessions() async {
    final sessions = await LocalSessionStorage.loadAllSessions();
    final localSites = await LocalSiteStorage.loadLocalSites();
    final unuploaded = sessions.where((s) => !s.isUploaded).toList();
    final uploadedSessions = sessions.where((s) => s.isUploaded).toList();
    final uploadedWithImageUrls =
        uploadedSessions.where((session) {
          return !session.isDeleted &&
              (session.portraitImageUrl?.isNotEmpty ?? false) &&
              (session.landscapeImageUrl?.isNotEmpty ?? false);
        }).toList();
    // final uploadedWithAnyImageUrls =
    //     uploadedSessions.where((session) {
    //       return (session.portraitImageUrl?.isNotEmpty ?? false) &&
    //           (session.landscapeImageUrl?.isNotEmpty ?? false);
    //     }).length;
    // final deletedSessions = sessions.where((s) => s.isDeleted).length;
    final hasPendingMetadataSync =
        unuploaded.isEmpty &&
        localSites.isNotEmpty &&
        uploadedWithImageUrls.isNotEmpty;

    // dLog(
    //   'upload_dial_widget: _loadSessions loaded '
    //   '${sessions.length} total, ${unuploaded.length} unuploaded, '
    //   '${uploadedSessions.length} uploaded '
    //   '(${uploadedWithImageUrls.length} non-deleted with image URLs, '
    //   '${uploadedSessions.length - uploadedWithAnyImageUrls} missing image URLs), '
    //   '$deletedSessions deleted, ${localSites.length} local site(s), '
    //   'pendingMetadataSync=$hasPendingMetadataSync; previous dial state '
    //   'uploaded=$uploaded total=$total hasError=$hasError '
    //   'pendingMetadataSync=$_hasPendingMetadataSync '
    //   'isUploading=$_isUploading isSyncingMetadata=$_isSyncingMetadata '
    //   'errorMessage=$_errorMessage lastError=$_lastErrorLabel',
    // );

    if (!mounted) return;
    setState(() {
      uploaded = 0;
      total = unuploaded.length;
      _hasPendingMetadataSync = hasPendingMetadataSync;
    });
  }

  Future<bool> _checkNetwork() async {
    try {
      // Check our own S3 bucket rather than a third-party URL like google.com.
      // auth_config.json is public, so no auth is needed, and a 200 confirms
      // both network connectivity and S3 reachability — exactly what matters
      // before an upload. This also avoids CORS issues on web (google.com does
      // not send Access-Control-Allow-Origin headers).
      final url =
          'https://${AppConfig.bucketName}.s3.${AppConfig.region}.amazonaws.com/auth_config.json';
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  void _onUploadPressed() async {
    // dLog(
    //   'upload_dial_widget: upload pressed with state '
    //   'uploaded=$uploaded total=$total hasError=$hasError '
    //   'isUploading=$_isUploading noNetwork=$_noNetwork '
    //   'pendingMetadataSync=$_hasPendingMetadataSync '
    //   'isSyncingMetadata=$_isSyncingMetadata '
    //   'errorMessage=$_errorMessage lastError=$_lastErrorLabel',
    // );

    // Show immediate tap feedback
    setState(() {
      _isPressed = true;
    });
    // Reset feedback after brief delay
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() {
          _isPressed = false;
        });
      }
    });

    // Always refresh sessions first so `total` reflects the current number
    // of unuploaded sessions before we decide whether there is any work to do.
    await _loadSessions();
    if (!mounted) return;

    if (total == 0 && !_hasPendingMetadataSync) {
      dLog(
        'upload_dial_widget: upload press returning early because '
        '_loadSessions set total=0 and no metadata sync is pending; '
        'hasError=$hasError '
        'errorMessage=$_errorMessage lastError=$_lastErrorLabel '
        'noNetwork=$_noNetwork isSyncingMetadata=$_isSyncingMetadata',
      );
      return;
    }

    final isMetadataOnlyRetry = total == 0 && _hasPendingMetadataSync;

    // Quick visual feedback on tap
    setState(() {
      _isUploading = true;
      hasError = false;
      _noNetwork = false;
      _completedSubsteps = 0;
      _currentPhase = null;
      _currentSessionLabel = null;
      _lastErrorLabel = null;
      _errorMessage = null;
      _isSyncingMetadata = isMetadataOnlyRetry;
    });
    dLog(
      isMetadataOnlyRetry
          ? 'upload_dial_widget: starting metadata-only sync retry'
          : 'upload_dial_widget: starting upload workflow for $total '
              'unuploaded session(s)',
    );

    // Network check before starting upload
    final hasNetwork = await _checkNetwork();
    if (!mounted) return;
    if (!hasNetwork) {
      setState(() {
        _isUploading = false;
        _isSyncingMetadata = false;
        _noNetwork = true;
        hasError = true;
      });
      return;
    }

    if (isMetadataOnlyRetry) {
      try {
        await _syncMetadataAndRefresh(reason: 'metadata-only retry');
      } finally {
        if (mounted) {
          setState(() {
            _isUploading = false;
            _isSyncingMetadata = false;
          });
        }
      }
      return;
    }

    // Upload all sessions, then sync local sites into remote sites.json.
    //
    // uploadAllSessions() throws after finishing its loop when any session
    // had an error (the loop itself continues). syncSitesToRemote() must
    // still run in that case: sessions that DID upload have their image URLs
    // set, so a new local site can be promoted even if another session failed.
    // syncSitesToRemote() never throws (logs only).
    //
    // Auth exceptions are re-thrown from the inner try so the outer handlers
    // can redirect to login.
    try {
      // --- Step 1: upload (errors collected, not immediately fatal) ---
      try {
        await UploadService.instance.uploadAllSessions(
          sites: widget.sites,
          onProgress: () {
            setState(() => uploaded++);
          },
          onPhaseProgress: (CapturedSession session, UploadPhase phase) {
            setState(() {
              _currentPhase = phase;
              _completedSubsteps++;
              _currentSessionLabel = _formatSessionLabel(session);
            });
          },
          onSessionError: (CapturedSession session, Object error) {
            setState(() {
              hasError = true;
              _currentPhase = null;
              _currentSessionLabel = _formatSessionLabel(session);
              _lastErrorLabel = error.toString();
            });
          },
        );
      } on AuthSessionExpiredException {
        rethrow;
      } on AuthCredentialsException {
        rethrow;
      } catch (e) {
        // Session-level upload errors: UI already updated via onSessionError.
        // Fall through so sync still runs for the sessions that succeeded.
        dLog("upload_dial_widget: upload error: $e");
        if (mounted && !hasError) {
          setState(() {
            hasError = true;
            _lastErrorLabel ??= e.toString();
          });
        }
      }

      await _syncMetadataAndRefresh(reason: 'post-upload sync');
      dLog(
        'upload_dial_widget: post-workflow refresh complete with '
        'uploaded=$uploaded total=$total hasError=$hasError '
        'pendingMetadataSync=$_hasPendingMetadataSync '
        'errorMessage=$_errorMessage lastError=$_lastErrorLabel',
      );
      if (mounted) {
        setState(() {
          _isUploading = false;
          _isSyncingMetadata = false;
        });
      }
    } on AuthSessionExpiredException catch (e) {
      dLog("upload_dial_widget: Session expired: $e");
      if (mounted) {
        setState(() {
          _isUploading = false;
          _isSyncingMetadata = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your session has expired. Please log in again.'),
            duration: Duration(seconds: 3),
          ),
        );
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      }
    } on AuthCredentialsException catch (e) {
      dLog("upload_dial_widget: Auth credentials error: $e");
      if (mounted) {
        setState(() {
          _isUploading = false;
          _isSyncingMetadata = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your session has expired. Please log in again.'),
            duration: Duration(seconds: 3),
          ),
        );
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      }
    } catch (e) {
      dLog("upload_dial_widget: unexpected error: $e");
      if (mounted && !hasError) {
        setState(() {
          hasError = true;
          _lastErrorLabel ??= e.toString();
        });
      }
      await _loadSessions();
      if (mounted) {
        setState(() {
          _isUploading = false;
          _isSyncingMetadata = false;
        });
      }
    }
  }

  Future<void> _syncMetadataAndRefresh({required String reason}) async {
    if (mounted) {
      setState(() => _isSyncingMetadata = true);
    }
    dLog(
      'upload_dial_widget: starting SiteSyncService.syncSitesToRemote() '
      'for $reason',
    );
    final syncResult = await SiteSyncService.syncSitesToRemote();
    dLog(
      'upload_dial_widget: sync result for $reason '
      'status=${syncResult.status} isSuccess=${syncResult.isSuccess} '
      'message=${syncResult.message}',
    );

    if (mounted) {
      setState(() {
        if (syncResult.isSuccess) {
          hasError = false;
          _noNetwork = false;
          _errorMessage = null;
          _lastErrorLabel = null;
        } else {
          hasError = true;
          _errorMessage = syncResult.message;
          _lastErrorLabel = syncResult.status.toString();
        }
      });
    }

    await _loadSessions();
  }

  @override
  Widget build(BuildContext context) {
    final label = total == 0 ? '0/0 files' : '$uploaded/$total';
    final hasMetadataOnlyPending = total == 0 && _hasPendingMetadataSync;
    final buttonText =
        _noNetwork
            ? 'No Network'
            : _isSyncingMetadata
            ? 'Syncing Metadata...'
            : hasMetadataOnlyPending && hasError
            ? 'Retry Metadata'
            : hasMetadataOnlyPending
            ? 'Sync Metadata'
            : hasError
            ? 'Tap to Retry'
            : _isUploading
            ? 'Uploading...'
            : 'Tap to Upload';
    final buttonTitleTextColor =
        _noNetwork || hasError ? Colors.redAccent : Colors.white70;
    final buttonTextColor =
        _noNetwork || hasError ? Colors.redAccent : Colors.white;

    final totalSubsteps = total == 0 ? 0 : numPhasesPerSession * total;
    final progressValue =
        totalSubsteps == 0
            ? 0.0
            : (_completedSubsteps / totalSubsteps).clamp(0.0, 1.0);
    // Indeterminate spinner when waiting for first upload or when syncing metadata
    final showIndeterminate =
        _isUploading &&
        (total > 0 && _completedSubsteps == 0 || _isSyncingMetadata);

    final phaseLabel =
        _isSyncingMetadata
            ? 'Updating sites…'
            : _currentPhase != null
            ? _phaseLongLabel[_currentPhase] ?? ''
            : total == 0
            ? 'Idle'
            : _isUploading && total > 0 && _completedSubsteps == 0
            ? 'Starting sync…'
            : 'Ready';

    // Show success message when all sessions uploaded
    final allUploaded =
        total == 0 &&
        uploaded == 0 &&
        !hasError &&
        !_isUploading &&
        !_hasPendingMetadataSync;

    return GestureDetector(
      onTap: _isUploading ? null : _onUploadPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color:
                          _isPressed
                              ? Colors.yellowAccent
                              : Colors.grey.withValues(alpha: 0.5),
                      width: 2,
                    ),
                  ),
                  child: CircularProgressIndicator(
                    value: showIndeterminate ? null : progressValue,
                    strokeWidth: 6,
                    backgroundColor: Colors.grey.withValues(alpha: 0.3),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.yellowAccent,
                    ),
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    color: buttonTextColor,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Cute 3-step indicator for current session
            // This is the phase display UI that shows up under the progress
            // indicator.
            if (total > 0)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildStepDot(UploadPhase.portrait),
                  const SizedBox(width: 6),
                  _buildStepDot(UploadPhase.landscape),
                  const SizedBox(width: 6),
                  _buildStepDot(UploadPhase.sessionJson),
                ],
              ),
            if (total > 0) const SizedBox(height: 4),
            if (total > 0)
              Text(
                phaseLabel,
                style: TextStyle(
                  color: buttonTitleTextColor,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            // Show session label during upload or on failure
            if ((_isUploading || hasError) && _currentSessionLabel != null) ...[
              const SizedBox(height: 4),
              Text(
                _currentSessionLabel!,
                style: TextStyle(
                  color: hasError ? Colors.redAccent : Colors.white54,
                  fontSize: 9,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ],
            // Show success message when all done
            if (allUploaded) ...[
              const SizedBox(height: 4),
              const Text(
                'All sessions uploaded',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (hasMetadataOnlyPending && !hasError) ...[
              const SizedBox(height: 4),
              Text(
                _isSyncingMetadata ? phaseLabel : 'Metadata sync pending',
                style: TextStyle(
                  color:
                      _isSyncingMetadata ? Colors.white70 : Colors.yellowAccent,
                  fontSize: 9,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ],
            // Show error message on failure (but not the raw error string)
            if (hasError && !allUploaded) ...[
              const SizedBox(height: 4),
              Text(
                _noNetwork
                    ? 'No network connection'
                    : _errorMessage ?? 'Upload failed',
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 9,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            if (total > 0 || allUploaded || hasMetadataOnlyPending)
              const SizedBox(height: 4),
            Text(
              buttonText,
              style: TextStyle(
                color: buttonTitleTextColor,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepDot(UploadPhase phase) {
    final isActive = _currentPhase == phase;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color:
                isActive
                    ? Colors.yellowAccent
                    : Colors.grey.withValues(alpha: 0.4),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _phaseShortLabel[phase] ?? '',
          style: TextStyle(
            color:
                isActive
                    ? Colors.yellowAccent
                    : Colors.grey.withValues(alpha: 0.7),
            fontSize: 8,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  String _formatSessionLabel(CapturedSession session) {
    final ts = session.timestamp.toLocal();
    final date =
        '${ts.year.toString().padLeft(4, '0')}-'
        '${ts.month.toString().padLeft(2, '0')}-'
        '${ts.day.toString().padLeft(2, '0')}';
    final time =
        '${ts.hour.toString().padLeft(2, '0')}:'
        '${ts.minute.toString().padLeft(2, '0')}';
    return '${session.siteId} · $date $time';
  }
}
