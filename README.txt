================================================================
SMART GEO-TAGGED LANDMARKS
CSE 489: Mobile Application Development - Lab Exam
Student ID / API key: 22299219
================================================================


1. PROJECT OVERVIEW
-------------------

A cross-platform mobile application (Flutter / Dart, targeting Android)
that consumes the faculty-provided REST API at

    https://labs.anontech.info/cse489/exm3/api.php

to browse, map, visit and manage Smart Geo-Tagged Landmarks.

The app works fully offline from a local SQLite cache, and uses
WorkManager to complete visit requests in the background once
connectivity returns.

Note on project layout: the assignment's suggested structure lists an
"app/" directory, which assumes a native Android project. This is a
Flutter project, so the application source lives in "lib/" and the
Android host project (manifest, Gradle, permissions) lives in
"android/". Build output folders are excluded via .gitignore.


2. FEATURES IMPLEMENTED
-----------------------

Bottom navigation with four tabs: Map, Landmarks, Activity, Add.

  Map tab
    - All active landmarks plotted on an OpenStreetMap layer
      (flutter_map), centred on Bangladesh (23.685 N, 90.356 E).
    - Marker colour is interpolated red -> green across the current
      score range, so colour reflects score low-to-high.
    - Tapping a marker opens a detail dialog (image, score,
      coordinates) with a Visit action.
    - Landmarks whose coordinates cannot be plotted are excluded and
      the count is shown in a footer, so the map and list never
      silently disagree.

  Landmarks tab
    - List of all landmarks showing title, image and score.
    - Sort by score, ascending or descending.
    - Filter by minimum score, with the active filter shown as a
      removable chip.
    - Soft delete with confirmation, plus a "Deleted (n)" view from
      which a landmark can be restored.

  Activity tab
    - Visit history: landmark name, visit time and distance.
    - A banner shows how many visits are waiting for connectivity and
      how many results are still being processed.
    - Refreshes itself automatically while work is outstanding.

  Add tab
    - Title, latitude, longitude and an optional image.
    - GPS position is fetched automatically when the tab opens; a
      button re-reads it on demand.
    - Coordinates are range-validated before submission.
    - Images are downscaled and recompressed at pick time to stay
      under the API's 2 MB limit.
    - On success the Map and Landmarks tabs are told to refresh.


3. API USAGE
------------

The student key is sent as the "key" query parameter on every request.
All six documented actions are used:

  GET  ?action=get_landmarks
        Full landmark list. Parsed leniently (see section 6).

  POST ?action=visit_landmark            [application/json]
        Body: landmark_id, user_lat, user_lon.
        Returns { job_id, status:"pending" } - the distance is NOT in
        this response.

  GET  ?action=get_job_status&job_id=..
        Polled until status becomes "done", then the distance is
        stored. Polling happens in a WorkManager worker, never on the
        UI thread. A "failed" status is recorded as a failed visit
        rather than discarded.

  POST ?action=create_landmark           [multipart/form-data]
        Sent as multipart, not JSON, because the server reads the
        image from PHP's $_FILES, which is empty for a JSON body.

  POST ?action=delete_landmark           [x-www-form-urlencoded]
  POST ?action=restore_landmark          [x-www-form-urlencoded]

Error handling: a non-200 response raises an ApiException carrying the
HTTP status code. 403 (invalid_or_expired_key) and 404 (unknown
landmark or job) are treated as permanent and the queued item is
dropped; every other failure is transient and retried with backoff.
This distinction matters - without it, a job that returns 404 would be
re-polled every 15 minutes indefinitely.

Successes are reported with a SnackBar; failures are reported with a
SnackBar or a full error screen with a Retry action.


4. OFFLINE STRATEGY
-------------------

Local SQLite (sqflite) is the single source of truth for the UI.
Schema version 3, with four tables:

  landmarks       cached landmark list, plus a local isActive flag
  pending_visits  visits captured while offline, not yet submitted
  pending_jobs    submitted visits awaiting a get_job_status result
  visit_history   resolved visits (done or failed)

