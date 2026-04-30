import Foundation
import NetworkExtension
import OSLog
import SystemExtensions

enum FilterStatus: Equatable {
  case unknown
  case installing
  case needsApproval
  case activeAndConfigured
  case willActivateAfterReboot
  case error(String)

  var summary: String {
    switch self {
    case .unknown: return "Filter: checking…"
    case .installing: return "Filter: setting up…"
    case .needsApproval: return "Filter: approve in System Settings"
    case .activeAndConfigured: return "Filter: active"
    case .willActivateAfterReboot: return "Filter: reboot to activate"
    case .error(let m): return "Filter error: \(m)"
    }
  }
}

final class ExtensionActivator: NSObject, @unchecked Sendable {
  static let extensionBundleId = "com.usetessera.mybrick.FoqosMac.FoqosMacFilter"

  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "ExtensionActivator")
  private weak var state: BridgeState?

  init(state: BridgeState) {
    self.state = state
    super.init()
  }

  func activateIfNeeded() {
    log.info("Checking filter state")
    NEFilterManager.shared().loadFromPreferences { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        if let error {
          self.update(.error("load: \(error.localizedDescription)"))
          return
        }
        if NEFilterManager.shared().isEnabled {
          self.log.info("Filter already enabled, skipping activation")
          self.update(.activeAndConfigured)
        } else {
          self.requestActivation()
        }
      }
    }
  }

  @MainActor
  private func requestActivation() {
    log.info("Submitting activation request for \(Self.extensionBundleId, privacy: .public)")
    update(.installing)
    let request = OSSystemExtensionRequest.activationRequest(
      forExtensionWithIdentifier: Self.extensionBundleId,
      queue: .main
    )
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  @MainActor
  private func configureFilterManager() {
    log.info("Configuring NEFilterManager")
    NEFilterManager.shared().loadFromPreferences { [weak self] loadError in
      Task { @MainActor in
        guard let self else { return }
        if let err = loadError {
          self.update(.error("config load: \(err.localizedDescription)"))
          return
        }
        let cfg = NEFilterProviderConfiguration()
        cfg.filterPackets = false
        cfg.filterSockets = true
        NEFilterManager.shared().providerConfiguration = cfg
        NEFilterManager.shared().localizedDescription = "FoqosMac"
        NEFilterManager.shared().isEnabled = true
        NEFilterManager.shared().saveToPreferences { [weak self] saveError in
          Task { @MainActor in
            guard let self else { return }
            if let err = saveError {
              self.update(.error("config save: \(err.localizedDescription)"))
            } else {
              self.log.info("Filter active and enabled")
              self.update(.activeAndConfigured)
            }
          }
        }
      }
    }
  }

  @MainActor
  private func update(_ status: FilterStatus) {
    state?.filterStatus = status
  }
}

extension ExtensionActivator: OSSystemExtensionRequestDelegate {
  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    log.info("Replacing existing extension")
    return .replace
  }

  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    log.info("System Settings approval needed")
    Task { @MainActor in self.update(.needsApproval) }
  }

  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    didFinishWithResult result: OSSystemExtensionRequest.Result
  ) {
    log.info("Finished with result: \(String(describing: result), privacy: .public)")
    Task { @MainActor in
      switch result {
      case .completed:
        self.configureFilterManager()
      case .willCompleteAfterReboot:
        self.update(.willActivateAfterReboot)
      @unknown default:
        self.update(.error("unknown activation result"))
      }
    }
  }

  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    didFailWithError error: Error
  ) {
    log.error("Activation failed: \(error.localizedDescription, privacy: .public)")
    Task { @MainActor in self.update(.error(error.localizedDescription)) }
  }
}
