# Engineering Guide

This is the short engineering map for how the current app works.

## Key files in S3 and on device

Important shared files:

- `auth_config.json`: public bootstrap config for Cognito details
- `{org}/sites.json`: canonical remote site list for an org
- `{org}/{siteId}/...jpg`: ghost images and captured images
- `{org}/sessions/*.json`: uploaded session metadata

Important local caches and stores:

- cached `sites.json`
- cached ghost images
- local site store for sites created on device
- local session store for sessions waiting to upload

See also: [docs/sites.md](../../sites.md) and [docs/ghost_images.md](../../ghost_images.md)

## Read and write responsibilities

Current write ownership is split:

- The app reads `auth_config.json`, `sites.json`, and ghost images.
- The app writes session images, session JSON, and can update `sites.json` by promoting local sites after upload.
- The admin interface writes users, org setup, `sites.json`, and ghost images.

Because both the app and admin can write `sites.json`, this is a file-coordination design with eventual consistency and some write-conflict risk (see [issues/50](https://github.com/bprashanth/fomomon/issues/50)). 

See also: [docs/v2/sync_sites.md](../../v2/sync_sites.md) and [docs/v2/admin.md](../../v2/admin.md)

## Screen map

Core screens in [fomomon/lib/screens](../../../fomomon/lib/screens):

- `login_screen.dart`: fetches auth config and starts login
- `site_prefetch_screen.dart`: fetches `sites.json` and ghost images for offline use after login
- `home_screen.dart`: shows nearby sites and the plus-button entry point
- `site_selection_screen.dart`: choose an existing site or create a local one
- `capture_screen.dart`: camera capture with ghost-image guidance
- `confirm_screen.dart`: retake or accept each capture
- `survey_screen.dart`: optional survey completion
- `upload_queue_screen.dart`: review and upload pending sessions

See also: [docs/ux/ux.md](../../ux/ux.md), [docs/ux/finding_sites.md](../../ux/finding_sites.md), and [docs/ux/upload_queue.md](../../ux/upload_queue.md)

## Widget map

Important widgets in [fomomon/lib/widgets](../../../fomomon/lib/widgets):

- `plus_button.dart`: starts the capture pipeline
- `upload_dial_widget.dart`: drives upload and post-upload sync
- `site_map_widget.dart`: renders site and user position context
- `orientation_dial.dart`: helps align capture orientation
- `session_detail_dialog.dart`: inspects queued sessions

## Service map

Important services in [fomomon/lib/services](../../../fomomon/lib/services):

- `auth_service.dart`: Cognito login, token refresh, and AWS credentials
- `site_service.dart`: fetch `sites.json`, download ghost images, cache locally, merge local sites
- `upload_service.dart`: upload images and session JSON to S3
- `site_sync_service.dart`: promote locally created sites into remote `sites.json`
- `fetch_service.dart`: signed and unsigned HTTP fetches
- `local_session_storage*.dart`: persist sessions on device
- `local_site_storage*.dart`: persist field-created local sites on device
- `local_image_storage*.dart`: persist captured and ghost images locally

See also: [docs/auth.md](../../auth.md), [docs/upload.md](../../upload.md), and [docs/sites.md](../../sites.md)

## Functionality map

If you are tracing a feature, start here:

- login: `login_screen.dart` -> `auth_service.dart`
- initial site fetch: `site_prefetch_screen.dart` -> `site_service.dart`
- home-screen refresh: `home_screen.dart` -> `site_service.dart`
- capture pipeline: `home_screen.dart` / `plus_button.dart` -> capture/confirm/survey screens
- upload: `upload_queue_screen.dart` / `upload_dial_widget.dart` -> `upload_service.dart`
- local-site promotion after upload: `upload_dial_widget.dart` -> `site_sync_service.dart`
- admin org/user/site maintenance: [admin/backend](../../../admin/backend) and [admin/frontend](../../../admin/frontend)

## Further detail

- [docs/v2/background.md](../../v2/background.md)
- [docs/v2/sync_sites.md](../../v2/sync_sites.md)
- [docs/upload.md](../../upload.md)
- [docs/sites.md](../../sites.md)
- [docs/ghost_images.md](../../ghost_images.md)
