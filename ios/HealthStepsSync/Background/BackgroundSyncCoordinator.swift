import Foundation
import BackgroundTasks

final class BackgroundSyncCoordinator {
  private let uploadManager: UploadManager
  private var currentWork: Task<Void, Never>?

  init(uploadManager: UploadManager) {
    self.uploadManager = uploadManager
  }

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
