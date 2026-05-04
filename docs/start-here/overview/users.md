# Users And Journeys

Fomomon has two main user journeys: the field user journey and the admin user journey.
Within the admin journeys, there is: 
1. A system-admin, i.e. someone who has deployed the app for a set of orgs
2. A program admin, i.e. someone who has thought strategically about site placement, ghost images and survey questions. 

In the case of the main Fomomon deployment, T4GC plays the role of system admin, while the ecologist running an experiment plays the role of aprogram admin. 

## Field user

The field user's job is to create and upload photo monitoring sessions.

Typical actions:

- log in with credentials issued ahead of time
- fetch `sites.json` and ghost images for offline use (this happens automatically on login)
- choose an existing site or create a new local site
- capture portrait and landscape images
- answer surveys when present
- upload sessions 

See also: [docs/auth.md](../../auth.md), [docs/sites.md](../../sites.md), [docs/ghost_images.md](../../ghost_images.md), and [docs/upload.md](../../upload.md)

### Field user prerequisites

- Their organization mmust already be on-boarded by the system admin. 
- They themselves must be onboarded by the program admin. This is how they obtain login credentials.
- Their device must be able to cache site data and ghost images locally.
- In practice they also need camera and location permissions.

### Field user outputs

The field app is the only place that creates session data:

- uploaded images under site-specific storage paths
- uploaded session JSON under `sessions/`
- site additions promoted back into `sites.json`

See also: [docs/upload.md](../../upload.md) and [docs/v2/sync_sites.md](../../v2/sync_sites.md)

## Admin user

Currently, both the system and program admin roles are merged in one and operated via a single admin interface. The only people using this interface are the T4GC eng team. 

### System admin 

First, the system admin (this could be someone at T4GC but also eg an NCF wide admin who has deployed the entire stack on-prem) must create an "org". This "org" admin then owns the canonical setup for:

- bucket and auth configuration
- AWS CLI credentials or equivalent AWS credentials made available to the program admin
- permission to operate on the Fomomon S3 bucket
- permission to manage Cognito app resources
- permission to manage the IAM role used by the phone app

Currently this role is owned by the T4GC eng team, and there are no plans to transition it to the community. 

### System admin: AWS permission categories

At a minimum, the admin path needs access equivalent to:

- `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, and delete permissions for org files such as `sites.json`, `users.json`, ghost images, and telemetry cleanup
- Cognito user-pool administration for creating users, deleting users, listing users, and resetting passwords
- Cognito identity-pool read/update access for wiring app auth
- IAM role read/update access for the phone app role policy
- enough bucket-level access to inspect or enforce bucket configuration used by the admin tooling

### Program admin

The program admin user's job is to keep organizations, users, sites, and ghost images coherent.

Typical actions:

- create users and reset passwords
- add or remove sites in `sites.json`
- rename or delete sites
- upload or replace ghost images

See also: [docs/v2/admin.md](../../v2/admin.md), [admin/README.md](../../../admin/README.md), and [admin/AUTH.md](../../../admin/AUTH.md)

Currently this role is owned by the T4GC eng team, but it will be transitioned to individual Ecologists running their programs. To do so, the admin interface needs to function without relying on local AWS credentials - i.e. the functionality of the admin server needs to merge with an API server in the cloud that is capable of using its own credentials (or those of a logged in cognito user) to perform the actions above.  

## Further detail

- [docs/v2/admin.md](../../v2/admin.md)
- [docs/v2/background.md](../../v2/background.md)
- [docs/auth.md](../../auth.md)
- [admin/README.md](../../../admin/README.md)
- [admin/AUTH.md](../../../admin/AUTH.md)
