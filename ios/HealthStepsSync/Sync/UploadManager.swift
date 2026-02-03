import Foundation

/// Protocol defining the interface of the sync/upload manager.
protocol UploadManaging: Actor {
  func makeLogStream() -> AsyncStream<String>
  func makeProgressStream() -> AsyncStream<Double>

  func resetProgressForNewRun() async
  func notifyHealthDataChanged() async
  func setNetworkReachable(_ reachable: Bool) async
  func startOrResume() async

  func pause() async
  func resume() async

  func isSyncComplete() async -> Bool
  func hasPendingWork() async -> Bool
  func isPausedFlag() async -> Bool

  func stop() async
  func resetSync() async
}

actor UploadManager: UploadManaging {
  enum State: Equatable {
    case idle
    case waitingForNetwork
    case loadingLocalData
    case uploading
    case backingOff
    case pinging
    case paused
    case stopped
  }

  private(set) var state: State = .idle

  private var logContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
  private var progressContinuations: [UUID: AsyncStream<Double>.Continuation] = [:]
  private var progressTotal: Int = 0
  private var progressUploaded: Int = 0
  private let analysisProgressWeight: Double = 0.4
  private var lastProgress: Double = 0

  private var progressRangeStartDate: Date?
  private var progressRangeEndDate: Date?

  private var cachedEarliestQueuedSampleStartDate: Date?
  private var isEarliestQueuedSampleStartDateDirty: Bool = true

  private var isPaused: Bool = false

  private let stepsProvider: any StepsProviding
  private let outbox: any OutboxStoring
  private let api: any StepsAPIClient

  private var isNetworkReachable: Bool = true
  private var consecutiveUploadFailures: Int = 0

  private var reachedEndOfHealthData: Bool = false
  private var didLogNoWorkIdle: Bool = false

  private var syncRunTask: Task<Void, Never>?

  private var wakeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  private let chunkSize: Int
  private let maxQueuedChunks: Int

  init(
    stepsProvider: any StepsProviding,
    outbox: any OutboxStoring,
    api: any StepsAPIClient,
    chunkSize: Int = 1000,
    maxQueuedChunks: Int = 2
  ) {
    self.stepsProvider = stepsProvider
    self.outbox = outbox
    self.api = api
    self.chunkSize = chunkSize
    self.maxQueuedChunks = maxQueuedChunks
  }

  /// Creates a stream of log lines describing sync activity.
  func makeLogStream() -> AsyncStream<String> {
    AsyncStream { continuation in
      let id = UUID()
      logContinuations[id] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeLogContinuation(id: id) }
      }

      isEarliestQueuedSampleStartDateDirty = true
    }
  }

  private func emitDateRangeProgressIfPossible() {
    updateProgressRangeIfNeeded()

    guard let start = progressRangeStartDate, let end = progressRangeEndDate else {
      return
    }

    let total = end.timeIntervalSince(start)
    guard total > 0 else {
      emitProgress(0)
      return
    }

    let earliestQueued = earliestQueuedSampleStartDateCached()

    if earliestQueued == nil {
      if reachedEndOfHealthData {
        emitProgress(0.99)
      }
      return
    }

    let clamped = min(max(earliestQueued!, start), end)
    let ratio = min(1, max(0, clamped.timeIntervalSince(start) / total))
    emitProgress(min(0.99, ratio))
  }

  private func updateProgressRangeIfNeeded() {
    progressRangeEndDate = Date()

    if progressRangeStartDate == nil {
      progressRangeStartDate = earliestQueuedSampleStartDateCached()
    }
  }

  private func earliestQueuedSampleStartDateCached() -> Date? {
    if !isEarliestQueuedSampleStartDateDirty {
      return cachedEarliestQueuedSampleStartDate
    }

    let earliest = (try? outbox.earliestQueuedSampleStartDate()) ?? nil
    cachedEarliestQueuedSampleStartDate = earliest
    isEarliestQueuedSampleStartDateDirty = false
    return earliest
  }

  /// Creates a stream of progress updates in the range [0...1].
  func makeProgressStream() -> AsyncStream<Double> {
    AsyncStream { continuation in
      let id = UUID()
      progressContinuations[id] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeProgressContinuation(id: id) }
      }
    }
  }

  /// Resets progress state for a new sync run.
  func resetProgressForNewRun() async {
    lastProgress = 0
    progressRangeStartDate = nil
    progressRangeEndDate = nil
    cachedEarliestQueuedSampleStartDate = nil
    isEarliestQueuedSampleStartDateDirty = true
    emitProgress(0)
  }

  /// Notifies the manager that new HealthKit data may be available.
  func notifyHealthDataChanged() async {
    log("Health data changed")
    reachedEndOfHealthData = false
    didLogNoWorkIdle = false
    wakeAll()
  }

  /// Updates reachability and wakes workers.
  func setNetworkReachable(_ reachable: Bool) async {
    isNetworkReachable = reachable
    if reachable {
      log("Network reachable")
      wakeAll()

      if state == .waitingForNetwork {
        await startOrResume()
      }
    } else {
      log("Network unreachable; waiting")
      state = .waitingForNetwork
      wakeAll()
    }
  }

  /// Starts the sync pipeline or resumes it if it was paused.
  func startOrResume() async {
    guard state != .stopped else { return }

    if syncRunTask != nil {
      return
    }

    log("Start/resume")

    if Task.isCancelled {
      state = .idle
      log("Cancelled")
      return
    }

    if !isNetworkReachable {
      state = .waitingForNetwork
      log("Waiting for network")
      return
    }

    if isPaused {
      state = .paused
      log("Paused")
      return
    }

    if await isSyncComplete() {
      state = .idle
      emitProgress(1)
      log("Already synced")
      return
    }

    emitProgress(0)

    let task = Task { await self.runSyncPipeline() }
    syncRunTask = task
    await task.value
  }

  /// Pauses the sync pipeline.
  func pause() async {
    guard state != .stopped else { return }
    isPaused = true
    state = .paused
    log("Paused")
    wakeAll()
  }

  /// Resumes the sync pipeline.
  func resume() async {
    guard state != .stopped else { return }
    isPaused = false
    if state == .paused {
      state = .idle
    }
    log("Resumed")
    wakeAll()
  }

  func isSyncComplete() async -> Bool {
    let queued = (try? outbox.queuedChunksCount()) ?? 0
    return queued == 0 && reachedEndOfHealthData
  }

  func hasPendingWork() async -> Bool {
    let queued = (try? outbox.queuedChunksCount()) ?? 0
    return queued > 0 || !reachedEndOfHealthData
  }

  func isPausedFlag() async -> Bool {
    isPaused
  }

  /// Stops the sync pipeline.
  func stop() async {
    state = .stopped
    log("Stopped")
    syncRunTask?.cancel()
    wakeAll()
  }

  /// Resets all sync state and clears the outbox.
  func resetSync() async {
    let task = syncRunTask
    task?.cancel()
    wakeAll()
    await task?.value

    isPaused = false
    consecutiveUploadFailures = 0
    reachedEndOfHealthData = false
    progressTotal = 0
    progressUploaded = 0
    lastProgress = 0
    progressRangeStartDate = nil
    progressRangeEndDate = nil
    cachedEarliestQueuedSampleStartDate = nil
    isEarliestQueuedSampleStartDateDirty = true
    emitProgress(0)

    log("Reset sync")

    do {
      try outbox.reset()
      cachedEarliestQueuedSampleStartDate = nil
      isEarliestQueuedSampleStartDateDirty = true
    } catch {
      log("Failed to reset outbox: \(String(describing: error))")
    }
    stepsProvider.resetAllAnchors()
    state = .idle
    wakeAll()
  }

  private func runSyncPipeline() async {
    defer {
      syncRunTask = nil
    }

    didLogNoWorkIdle = false

    async let ingest: Void = ingestWorker()
    async let upload: Void = uploadWorker()

    _ = await (ingest, upload)

    if state == .waitingForNetwork || state == .paused || state == .stopped {
      return
    }

    let queued = (try? outbox.queuedChunksCount()) ?? 0
    if queued == 0, reachedEndOfHealthData {
      state = .idle
      emitProgress(1)
      log("Sync completed")
    }
  }

  private func ingestWorker() async {
    while true {
      if state == .stopped {
        return
      }

      if Task.isCancelled {
        state = .idle
        log("Cancelled")
        return
      }

      if isPaused {
        state = .paused
        log("Paused")
        return
      }

      if !isNetworkReachable {
        state = .waitingForNetwork
        log("Waiting for network")
        return
      }

      let queued = (try? outbox.queuedChunksCount()) ?? 0
      if queued >= maxQueuedChunks {
        await waitForWakeOrTimeout(0.5)
        continue
      }

      state = .loadingLocalData
      emitProgress(0)

      do {
        try await ingestGlobalToOutbox()
      } catch {
        state = .backingOff
        log("Failed to load local data: \(String(describing: error))")
        await waitForWakeOrTimeout(2)
        continue
      }

      emitDateRangeProgressIfPossible()

      if reachedEndOfHealthData {
        return
      }
    }
  }

  private func uploadWorker() async {
    var didLogUploadConfig = false

    emitDateRangeProgressIfPossible()

    while true {
      if state == .stopped {
        return
      }

      if Task.isCancelled {
        state = .idle
        log("Cancelled")
        return
      }

      if isPaused {
        state = .paused
        log("Paused")
        return
      }

      if !isNetworkReachable {
        state = .waitingForNetwork
        log("Waiting for network")
        return
      }

      guard let chunk = (try? outbox.claimNextPendingChunk()) else {
        let queued = (try? outbox.queuedChunksCount()) ?? 0
        if queued == 0, reachedEndOfHealthData {
          return
        }

        state = .idle
        if !didLogNoWorkIdle {
          didLogNoWorkIdle = true
          log("No queued chunks; waiting for new data")
        }
        await waitForWakeOrTimeout(1)
        continue
      }

      didLogNoWorkIdle = false
      state = .uploading
      if !didLogUploadConfig {
        didLogUploadConfig = true
        log("Uploading")
        log("Upload config: chunkSize=\(chunkSize)")
      }

      let filteredSamples = chunk.samples.filter { $0.count > 0 }
      if filteredSamples.isEmpty {
        do {
          try outbox.markUploaded(chunk: chunk)
          consecutiveUploadFailures = 0
          wakeAll()

          isEarliestQueuedSampleStartDateDirty = true

          emitDateRangeProgressIfPossible()
        } catch {
          log("Failed to drop empty chunk \(chunk.chunkId): \(String(describing: error))")
        }
        continue
      }

      do {
        let filteredChunk = OutboxChunk(
          chunkId: chunk.chunkId,
          createdAt: chunk.createdAt,
          attemptCount: chunk.attemptCount,
          samples: filteredSamples
        )
        log("Uploading chunk \(chunk.chunkId) (samples: \(filteredSamples.count))")
        let resp = try await api.upload(chunk: filteredChunk)
        try outbox.markUploaded(chunk: chunk)
        consecutiveUploadFailures = 0
        wakeAll()

        isEarliestQueuedSampleStartDateDirty = true

        emitDateRangeProgressIfPossible()

        let received = resp.receivedSamples ?? filteredSamples.count
        let written = resp.written ?? -1
        let skipped = resp.skippedSeenSamples ?? -1
        let took = resp.tookMs ?? -1
        let duplicate = resp.duplicate ?? false
        log("Uploaded chunk \(chunk.chunkId) (received: \(received), written: \(written), skipped: \(skipped), duplicate: \(duplicate), tookMs: \(took))")
      } catch {
        do {
          try outbox.markFailedAndReturnToPending(chunk: chunk)
          isEarliestQueuedSampleStartDateDirty = true
        } catch {
          log("Failed to requeue chunk \(chunk.chunkId): \(String(describing: error))")
        }
        wakeAll()

        consecutiveUploadFailures += 1
        log("Failed to upload chunk \(chunk.chunkId): \(String(describing: error))")

        if consecutiveUploadFailures >= 3 {
          await pingUntilReachable()
        } else {
          state = .backingOff
          let delay = computeUploadBackoffSeconds()
          log("Backing off \(delay)s (upload)")
          await waitForWakeOrTimeout(delay)
        }
      }
    }
  }

  private func pingUntilReachable() async {
    state = .pinging
    log("Pinging")

    while true {
      if Task.isCancelled {
        state = .idle
        return
      }

      if isPaused {
        state = .paused
        log("Paused")
        return
      }

      if !isNetworkReachable {
        state = .waitingForNetwork
        return
      }

      let delay = computePingBackoffSeconds()
      await waitForWakeOrTimeout(delay)

      do {
        try await api.ping()
        consecutiveUploadFailures = 0
        log("Ping successful")
        return
      } catch {
        consecutiveUploadFailures += 1
        log("Ping failed: \(String(describing: error))")
        continue
      }
    }
  }

  private func wakeAll() {
    let waiters = wakeWaiters
    wakeWaiters.removeAll()
    for c in waiters.values {
      c.resume()
    }
  }

  private func removeWakeWaiter(id: UUID) {
    wakeWaiters.removeValue(forKey: id)
  }

  private func cancelWakeWaiter(id: UUID) {
    if let cont = wakeWaiters.removeValue(forKey: id) {
      cont.resume()
    }
  }

  private func waitForWake() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        wakeWaiters[id] = cont
      }
    } onCancel: {
      Task { await self.cancelWakeWaiter(id: id) }
    }
  }

  private func waitForWakeOrTimeout(_ seconds: Double) async {
    let ns = UInt64(max(0, seconds) * 1_000_000_000)
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.waitForWake() }
      group.addTask {
        try? await Task.sleep(nanoseconds: ns)
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  private func ensureLocalDataEnqueuedIfNeeded() async {
    state = .loadingLocalData
    log("Loading local data")
    emitProgress(0)

    do {
      try await ingestGlobalToOutbox()
    } catch {
      await backoffThenRetryStart()
      return
    }

    emitDateRangeProgressIfPossible()
  }

  private func ingestGlobalToOutbox() async throws {
    while true {
      if Task.isCancelled {
        state = .idle
        return
      }

      if isPaused {
        state = .paused
        log("Paused")
        return
      }

      do {
        let queued = try outbox.queuedChunksCount()
        if queued >= maxQueuedChunks {
          log("Outbox is full (queued: \(queued)); skipping enqueue")
          return
        }
      } catch {
        return
      }

      var exhausted = false
      var collected: [StepSampleDTO] = []

      while collected.count < chunkSize {
        let remaining = max(1, chunkSize - collected.count)
        let batch = try await stepsProvider.fetchNextBatch(limit: remaining)
        if batch.isEmpty {
          exhausted = true
          break
        }

        let filtered = batch.filter { $0.count > 0 }
        if filtered.isEmpty {
          continue
        }

        collected.append(contentsOf: filtered)
      }

      if collected.isEmpty {
        if exhausted {
          reachedEndOfHealthData = true
          wakeAll()
        }
        return
      }

      let sorted = collected.sorted { lhs, rhs in
        let ld = ISO8601.formatter.date(from: lhs.startDate) ?? .distantPast
        let rd = ISO8601.formatter.date(from: rhs.startDate) ?? .distantPast
        return ld < rd
      }

      _ = try outbox.enqueueChunk(samples: sorted)
      isEarliestQueuedSampleStartDateDirty = true
      reachedEndOfHealthData = false
      wakeAll()

      emitDateRangeProgressIfPossible()
    }
  }

  private func uploadLoop() async {
    guard state != .stopped else { return }

    if Task.isCancelled {
      state = .idle
      return
    }

    if isPaused {
      state = .paused
      log("Paused")
      return
    }

    if !isNetworkReachable {
      state = .waitingForNetwork
      log("Waiting for network")
      return
    }

    state = .uploading
    log("Uploading")
    log("Upload config: chunkSize=\(chunkSize)")

    emitDateRangeProgressIfPossible()

    while state == .uploading {
      if Task.isCancelled {
        state = .idle
        log("Cancelled")
        return
      }

      if isPaused {
        state = .paused
        log("Paused")
        return
      }

      if !isNetworkReachable {
        state = .waitingForNetwork
        log("Waiting for network")
        return
      }

      do {
        guard let chunk = try outbox.claimNextPendingChunk() else {
          state = .idle
          log("Outbox empty")
          return
        }

        let filteredSamples = chunk.samples.filter { $0.count > 0 }
        if filteredSamples.isEmpty {
          try outbox.markUploaded(chunk: chunk)
          consecutiveUploadFailures = 0

          emitDateRangeProgressIfPossible()
          log("Skipped empty chunk \(chunk.chunkId) after filtering zero-step samples")
          continue
        }

        do {
          let filteredChunk = OutboxChunk(
            chunkId: chunk.chunkId,
            createdAt: chunk.createdAt,
            attemptCount: chunk.attemptCount,
            samples: filteredSamples
          )
          log("Uploading chunk \(chunk.chunkId) (samples: \(filteredSamples.count))")
          let resp = try await api.upload(chunk: filteredChunk)
          try outbox.markUploaded(chunk: chunk)
          consecutiveUploadFailures = 0

          emitDateRangeProgressIfPossible()
          let received = resp.receivedSamples ?? filteredSamples.count
          let written = resp.written ?? -1
          let skipped = resp.skippedSeenSamples ?? -1
          let took = resp.tookMs ?? -1
          let duplicate = resp.duplicate ?? false
          log("Uploaded chunk \(chunk.chunkId) (received: \(received), written: \(written), skipped: \(skipped), duplicate: \(duplicate), tookMs: \(took))")
        } catch {
          try outbox.markFailedAndReturnToPending(chunk: chunk)
          consecutiveUploadFailures += 1
          log("Failed to upload chunk \(chunk.chunkId): \(String(describing: error))")

          if consecutiveUploadFailures >= 3 {
            await pingGateLoop()
          } else {
            await backoffThenRetryUploads()
          }
        }
      } catch {
        log("Upload loop error: \(String(describing: error))")
        await backoffThenRetryUploads()
      }
    }
  }

  private func backoffThenRetryStart() async {
    state = .backingOff
    let delay = computeUploadBackoffSeconds()
    log("Backing off \(delay)s (start)")
    do {
      try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    } catch {
      state = .idle
      log("Cancelled")
      return
    }

    if isPaused {
      state = .paused
      log("Paused")
      return
    }
    await startOrResume()
  }

  private func backoffThenRetryUploads() async {
    state = .backingOff
    let delay = computeUploadBackoffSeconds()
    log("Backing off \(delay)s (upload)")
    do {
      try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    } catch {
      state = .idle
      log("Cancelled")
      return
    }

    if isPaused {
      state = .paused
      log("Paused")
      return
    }
    await uploadLoop()
  }

  private func pingGateLoop() async {
    state = .pinging
    log("Pinging")

    while true {
      if Task.isCancelled {
        state = .idle
        return
      }

      if isPaused {
        state = .paused
        log("Paused")
        return
      }

      if !isNetworkReachable {
        state = .waitingForNetwork
        return
      }

      let delay = computePingBackoffSeconds()
      do {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      } catch {
        state = .idle
        log("Cancelled")
        return
      }

      do {
        try await api.ping()
        consecutiveUploadFailures = 0
        log("Ping successful")
        await uploadLoop()
        return
      } catch {
        consecutiveUploadFailures += 1
        log("Ping failed: \(String(describing: error))")
        continue
      }
    }
  }

  private func log(_ message: String) {
    let ts = ISO8601.string(from: Date())
    let line = "[\(ts)] \(message)"
    for c in logContinuations.values {
      c.yield(line)
    }
  }

  private func emitProgress(_ progress: Double) {
    let p = max(lastProgress, progress)
    lastProgress = p
    for c in progressContinuations.values {
      c.yield(p)
    }
  }

  private func removeLogContinuation(id: UUID) {
    logContinuations.removeValue(forKey: id)
  }

  private func removeProgressContinuation(id: UUID) {
    progressContinuations.removeValue(forKey: id)
  }

  private func computeUploadBackoffSeconds() -> Double {
    let n = max(1, min(consecutiveUploadFailures, 10))
    return min(pow(2.0, Double(n)), 60.0)
  }

  private func computePingBackoffSeconds() -> Double {
    let extraFailures = max(0, consecutiveUploadFailures - 3)
    return min(30.0 * pow(2.0, Double(extraFailures)), 300.0)
  }
}
