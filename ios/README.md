# iOS app

The iOS app reads *raw* step samples from HealthKit and uploads them to the backend in chunks.

---

## What is implemented

- HealthKit step samples reading via `HKAnchoredObjectQuery` (paging/batching).
- An observer query to continue syncing new samples after the initial backfill.
- A disk-backed outbox (chunk JSON files) to guarantee eventual delivery.
- `UploadManager` as a producer/consumer pipeline:
  - producer reads from HealthKit and enqueues chunk files
  - consumer uploads queued chunk files
  - pause/resume + network reachability support
  - retry with exponential backoff
  - after 3 consecutive upload failures: switches to `ping` gate mode and resumes only after successful `GET /ping`
- Background execution via `BGProcessingTask`.

---

## Xcode project

Open:

- `ios/HealthKitApp.xcodeproj`

---

## Run on Simulator vs Device

### Simulator

- You can build and run UI.
- HealthKit data is often missing/unreliable on Simulator, so syncing may show no work.

### Physical device (recommended)

- Required to read your real step samples.
- Requires code signing and enabling capabilities.

---

## Required capabilities / Info.plist

### Capabilities

- **HealthKit** capability enabled.
- **Background Modes**:
  - Background processing.

### Info.plist keys

- `NSHealthShareUsageDescription` (HealthKit read prompt).
- `BGTaskSchedulerPermittedIdentifiers` must include:
  - `com.pavlohurkovskyi.healthkitapp.processing`

### App configuration keys

The app reads configuration from `ios/HealthKitApp/Info.plist`:

- `BackendBaseURL`
  - Default: `http://localhost:3000`
  - For physical device, this must point to a reachable backend URL.
- `UploadChunkSize`
  - Optional. If missing, app uses default `50`.
  - Clamped to `[1..5000]`.

---

## Backend URL configuration

### Local dev on Simulator

- Use `BackendBaseURL = http://localhost:3000`.

### Physical device

Because the app runs on the phone, `localhost` would point to the phone itself.

Use one of:

- **LAN IP**: run backend on your Mac and set `BackendBaseURL` to `http://<mac_lan_ip>:3000`.
- **ngrok**: expose backend to the internet and set `BackendBaseURL` to the ngrok HTTPS URL.

The repo includes a helper script from the repo root:

```bash
./run_device.sh --team <YOUR_TEAM_ID>
```

It starts backend + ngrok and patches `BackendBaseURL` in `Info.plist` automatically.

---

## How HealthKit selection works

- The app queries `HKQuantityTypeIdentifier.stepCount`.
- It uses an anchored query (`HKAnchoredObjectQuery`) with a persisted anchor.
  - Each fetch advances the anchor and persists it in `UserDefaults`.
- This means:
  - first run does a backfill (until HealthKit returns no more samples)
  - subsequent runs continue from the last saved anchor

For live updates:

- An observer query (`HKObserverQuery`) triggers when new step samples appear.
- The app wakes the upload pipeline to enqueue/upload new data.

---

## Upload pipeline and outbox

### Outbox

Chunk files are stored in Application Support:

- `Outbox/pending/`
- `Outbox/uploading/`

On startup the outbox attempts recovery:

- any files found in `uploading/` are moved back to `pending/`

### Delivery semantics

- Uploads are **at-least-once**.
- Backend deduplicates duplicates, so retries are safe.

### Progress

UI progress is based on the date range of queued samples:

- start = earliest queued `startDate` at run start
- end = now
- current = earliest queued `startDate` remaining

Progress is capped at 99% until the sync completes.

---

## Background sync

- The app registers a `BGProcessingTask`.
- `BackgroundSyncCoordinator` checks whether there is pending work and whether the user paused.
- If there is still work after a run, it re-schedules the background task.

---

## Edge cases covered

- App killed/crash mid-upload: outbox recovery moves `uploading/` back to `pending/`.
- Network loss: pipeline pauses in `waitingForNetwork` and resumes when reachable.
- Repeated failures: enters ping-with-backoff mode.
- User pause/resume: respected both by UI and background coordinator.
- Reset sync:
  - cancels running tasks
  - clears outbox
  - resets HealthKit anchors

---

## Troubleshooting

### Device build fails (signing)

- In Xcode: set a Development Team for the target.
- Or use the script with a team id:
  - `./run_device.sh --team <TEAM_ID>`

### Backend not reachable

- Verify `BackendBaseURL`.
- Verify `/ping` returns 200.

### No samples uploaded

- Make sure Health permissions are granted.
- Verify the Health app has step data.
- On Simulator, try a physical device.
