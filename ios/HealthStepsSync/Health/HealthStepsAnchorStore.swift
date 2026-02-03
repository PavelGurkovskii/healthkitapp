import Foundation
import HealthKit

final class HealthStepsAnchorStore {
  private let defaults: UserDefaults
  private let key = "HealthStepsSync.anchor.stepCount"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadAnchor() -> HKQueryAnchor? {
    guard let data = defaults.data(forKey: key) else { return nil }

    do {
      return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    } catch {
      return nil
    }
  }

  func saveAnchor(_ anchor: HKQueryAnchor) {
    do {
      let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
      defaults.set(data, forKey: key)
    } catch {
      return
    }
  }

  func reset() {
    defaults.removeObject(forKey: key)
  }
}
