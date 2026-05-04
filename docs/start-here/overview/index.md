# Fomomon 

## What is photo monitoring? 

Here is a great [doc](https://research.fs.usda.gov/download/treesearch/3255.pdf) on fixed point photomonitoring in ecology. An excerpt from the document
```
A simple question might deal with effects of livestock grazing on a riparian
area: (1) Are streambanks being broken down?  (2) Are riparian shrubs able to
grow in both height and crown spread? (3) Is there enough herbage remaining
after grazing to trap sediments from flooding? (4) Is herbaceous vegetation
stable, improving, or deteriorating?  

These questions require selection of a sampling location, placement of enough
photo points to answer each of the four questions, and establishment of camera
locations to adequately photograph each photo point. Try to select camera
locations that will photograph more than one photo point. Next, time or times
of year to do the photography must be specified, such as just prior to animal
use of the area, just after they leave, or fall vegetation conditions. Will a
riparian site be monitored for high spring runoff? late season low flows? or
during floods? Monitoring of stream flows vs. animal use probably will require
different scheduling.
```

The fomomon app helps establish it as a practice. 

## Overview

There are two main personas who will use the system

- Field staff: they execute the monitoring (e.g. go to this location, take a picture) 
- Program admins: they plan the monitoring (e.g. set the date, time, location, frequency for monitoring)

There is a third persona, the ecologist who plans an experiment and analyzes the results. Supporting this persona is out of scope for Fomomon (but in scope for good-shepherd).  

Fomomon has two main surfaces, for each persona.

## What the app does

The app exists to tie together the following pieces:

1. Sites: a physical location with GPS coordinates, reference images for overlay guidance, and survey questions. 
2. Session: a captured photo set (portrait + landscape) at a site, tagged with that site's ID, timestamp, and survey responses.
3. Ghost images: a visual reference of the site so the field staff can capture the same image over time. 
4. Pipeline of activities: since the field staff is often not well versed with the end goal of monitoring, the app helps them take the required landscape/portrait images, at the right orientation/bearing/heading, and answer a few pre-configured questions. 

The output is a package of files written into the right S3 directories for the right organization.

## Current architecture

The system is currently serverless from the field app's point of view:

- There is **no API server** in the current app architecture.
- The app talks directly to Cognito for login.
- The app talks directly to S3 for reading configuration and writing uploads.
- The admin interface uses AWS credentials on the server side to update Cognito and S3.

That means some files are shared coordination points:

- `auth_config.json`
- `{org}/sites.json`
- ghost image files under site directories
- session JSON files under `sessions/`

## Read next

- [Architecture](./architecture.md)
- [Users And Journeys](./users.md)
- [Engineering Guide](./engineering.md)

## Further detail

These deeper docs are useful after this overview:

- [docs/v2/background.md](../../v2/background.md)
- [docs/v2/admin.md](../../v2/admin.md)
- [docs/v2/sync_sites.md](../../v2/sync_sites.md)
- [docs/v2/api_server.md](../../v2/api_server.md)
