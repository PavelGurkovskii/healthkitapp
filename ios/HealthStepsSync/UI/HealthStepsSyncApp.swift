import SwiftUI

@main
struct HealthStepsSyncApp: App {
  @StateObject private var environment = AppEnvironment()

  init() {}

  var body: some Scene {
    WindowGroup {
      ContentView(vm: environment.makeViewModel())
    }
  }
}
