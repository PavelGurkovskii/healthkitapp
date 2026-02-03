# iOS app

This folder contains a Swift/SwiftUI source code skeleton for the take-home assignment.

## What is implemented

- HealthKit raw step samples reading via `HKAnchoredObjectQuery` (paging/batching)
- Observer query to continue syncing new samples after the initial backfill
- Disk-backed outbox (chunk files) to guarantee eventual delivery
- `UploadManager` implemented as a state machine:
  - requests local data from the provider
  - enqueues chunks
  - uploads chunks
  - handles failures / network loss
  - after 3 consecutive upload failures: switches to ping-with-backoff mode and resumes only after successful ping
- Background execution via `BGProcessingTask`

## Xcode project

Open the included project:

- `ios/HealthKitApp.xcodeproj`

### Required capabilities / plist keys

- HealthKit capability enabled
- Background Modes:
  - Background processing
- `NSHealthShareUsageDescription`
- `BGTaskSchedulerPermittedIdentifiers` includes the identifier used in code: `com.pavlohurkovskyi.healthkitapp.processing`

## Configure backend URL

The app reads the backend base URL from `Info.plist` key `BackendBaseURL`.

Default value:

- `http://localhost:3000`

If you run on a physical device, expose the local backend using e.g. ngrok and update `BackendBaseURL` to your ngrok HTTPS URL.
