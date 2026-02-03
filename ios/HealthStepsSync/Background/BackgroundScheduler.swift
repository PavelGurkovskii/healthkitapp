import Foundation
import BackgroundTasks

enum BackgroundScheduler {
  static let taskIdentifier = "com.pavlohurkovskyi.healthkitapp.processing"

  static func register(handler: @escaping (BGProcessingTask) -> Void) {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
      guard let processingTask = task as? BGProcessingTask else { return }
      handler(processingTask)
    }
  }

  static func schedule() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    let request = BGProcessingTaskRequest(identifier: taskIdentifier)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false

    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      return
    }
  }

  static func cancel() {
    BGTaskScheduler.shared.cancelAllTaskRequests()
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
  }
}
