# Architecture

## High-level shape

Fomomon has three important UI and code concepts:

- **Screens**: route-level steps such as login, site prefetch, home, capture, confirm, survey, and upload queue.
- **Widgets**: reusable UI pieces inside screens such as the plus button, upload dial, orientation dial, site map, and session dialogs.
- **Services**: non-UI logic for auth, site fetching, local storage, uploads, telemetry, and sync.

A screen is made up of widgets. The app's main user action is a pipeline of screens triggered from the plus button on the home screen.

See also: [docs/code.md](../../code.md)

## Capture pipeline

The primary pipeline starts when the field user taps the plus button:

1. Home screen: decides whether the user can continue with the nearest site or should choose/create a site.
2. Site selection: screen optionally creates a local site if the user is not using an existing one.
3. Capture screen: records the portrait image.
4. Confirm screen: either accepts or retakes the portrait image.
5. Capture screen: records the landscape image.
6. Confirm screen: either accepts or retakes the landscape image.
7. Survey screen: collects responses when the site has survey questions.
8. The app saves a local session package for later upload.

This is why the app feels like a guided workflow rather than a collection of independent pages.

See also: [docs/ghost_images.md](../../ghost_images.md) and [docs/surveys.md](../../surveys.md)

## Data flow

The current architecture is direct-to-AWS:

- Login goes from the app to Cognito.
- Authenticated upload uses temporary Cognito-backed AWS credentials and presigned S3 PUT URLs.
- Site configuration and ghost images are read from S3 and cached locally.
- Session files are assembled on device first, then uploaded to S3.

There is **no app API server** in the current runtime path.

See also: [docs/v2/background.md](../../v2/background.md), [docs/auth.md](../../auth.md), and [docs/upload.md](../../upload.md)

## Source-of-truth rules

Today the system uses different writers for different kinds of data:

- `sites.json` is updated from both the app and the admin interface.
- Ghost images are updated through the admin interface.
- New users and new orgs are updated through the admin interface.
- Sessions are created and updated through the app.

In other words, Fomomon coordinates a shared file-based system, not a database-backed transaction system.

See also: [docs/v2/admin.md](../../v2/admin.md) and [docs/v2/sync_sites.md](../../v2/sync_sites.md)

## Local-first behavior

The field app is built to keep working when connectivity is weak:

- `sites.json` is downloaded from S3 and cached locally.
- ghost images are downloaded from S3 and cached locally
- locally created sites are stored separately on device
- captured sessions are stored locally until uploaded

After upload, local sites may be promoted into remote `sites.json`, using uploaded session images as the new reference images for that site.

See also: [docs/sites.md](../../sites.md) and [docs/ghost_images.md](../../ghost_images.md)

## Main code entry points

- Screens: [fomomon/lib/screens](../../../fomomon/lib/screens)
- Widgets: [fomomon/lib/widgets](../../../fomomon/lib/widgets)
- Services: [fomomon/lib/services](../../../fomomon/lib/services)
- Admin app: [admin](../../../admin)

Also see [docs/code.md](../../code.md)

## Further detail

- [docs/v2/background.md](../../v2/background.md)
- [docs/v2/sync_sites.md](../../v2/sync_sites.md)
- [docs/v2/api_server.md](../../v2/api_server.md)
