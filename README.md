# HealthKit Steps Sync

This repository contains:

- **`ios/`**: Swift/SwiftUI iOS app that reads *raw* step samples from Apple Health (HealthKit) and uploads them to a backend.
- **`backend/`**: Node/Express backend that accepts step samples in chunks and persists them to disk.

The sync pipeline is designed for **at-least-once delivery** with server-side deduplication.

---

## Quick start

### Prerequisites

- **macOS** with **Xcode** installed.
- **Node.js + npm** (for backend).
- **Physical iPhone** recommended/required for real HealthKit data.
  - HealthKit data is not reliably available in Simulator.
- Optional: **ngrok** (for running backend on your Mac while the app runs on a physical iPhone).

### 1) Run backend locally

From repo root:

```bash
cd backend
npm install
npm start
```

Backend will listen on:

- `http://localhost:3000`

### 2) Run iOS app

Open:

- `ios/HealthKitApp.xcodeproj`

Then:

- Select a destination (device preferred).
- Run.

If you run on a **physical device** and backend is on your Mac:

- Either put both device and Mac on the same network and point `BackendBaseURL` to your Mac’s LAN IP.
- Or use `run_device.sh` which automatically starts backend + ngrok and sets `BackendBaseURL`.

---

## One-command device run (backend + ngrok + install on iPhone)

Script:

```bash
./run_device.sh --team <YOUR_TEAM_ID>
```

Optional flags:

- `--udid <device_udid>`: explicitly select a device.
- `--no-launch`: install but do not launch.
- `--ngrok-authtoken <token>`: configure ngrok token for this run.

You can also provide env vars:

- `TEAM_ID=<YOUR_TEAM_ID> ./run_device.sh`
- `NGROK_AUTHTOKEN=<token> ./run_device.sh --team <YOUR_TEAM_ID>`

Notes:

- **Do not commit tokens**. This repo’s `.gitignore` excludes ngrok runtime logs.
- The script will:
  - start backend and wait for `/ping`
  - start ngrok and discover HTTPS public URL
  - patch `ios/HealthKitApp/Info.plist` key `BackendBaseURL`
  - build with `xcodebuild` for the connected device using your `DEVELOPMENT_TEAM`
  - install & optionally launch the app

---

## Architecture overview

### Data flow

1. **HealthKit → iOS app**
   - `HealthStepsProvider` uses `HKAnchoredObjectQuery` for `.stepCount`.
   - It pages results by `limit` and persists the query anchor in `UserDefaults`.

2. **iOS Outbox (disk) → backend**
   - Samples are collected into chunks and written to disk in `Application Support/Outbox/`.
   - The outbox has `pending/` and `uploading/` directories.

3. **Upload manager**
   - `UploadManager` runs a producer/consumer pipeline:
     - **Producer** reads HealthKit samples and enqueues chunk files.
     - **Consumer** claims pending chunks and uploads them.
   - Both workers respond to:
     - pause/resume
     - network reachability
     - cancellations and background task expirations

### Progress reporting

Progress is reported as a value in `[0...1]`.

- It is computed based on a **date range**:
  - start = earliest `startDate` among queued samples at the beginning of a run
  - end = `now`
  - current = earliest `startDate` among remaining queued samples
- Progress is capped at `0.99` until sync completion, then set to `1.0`.

### Chunk sizing and buffering

- Chunk size is configured via `Info.plist` key **`UploadChunkSize`**.
  - If not set: default is `50`.
- The local outbox is bounded by `maxQueuedChunks` in `UploadManager` (default: `2`) to avoid unbounded buffering.

---

## Backend API

Endpoints:

- `GET /ping` → `200 { ok: true }`
- `POST /steps/chunk` → persists samples to `.jsonl`

Request body:

```json
{
  "chunkId": "<uuid>",
  "samples": [
    {
      "uuid": "...",
      "startDate": "2026-02-02T12:34:56.000Z",
      "endDate": "2026-02-02T12:35:56.000Z",
      "count": 42,
      "sourceBundleId": "com.apple.Health"
    }
  ]
}
```

Persisted files (created under `backend/data/`):

- `steps.jsonl` (1 JSON object per line)
- `seen_chunks.json` (chunkId dedup)
- `seen_samples.txt` (uuid dedup)
- `seen_periods.txt` (period-key dedup)

See `backend/README.md` for details.

---

## Edge cases handled

### iOS

- **At-least-once delivery**: upload retries can resend; backend dedups.
- **Crash / kill during upload**: on next start, outbox recovers `uploading/` files back to `pending/`.
- **Network loss**: uploader moves into `waitingForNetwork` and resumes when network is reachable.
- **Repeated failures**: after N failures it switches to `ping` gate with backoff and only continues after successful `GET /ping`.
- **Pause/resume**: UI and background coordinator respect paused state.
- **Reset sync**: cancels pipeline, clears outbox, resets HealthKit anchor; next run starts from scratch.

### Backend

- **Deduplication**: by `chunkId`, by sample `uuid`, and by a period key derived from `(startDate,endDate,count,sourceBundleId)`.
- **Manual deletion of backend data files**: server detects missing/empty dedup files and clears in-memory state so it can write again.

---

## Troubleshooting

### Device build fails with signing error

- Provide a valid Apple Team ID:
  - `./run_device.sh --team <TEAM_ID>`
  - or `TEAM_ID=<TEAM_ID> ./run_device.sh`

### `Port 3000 is already in use`

- Stop the process using port `3000` or change the backend port (requires code change).

### ngrok errors (e.g. `ERR_NGROK_105`)

- Provide a valid token:
  - `./run_device.sh --ngrok-authtoken <TOKEN> --team <TEAM_ID>`
  - or `NGROK_AUTHTOKEN=<TOKEN> ./run_device.sh --team <TEAM_ID>`

### HealthKit permission denied / no data

- Ensure Health permissions are granted for the app.
- On Simulator, HealthKit data may be unavailable.

---

## More details

- iOS setup and capabilities: `ios/README.md`
- Backend specifics and file formats: `backend/README.md`
