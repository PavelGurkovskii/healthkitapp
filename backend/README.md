# Backend

This backend is a small Node/Express server that accepts step samples in **chunks** and persists them to disk.

It is intentionally simple and file-backed so you can inspect what the iOS app is uploading.

---

## Prerequisites

- Node.js
- npm

---

## Run

From repo root:

```bash
cd backend
npm install
npm start
```

Server starts on:

- `http://localhost:3000`

Health check:

- `GET http://localhost:3000/ping`

---

## API

### `GET /ping`

Returns `200` if the server is reachable.

This is used by the iOS app to detect when uploads can resume after repeated failures.

### `POST /steps/chunk`

Accepts a chunk of samples.

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

Response (fields may be omitted depending on the backend version):

- `ok`: boolean
- `duplicate`: boolean (chunk-level duplicate)
- `written`: number of samples written to `steps.jsonl`
- `skippedSeenSamples`: number of samples skipped due to dedup
- `receivedSamples`: number of samples received
- `tookMs`: processing time

---

## Persistence and data files

All persistent files live under:

- `backend/data/`

### `steps.jsonl`

Append-only data file.

- One JSON object per line.
- Each line corresponds to one raw `StepSampleDTO`.

### Deduplication files

The backend implements deduplication to support the iOS app’s **at-least-once** delivery semantics.

- `seen_chunks.json`
  - JSON array of processed `chunkId` values.
  - If a `chunkId` is seen again, the whole request may be treated as duplicate.

- `seen_samples.txt`
  - One sample `uuid` per line.
  - If a sample uuid is seen again, it is not written again.

- `seen_periods.txt`
  - One “period key” per line.
  - The period key is derived from:
    - `startDate`
    - `endDate`
    - `count`
    - `sourceBundleId`
  - This additionally protects against duplicates if sample UUID behavior changes.

---

## Edge cases handled

### At-least-once uploads and retries

The iOS app may retry uploads (for example after timeouts or process restarts). The backend is designed to be idempotent in practice by using the dedup files above.

### Manual deletion of `backend/data/*`

If you manually delete `steps.jsonl` or any of the `seen_*` files while the backend is running:

- On startup, the backend checks the dedup files.
- If a dedup file is **missing** or **empty**, in-memory state is cleared for that dedup set.

Practical advice:

- If you want a clean run, delete `backend/data/*` and restart the backend.

### Partial writes / crashes

- `steps.jsonl` is append-only. If a crash occurs mid-run, already-written lines remain.
- Dedup files are updated as uploads arrive; restarting the server will reload them.

---

## Troubleshooting

### `npm start` fails

- Verify Node.js and npm are installed.
- Remove and reinstall deps:

```bash
rm -rf node_modules
npm install
```

### `Port 3000 is already in use`

Stop the process using port 3000 or change the backend port (requires code change on both backend and iOS configuration).
