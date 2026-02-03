import Foundation
import Combine
import HealthKit

final class AppEnvironment: ObservableObject {
  private let healthStore: HKHealthStore
  private let stepsProvider: HealthStepsProvider
  private let outbox: FileOutboxStore
  private let api: APIClient
  private let uploadManager: UploadManager
  private let networkMonitor: NetworkMonitor
  private let backgroundCoordinator: BackgroundSyncCoordinator

  private static func loadBackendBaseURL() -> URL {
    if let raw = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
       let url = URL(string: raw) {
      return url
    }
    return URL(string: "http://localhost:3000")!
  }

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
  func makeViewModel() -> SyncViewModel {
    SyncViewModel(stepsProvider: stepsProvider, networkMonitor: networkMonitor, uploadManager: uploadManager)
  }
}
