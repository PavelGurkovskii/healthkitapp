import Foundation
import Combine
import HealthKit

/// Root dependency container for the app.
final class AppEnvironment: ObservableObject {
  private let healthStore: HKHealthStore
  private let stepsProvider: any StepsProviding
  private let outbox: any OutboxStoring
  private let api: any StepsAPIClient
  private let uploadManager: any UploadManaging
  private let networkMonitor: any NetworkMonitoring
  private let backgroundCoordinator: BackgroundSyncCoordinator

  /// Loads Backend base URL from Info.plist.
  private static func loadBackendBaseURL() -> URL {
    if let raw = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
       let url = URL(string: raw) {
      return url
    }
    return URL(string: "http://localhost:3000")!
  }

  /// Loads max upload chunk size from Info.plist.
  private static func loadUploadChunkSize() -> Int {
    if let raw = Bundle.main.object(forInfoDictionaryKey: "UploadChunkSize") as? NSNumber {
      let v = raw.intValue
      return max(1, min(v, 5000))
    }
    if let raw = Bundle.main.object(forInfoDictionaryKey: "UploadChunkSize") as? Int {
      return max(1, min(raw, 5000))
    }
    return 50
  }

  init() {
    self.healthStore = HKHealthStore()
    self.stepsProvider = HealthStepsProvider(healthStore: healthStore)

    do {
      self.outbox = try FileOutboxStore()
    } catch {
      fatalError("Failed to initialize outbox")
    }

    self.api = APIClient(config: .init(baseURL: Self.loadBackendBaseURL()))
    self.uploadManager = UploadManager(
      stepsProvider: stepsProvider,
      outbox: outbox,
      api: api,
      chunkSize: Self.loadUploadChunkSize()
    )
    self.networkMonitor = NetworkMonitor()
    self.backgroundCoordinator = BackgroundSyncCoordinator(uploadManager: uploadManager)

    BackgroundScheduler.register { [weak self] task in
      guard let self else { return }
      self.backgroundCoordinator.handleProcessingTask(task)
    }
  }

  @MainActor
  /// Creates a view model for the root UI.
  func makeViewModel() -> SyncViewModel {
    SyncViewModel(stepsProvider: stepsProvider, networkMonitor: networkMonitor, uploadManager: uploadManager)
  }
}
