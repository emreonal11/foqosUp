import SwiftUI

@main
struct FoqosMacApp: App {
  @StateObject private var bridge = BridgeState()

  init() {
    LoginItem.ensureRegistered()
  }

  var body: some Scene {
    MenuBarExtra {
      ContentView()
        .environmentObject(bridge)
    } label: {
      Image(systemName: bridge.menuBarSymbol)
    }
    .menuBarExtraStyle(.window)
  }
}
