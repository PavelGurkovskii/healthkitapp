import Foundation

/// Protocol defining the interface for an outbox used to persist upload chunks.
protocol OutboxStoring: AnyObject {
  /// Returns the number of queued chunks (pending + uploading).
  func queuedChunksCount() throws -> Int

  /// Returns the earliest `startDate` among queued chunks.
  func earliestQueuedSampleStartDate() throws -> Date?

  /// Enqueues a new chunk built from already-sorted samples.
  func enqueueChunk(samples: [StepSampleDTO]) throws -> OutboxChunk

  /// Claims the next pending chunk and moves it to the uploading state.
  func claimNextPendingChunk() throws -> OutboxChunk?

  /// Marks a chunk as uploaded (removes it from uploading).
  func markUploaded(chunk: OutboxChunk) throws

  /// Marks a chunk upload attempt as failed and returns it back to pending.
  func markFailedAndReturnToPending(chunk: OutboxChunk) throws

  /// Clears all outbox state.
  func reset() throws
}

final class FileOutboxStore: OutboxStoring {
  enum StoreError: Error {
    case failedToCreateDirectories
    case failedToMoveChunk
    case invalidChunk
    case failedToRecoverUploadingChunks
  }

  private let fileManager: FileManager
  private let rootURL: URL

  private var pendingURL: URL { rootURL.appendingPathComponent("pending", isDirectory: true) }
  private var uploadingURL: URL { rootURL.appendingPathComponent("uploading", isDirectory: true) }

  init(fileManager: FileManager = .default) throws {
    self.fileManager = fileManager

    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )

    self.rootURL = base.appendingPathComponent("Outbox", isDirectory: true)
    try ensureDirectories()
    try recoverUploadingToPending()
  }

  /// Returns the total number of chunks currently queued for upload.
  func queuedChunksCount() throws -> Int {
    let pending = try fileManager.contentsOfDirectory(at: pendingURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count
    let uploading = try fileManager.contentsOfDirectory(at: uploadingURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count
    return pending + uploading
  }

  /// Returns the earliest sample start date among all queued chunks.
  ///
  /// Note: samples inside a chunk are expected to be sorted by `startDate`, so we only inspect the first sample.
  func earliestQueuedSampleStartDate() throws -> Date? {
    let urls = try allQueuedChunkURLs()
    var earliest: Date?

    for url in urls {
      let chunk = try readChunk(at: url)
      guard let sample = chunk.samples.first else { continue }
      guard let d = ISO8601.date(from: sample.startDate) else { continue }
      if let current = earliest {
        if d < current { earliest = d }
      } else {
        earliest = d
      }
    }

    return earliest
  }

  func ensureDirectories() throws {
    do {
      try fileManager.createDirectory(at: pendingURL, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: uploadingURL, withIntermediateDirectories: true)
    } catch {
      throw StoreError.failedToCreateDirectories
    }
  }

  private func allQueuedChunkURLs() throws -> [URL] {
    let pending = try fileManager.contentsOfDirectory(at: pendingURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    let uploading = try fileManager.contentsOfDirectory(at: uploadingURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    return pending + uploading
  }

  private func recoverUploadingToPending() throws {
    do {
      let urls = try fileManager.contentsOfDirectory(at: uploadingURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      for url in urls {
        let dest = pendingURL.appendingPathComponent(url.lastPathComponent, isDirectory: false)

        if fileManager.fileExists(atPath: dest.path) {
          try? fileManager.removeItem(at: url)
          continue
        }

        do {
          try fileManager.moveItem(at: url, to: dest)
        } catch {
          do {
            try fileManager.copyItem(at: url, to: dest)
            try fileManager.removeItem(at: url)
          } catch {
            throw StoreError.failedToRecoverUploadingChunks
          }
        }
      }
    } catch {
      throw StoreError.failedToRecoverUploadingChunks
    }
  }

  /// Enqueues a new chunk into the pending queue.
  func enqueueChunk(samples: [StepSampleDTO]) throws -> OutboxChunk {
    let chunk = OutboxChunk(
      chunkId: UUID().uuidString,
      createdAt: ISO8601.string(from: Date()),
      attemptCount: 0,
      samples: samples
    )

    let url = pendingURL.appendingPathComponent(filename(for: chunk), isDirectory: false)
    try write(chunk: chunk, to: url)
    return chunk
  }

  /// Moves the oldest pending chunk to uploading and returns it.
  func claimNextPendingChunk() throws -> OutboxChunk? {
    let urls = try fileManager.contentsOfDirectory(at: pendingURL, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])

    let sorted = try urls.sorted { lhs, rhs in
      let lDate = try lhs.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
      let rDate = try rhs.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
      return lDate < rDate
    }

    guard let next = sorted.first else { return nil }

    let chunk = try readChunk(at: next)
    let dest = uploadingURL.appendingPathComponent(next.lastPathComponent, isDirectory: false)

    do {
      try fileManager.moveItem(at: next, to: dest)
    } catch {
      throw StoreError.failedToMoveChunk
    }

    return chunk
  }

  /// Removes a chunk from the uploading queue after successful upload.
  func markUploaded(chunk: OutboxChunk) throws {
    let url = uploadingURL.appendingPathComponent(filename(for: chunk), isDirectory: false)
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  /// Increments attempt count and moves the chunk back from uploading to pending.
  func markFailedAndReturnToPending(chunk: OutboxChunk) throws {
    var updated = chunk
    updated.attemptCount += 1

    let from = uploadingURL.appendingPathComponent(filename(for: chunk), isDirectory: false)
    let to = pendingURL.appendingPathComponent(filename(for: updated), isDirectory: false)

    try write(chunk: updated, to: from)

    do {
      try fileManager.moveItem(at: from, to: to)
    } catch {
      throw StoreError.failedToMoveChunk
    }
  }

  /// Clears pending and uploading directories and recreates them.
  func reset() throws {
    if fileManager.fileExists(atPath: pendingURL.path) {
      try? fileManager.removeItem(at: pendingURL)
    }
    if fileManager.fileExists(atPath: uploadingURL.path) {
      try? fileManager.removeItem(at: uploadingURL)
    }
    try ensureDirectories()
  }

  private func filename(for chunk: OutboxChunk) -> String {
    "\(chunk.chunkId).json"
  }

  private func write(chunk: OutboxChunk, to url: URL) throws {
    let data = try JSONEncoder().encode(chunk)
    let tmp = url.appendingPathExtension("tmp")
    try data.write(to: tmp, options: [.atomic])
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    try fileManager.moveItem(at: tmp, to: url)
  }

  private func readChunk(at url: URL) throws -> OutboxChunk {
    let data = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(OutboxChunk.self, from: data)
    return decoded
  }
}