Reads are cache-first: each screen renders the cached copy
immediately, then refreshes from the network. If the refresh fails and
a cache exists, the cached data stays on screen behind an "Offline"
banner. If there is no cache, an error screen with a Retry button is
shown - never a dead end.

Writes while offline: tapping Visit with no connectivity stores the
landmark id and the user's GPS position in pending_visits and returns
immediately.

Soft delete needs special handling. get_landmarks only ever returns
active landmarks, so a refresh would otherwise "undelete" anything the
user had removed. The cache merge preserves locally-deleted rows,
which is also what makes the Restore action possible.


5. ARCHITECTURE USED
--------------------

Repository / single-source-of-truth, as suggested in the brief:

    API (ApiService)  ->  SQLite (DBHelper)  ->  UI screens

Nothing renders straight from a network response; the network writes
to the database and the UI reads from it. This is what allows the
background worker - which runs in a different isolate and cannot call
setState - to deliver results to the screen at all.

  lib/api_service.dart        HTTP client, ApiException, logging
  lib/db_helper.dart          SQLite schema, migrations, queues
  lib/landmark.dart           model + tolerant parsing
  lib/location_service.dart   GPS permission handling (geolocator)
  lib/background_service.dart WorkManager worker
  lib/main.dart               bottom navigation
  lib/*_screen.dart           the four tabs

Background work (Requirement 10) is one WorkManager task serving both
jobs, because they are the same problem - reliable work that must
survive app restarts and unreliable connectivity:

  1. drain pending_visits by submitting them to visit_landmark, then
     record the returned job_id in pending_jobs
  2. poll get_job_status for every row in pending_jobs and write
     resolved results into visit_history

It is registered as a periodic task (15 minutes, the Android minimum,
constrained to NetworkType.connected) with an exponential backoff
policy, plus a one-off trigger fired immediately after a visit is
submitted and whenever connectivity is restored. The periodic
registration is the guarantee; the one-off trigger is the
responsiveness.

Because the worker runs in a separate isolate it cannot notify the UI
directly, so the Activity screen polls the local database every three
seconds while anything is outstanding, and stops once the queues are
empty.

Dependencies: http, sqflite, path, flutter_map, latlong2, geolocator,
image_picker, connectivity_plus, workmanager.


6. CHALLENGES FACED
-------------------

Malformed data in a shared database.
  The API is one database the whole class writes into, so the response
  contains rows such as {"id":108,"title":null,"lat":null,"lon":null}
  and {"id":128,"title":"bushra","lat":7659.097,"lon":6547.93}.
  Parsing latitude with double.parse(json['lat'].toString()) turns a
  null into double.parse("null"), which throws FormatException - and
  because that happened inside a map() over the response, a single bad
  row took down all 175 landmarks and both tabs showed "could not load
  landmarks". Parsing is now lenient: latitude and longitude are
  nullable, a row is rejected only if it has no usable id, and the
  count of skipped rows is logged. Out-of-range coordinates are a
  separate hazard, because latlong2's LatLng asserts on them, so the
  map filters on a hasValidLocation check before constructing any
  LatLng.

The asynchronous visit flow.
  visit_landmark returns a job_id, not a distance. Getting the result
  onto the screen without blocking the UI thread meant persisting the
  job, polling it from a background worker, writing the result to
  SQLite, and having the UI observe the database rather than the
  network call.

Background isolates.
  A WorkManager task runs in a fresh isolate where the main isolate's
  plugin registrations do not exist, so sqflite and http calls fail
  with MissingPluginException unless DartPluginRegistrant is
  initialised first. This failure is silent if exceptions are
  swallowed, so every step of the worker now logs.

Concurrent database opens.
  The Map and Landmarks tabs both request the database in the same
  frame. Caching only the resulting Database object meant both saw
  null and each began its own open, racing one another through the
  ALTER TABLE migration. Caching the in-flight Future instead makes
  the second caller wait on the first.

Timestamps for queued visits.
  A visit queued offline overnight resolves the next morning. Storing
  the time the worker ran would show the wrong time, so the original
  visit time is carried from pending_visits through pending_jobs into
  visit_history.
