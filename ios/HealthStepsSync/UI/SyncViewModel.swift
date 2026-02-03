import Foundation
import Combine

@MainActor
final class SyncViewModel: ObservableObject {
  enum ControlState: Equatable {
    case idle
    case syncing
    case paused
    case success
  }

  var shouldShowResetButton: Bool {
    controlState == .success
  }

  @Published var status: String = "Idle"
  @Published var progressPercent: Int = 0
  @Published var logs: [String] = []
  @Published private(set) var controlState: ControlState = .idle

  private let stepsProvider: any StepsProviding
  private let networkMonitor: any NetworkMonitoring
  private let uploadManager: any UploadManaging

  private let defaults: UserDefaults
  private let pausedKey = "HealthStepsSync.userPaused"

  private var isObserverStarted = false
  private var syncTask: Task<Void, Never>?
  private var hasNewData: Bool = false
  private var userPaused: Bool = false

  /// Creates a view model that drives the sync UI.
  init(
    stepsProvider: any StepsProviding,
    networkMonitor: any NetworkMonitoring,
    uploadManager: any UploadManaging,
    defaults: UserDefaults = .standard
  ) {
    self.stepsProvider = stepsProvider
    self.networkMonitor = networkMonitor
    self.uploadManager = uploadManager
    self.defaults = defaults
    self.userPaused = defaults.bool(forKey: pausedKey)

    self.networkMonitor.onStatusChange = { reachable in
      Task {
        await uploadManager.setNetworkReachable(reachable)
      }
    }

    self.networkMonitor.start()

    Task {
      let stream = await uploadManager.makeProgressStream()
      for await progress in stream {
        self.progressPercent = Int((max(0, min(1, progress)) * 100).rounded())
      }
    }

    Task {
      let stream = await uploadManager.makeLogStream()
      for await line in stream {
        self.logs.append(line)
        if self.logs.count > 500 {
          self.logs.removeFirst(self.logs.count - 500)
        }
      }
    }

    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.stepsProvider.requestAuthorization()
      } catch {
        return
      }

      await MainActor.run {
        self.ensureObserverStartedIfNeeded()
      }

      let pending = await self.uploadManager.hasPendingWork()
      if !pending {
        return
      }

      if self.userPaused {
        await self.uploadManager.pause()
        await MainActor.run {
          self.controlState = .paused
          self.status = "Paused"
        }
        return
      }

      await MainActor.run {
        self.controlState = .syncing
        self.status = "Syncing…"
      }
      await self.uploadManager.resume()
      await self.uploadManager.startOrResume()

      let done = await self.uploadManager.isSyncComplete()
      await MainActor.run {
        if done {
          self.hasNewData = false
          self.progressPercent = 100
          self.status = "Success"
          self.controlState = .success
        } else if self.controlState != .paused {
          self.status = "Idle"
          self.controlState = .idle
        }
      }
    }
  }

  private func ensureObserverStartedIfNeeded() {
    if isObserverStarted {
      return
    }
    isObserverStarted = true
    stepsProvider.startObserver {
      Task {
        let shouldContinue = await MainActor.run { self.controlState == .syncing }

        await MainActor.run {
          self.hasNewData = true
          if self.controlState == .success {
            self.controlState = .idle
            self.status = "Idle"
          }
        }

        if shouldContinue {
          BackgroundScheduler.schedule()
          await self.uploadManager.notifyHealthDataChanged()
          await self.uploadManager.startOrResume()
        }
      }
    }
  }

  var primaryButtonTitle: String {
    switch controlState {
    case .idle, .success:
      return "Start Sync"
    case .syncing:
      return "Pause"
    case .paused:
      return "Resume"
    }
  }

  func primaryButtonTapped() {
    switch controlState {
    case .idle, .success:
      startSync()
    case .syncing:
      pauseSync()
    case .paused:
      resumeSync()
    }
  }

  /// Resets UI state and clears all local sync state.
  func resetButtonTapped() {
    guard controlState == .success else { return }

    syncTask?.cancel()
    syncTask = nil

    logs = []
    progressPercent = 0
    status = "Idle"
    controlState = .idle
    hasNewData = true
    userPaused = false
    defaults.set(false, forKey: pausedKey)

    Task {
      await uploadManager.resetSync()
    }
  }

  private func startSync() {
    syncTask?.cancel()
    controlState = .syncing
    status = "Requesting Health access…"
    userPaused = false
    defaults.set(false, forKey: pausedKey)
    BackgroundScheduler.schedule()

    syncTask = Task { [weak self] in
      guard let self else { return }
      do {
        await uploadManager.resetProgressForNewRun()
        await MainActor.run {
          self.progressPercent = 0
        }
        try await stepsProvider.requestAuthorization()

        await MainActor.run {
          self.ensureObserverStartedIfNeeded()
        }

        BackgroundScheduler.schedule()

        status = "Syncing…"
        await uploadManager.notifyHealthDataChanged()
        await uploadManager.resume()
        await uploadManager.startOrResume()

        let done = await uploadManager.isSyncComplete()
        if done {
          hasNewData = false
          progressPercent = 100
          status = "Success"
          controlState = .success
          BackgroundScheduler.cancel()
        } else if controlState != .paused {
          status = "Idle"
          controlState = .idle
        }
      } catch {
        status = "Failed: \(error.localizedDescription)"
        controlState = .idle
      }
    }
  }

  private func pauseSync() {
    controlState = .paused
    status = "Paused"
    userPaused = true
    defaults.set(true, forKey: pausedKey)
    BackgroundScheduler.cancel()
    syncTask?.cancel()
    Task {
      await uploadManager.pause()
    }
  }

  private func resumeSync() {
    controlState = .syncing
    status = "Syncing…"
    userPaused = false
    defaults.set(false, forKey: pausedKey)
    BackgroundScheduler.schedule()

    syncTask?.cancel()
    syncTask = Task { [weak self] in
      guard let self else { return }
      await uploadManager.resume()
      await uploadManager.startOrResume()

      let done = await uploadManager.isSyncComplete()
      if done {
        progressPercent = 100
        status = "Success"
        controlState = .success
        BackgroundScheduler.cancel()
      } else if controlState != .paused {
        status = "Idle"
        controlState = .idle
      }
    }
  }

  /// Entry point used by the app to start syncing.
  func start() {
    startSync()
  }
}
