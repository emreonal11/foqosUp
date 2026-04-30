import Combine
import OSLog
import SwiftUI

@main
struct FoqosMacApp: App {
  @StateObject private var bridge = BridgeState()

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

enum BridgeKey {
  static let isBlocked = "mybrick.isBlocked"
  static let isBreakActive = "mybrick.isBreakActive"
  static let isPauseActive = "mybrick.isPauseActive"
  static let activeBlocklistDomains = "mybrick.activeBlocklistDomains"
  static let activeProfileId = "mybrick.activeProfileId"
  static let lastUpdated = "mybrick.lastUpdated"
}

final class ICloudObserver {
  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "ICloudObserver")
  var onChange: (() -> Void)?

  func start() {
    let store = NSUbiquitousKeyValueStore.default
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(externalChange(_:)),
      name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: store
    )
    store.synchronize()
    log.info("Observer started")
  }

  @objc private func externalChange(_ note: Notification) {
    let info = note.userInfo
    let reason = info?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int ?? -1
    let keys = info?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
    log.info(
      "External change reason=\(reason, privacy: .public) keys=\(keys, privacy: .public)"
    )
    onChange?()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
