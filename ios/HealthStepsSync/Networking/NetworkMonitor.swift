import Foundation
import Network

/// Protocol defining network reachability monitoring.
protocol NetworkMonitoring: AnyObject {
  /// Called whenever reachability changes.
  var onStatusChange: ((Bool) -> Void)? { get set }

  /// Starts monitoring network reachability.
  func start()

  /// Stops monitoring.
  func stop()
}

final class NetworkMonitor: NetworkMonitoring {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "NetworkMonitor")

  var onStatusChange: ((Bool) -> Void)?

  func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.onStatusChange?(path.status == .satisfied)
    }
    monitor.start(queue: queue)
  }

  func stop() {
    monitor.cancel()
  }
}
