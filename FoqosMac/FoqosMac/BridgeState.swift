import Combine
import Foundation

@MainActor
final class BridgeState: ObservableObject {
  @Published var isBlocked: Bool = false
  @Published var isBreakActive: Bool = false
  @Published var isPauseActive: Bool = false
  @Published var activeProfileId: String?
  @Published var domains: [String] = []
  @Published var lastUpdated: Date?

  private let observer = ICloudObserver()

  init() {
    observer.onChange = { [weak self] in
      Task { @MainActor in self?.refresh() }
    }
    refresh()
    observer.start()
  }

  var menuBarSymbol: String {
    if isBlocked && !isBreakActive && !isPauseActive { return "lock.fill" }
    return "lock.open"
  }

  var summary: String {
    if !isBlocked { return "Not blocked" }
    if isBreakActive { return "On break" }
    if isPauseActive { return "Paused" }
    return "Blocked"
  }

  func refresh() {
    let store = NSUbiquitousKeyValueStore.default
    isBlocked = store.bool(forKey: BridgeKey.isBlocked)
    isBreakActive = store.bool(forKey: BridgeKey.isBreakActive)
    isPauseActive = store.bool(forKey: BridgeKey.isPauseActive)
    activeProfileId = store.string(forKey: BridgeKey.activeProfileId)
    if let data = store.data(forKey: BridgeKey.activeBlocklistDomains),
      let arr = try? JSONDecoder().decode([String].self, from: data)
    {
      domains = arr
    } else {
      domains = []
    }
    let ts = store.double(forKey: BridgeKey.lastUpdated)
    lastUpdated = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
  }

  func forceSync() {
    NSUbiquitousKeyValueStore.default.synchronize()
    refresh()
  }
}
