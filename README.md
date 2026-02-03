# iOS Health steps sync

## Overview

This repo contains:

- `backend/`: Node/Express mock API that accepts raw step samples in chunks and persists them to a `.jsonl` file (1 sample per line).
- `ios/`: iOS app source code skeleton (Swift/SwiftUI) that reads **raw** step samples from Apple Health and syncs them via a state-machine uploader.

## Assumptions / Scope

- Chunking is by **number of samples** (default: 1000 samples per chunk).
- Delivery semantics are **at-least-once**. The backend implements deduplication by `chunkId` and by sample `uuid`.
- Samples are written as **1 JSON object per line** in `backend/data/steps.jsonl`.
- Background execution is implemented using `BGProcessingTask` + retry/ping state machine.

For live updates the iOS app re-scans the last 7 days; the backend prevents duplicates via sample `uuid` dedup.

---

## Backend

### Endpoints

- `GET /ping` -> `200 { ok: true }`
- `POST /steps/chunk` -> persists samples to `.jsonl`

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

### Run

From `backend/`:

- `npm install`
- `npm start`

Server listens on `http://localhost:3000`.

Data files:

- `backend/data/steps.jsonl`
- `backend/data/seen_chunks.json`
- `backend/data/seen_samples.txt`

---

## iOS

See `ios/README.md`.
