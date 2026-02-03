import Foundation
import BackgroundTasks

/// Coordinates background processing tasks with the upload manager.
final class BackgroundSyncCoordinator {
  private let uploadManager: any UploadManaging
  private var currentWork: Task<Void, Never>?

  /// Creates a coordinator that uses the given upload manager.
  init(uploadManager: any UploadManaging) {
    self.uploadManager = uploadManager
  }

  /// Handles a BGProcessingTask by attempting to make forward progress on syncing.
  func handleProcessingTask(_ task: BGProcessingTask) {
    task.expirationHandler = {
      self.currentWork?.cancel()
    }

    currentWork = Task {
      let paused = await uploadManager.isPausedFlag()
      let pending = await uploadManager.hasPendingWork()

      if paused || !pending {
        task.setTaskCompleted(success: true)
        BackgroundScheduler.cancel()
        return
      }

      await uploadManager.startOrResume()
      let pausedAfter = await uploadManager.isPausedFlag()
      let pendingAfter = await uploadManager.hasPendingWork()
      if Task.isCancelled {
        task.setTaskCompleted(success: false)
        return
      }
      task.setTaskCompleted(success: true)

      if !pausedAfter && pendingAfter {
        BackgroundScheduler.schedule()
      } else {
        BackgroundScheduler.cancel()
      }
    }
  }
}
