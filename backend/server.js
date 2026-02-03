const fs = require('fs');
const path = require('path');

const express = require('express');
const cors = require('cors');

const app = express();

app.use(cors());
app.use(express.json({ limit: '10mb' }));

const DATA_DIR = path.join(__dirname, 'data');
const JSONL_PATH = path.join(DATA_DIR, 'steps.jsonl');
const SEEN_CHUNKS_PATH = path.join(DATA_DIR, 'seen_chunks.json');
const SEEN_SAMPLES_PATH = path.join(DATA_DIR, 'seen_samples.txt');

function ensureDataDir() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

function loadSeenChunks() {
  ensureDataDir();
  if (!fs.existsSync(SEEN_CHUNKS_PATH)) {
    return new Set();
  }

  try {
    const raw = fs.readFileSync(SEEN_CHUNKS_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return new Set();
    }
    return new Set(parsed);
  } catch (_) {
    return new Set();
  }
}

async function persistSeenChunks(seenChunksSet) {
  ensureDataDir();
  const asArray = Array.from(seenChunksSet);
  await fs.promises.writeFile(SEEN_CHUNKS_PATH, JSON.stringify(asArray, null, 2), 'utf8');
}

function loadSeenSamples() {
  ensureDataDir();
  if (!fs.existsSync(SEEN_SAMPLES_PATH)) {
    return new Set();
  }

  try {
    const raw = fs.readFileSync(SEEN_SAMPLES_PATH, 'utf8');
    const set = new Set();
    for (const line of raw.split('\n')) {
      const v = line.trim();
      if (v.length > 0) {
        set.add(v);
      }
    }
    return set;
  } catch (_) {
    return new Set();
  }
}

async function appendSeenSamples(uuids) {
  ensureDataDir();
  if (!uuids || uuids.length === 0) {
    return;
  }

  const payload = uuids.map((u) => `${u}\n`).join('');
  await fs.promises.appendFile(SEEN_SAMPLES_PATH, payload, 'utf8');
}

const seenChunks = loadSeenChunks();
const seenSamples = loadSeenSamples();

app.get('/ping', (_req, res) => {
  res.status(200).json({ ok: true });
});

app.post('/steps/chunk', async (req, res) => {
  const { chunkId, samples } = req.body ?? {};

  const startMs = Date.now();

  if (typeof chunkId !== 'string' || chunkId.length === 0) {
    return res.status(400).json({ ok: false, error: 'chunkId must be a non-empty string' });
  }

  if (!Array.isArray(samples)) {
    return res.status(400).json({ ok: false, error: 'samples must be an array' });
  }

  ensureDataDir();

  // If you manually delete data files while the server is running, the in-memory
  // sets can become out of sync (everything gets treated as already seen).
  // Detect that and reset the in-memory state.
  try {
    const chunksMissingOrEmpty = !fs.existsSync(SEEN_CHUNKS_PATH)
      || (fs.existsSync(SEEN_CHUNKS_PATH) && fs.statSync(SEEN_CHUNKS_PATH).size === 0);
    if (chunksMissingOrEmpty && seenChunks.size > 0) {
      console.log('[steps/chunk] seen_chunks.json missing/empty; clearing in-memory seenChunks');
      seenChunks.clear();
    }

    const samplesMissingOrEmpty = !fs.existsSync(SEEN_SAMPLES_PATH)
      || (fs.existsSync(SEEN_SAMPLES_PATH) && fs.statSync(SEEN_SAMPLES_PATH).size === 0);
    if (samplesMissingOrEmpty && seenSamples.size > 0) {
      console.log('[steps/chunk] seen_samples.txt missing/empty; clearing in-memory seenSamples');
      seenSamples.clear();
    }
  } catch (_) {
    // ignore
  }

  if (seenChunks.has(chunkId)) {
    console.log(`[steps/chunk] duplicate chunkId=${chunkId}`);
    return res.status(200).json({
      ok: true,
      duplicate: true,
      written: 0,
      skippedSeenSamples: 0,
      receivedSamples: samples.length,
      tookMs: Date.now() - startMs
    });
  }

  const receivedAt = new Date().toISOString();
  let lines = '';
  const newUuids = [];
  let written = 0;
  let skippedSeenSamples = 0;

  for (const sample of samples) {
    if (sample == null || typeof sample !== 'object') {
      return res.status(400).json({ ok: false, error: 'each sample must be an object' });
    }

    if (typeof sample.uuid !== 'string' || sample.uuid.length === 0) {
      return res.status(400).json({ ok: false, error: 'each sample must have non-empty uuid' });
    }

    if (seenSamples.has(sample.uuid)) {
      skippedSeenSamples += 1;
      continue;
    }

    seenSamples.add(sample.uuid);
    newUuids.push(sample.uuid);

    const record = {
      receivedAt,
      chunkId,
      ...sample
    };

    lines += `${JSON.stringify(record)}\n`;
    written += 1;
  }

  try {
    if (lines.length > 0) {
      await fs.promises.appendFile(JSONL_PATH, lines, 'utf8');
    }

    await appendSeenSamples(newUuids);
    seenChunks.add(chunkId);
    await persistSeenChunks(seenChunks);

    console.log(`[steps/chunk] chunkId=${chunkId} samples=${samples.length} written=${written} skippedSeenSamples=${skippedSeenSamples}`);

    return res.status(200).json({
      ok: true,
      duplicate: false,
      written,
      skippedSeenSamples,
      receivedSamples: samples.length,
      tookMs: Date.now() - startMs
    });
  } catch (err) {
    return res.status(500).json({ ok: false, error: err?.message ?? 'failed to persist data' });
  }
});

const port = Number(process.env.PORT ?? 3000);
app.listen(port, '0.0.0.0', () => {
  console.log(`Mock API listening on http://localhost:${port}`);
});
