import Foundation
import HealthKit

/// Protocol defining the interface for a steps provider.
protocol StepsProviding: AnyObject {
  /// Requests HealthKit read access for step count.
  func requestAuthorization() async throws
  
  /// Fetches the next batch of step samples using a persisted HK query anchor.
  func fetchNextBatch(limit: Int) async throws -> [StepSampleDTO]
  
  /// Resets all stored anchors so the next sync starts from the beginning.
  func resetAllAnchors()
  
  /// Starts a HealthKit observer query that notifies when new step samples appear.
  func startObserver(onUpdate: @escaping () -> Void)
}

/// Provides step count data from HealthKit.
final class HealthStepsProvider: StepsProviding {
  enum ProviderError: Error {
    case healthDataNotAvailable
    case authorizationFailed
    case invalidSample
  }

  private let healthStore: HKHealthStore
  private let anchorStore: HealthStepsAnchorStore

  init(
    healthStore: HKHealthStore = HKHealthStore(),
    anchorStore: HealthStepsAnchorStore = .init()
  ) {
    self.healthStore = healthStore
    self.anchorStore = anchorStore
  }

  /// Requests HealthKit read access for step count.
  func requestAuthorization() async throws {
    guard HKHealthStore.isHealthDataAvailable() else {
      throw ProviderError.healthDataNotAvailable
    }

    guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else {
      throw ProviderError.healthDataNotAvailable
    }

    try await withCheckedThrowingContinuation { cont in
      healthStore.requestAuthorization(toShare: [], read: [type]) { success, error in
        if success {
          cont.resume()
        } else {
          cont.resume(throwing: error ?? ProviderError.authorizationFailed)
        }
      }
    }
  }

  /// Fetches the next batch of step samples using a persisted HK query anchor.
  func fetchNextBatch(limit: Int) async throws -> [StepSampleDTO] {
    guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else {
      throw ProviderError.healthDataNotAvailable
    }

    let anchor = anchorStore.loadAnchor()

    return try await withCheckedThrowingContinuation { cont in
      let query = HKAnchoredObjectQuery(
        type: type,
        predicate: nil,
        anchor: anchor,
        limit: limit
      ) { [weak self] _, samplesOrNil, _, newAnchor, error in
        if let error {
          cont.resume(throwing: error)
          return
        }

        let samples = (samplesOrNil as? [HKQuantitySample]) ?? []

        if let newAnchor {
          self?.anchorStore.saveAnchor(newAnchor)
        }

        do {
          let mapped = try samples.map { try Self.map(sample: $0) }
          cont.resume(returning: mapped)
        } catch {
          cont.resume(throwing: error)
        }
      }

      self.healthStore.execute(query)
    }
  }

  /// Resets all stored anchors so the next sync starts from the beginning.
  func resetAllAnchors() {
    anchorStore.reset()
  }

  /// Starts a HealthKit observer query that notifies when new step samples appear.
  func startObserver(onUpdate: @escaping () -> Void) {
    guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else {
      return
    }

    let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, _ in
      onUpdate()
      completion()
    }

    healthStore.execute(query)
    healthStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
  }

  private static func map(sample: HKQuantitySample) throws -> StepSampleDTO {
    let unit = HKUnit.count()
    let count = sample.quantity.doubleValue(for: unit)

    return StepSampleDTO(
      uuid: sample.uuid.uuidString,
      startDate: ISO8601.string(from: sample.startDate),
      endDate: ISO8601.string(from: sample.endDate),
      count: count,
      sourceBundleId: sample.sourceRevision.source.bundleIdentifier
    )
  }
}
