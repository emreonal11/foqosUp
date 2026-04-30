import Foundation
import OSLog

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
