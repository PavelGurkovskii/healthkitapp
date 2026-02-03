import Foundation
import Network

final class NetworkMonitor {
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
