import Network
import NetworkExtension
import OSLog

class FilterDataProvider: NEFilterDataProvider {
  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "FilterDataProvider")

  override func startFilter(completionHandler: @escaping (Error?) -> Void) {
    log.info("startFilter")
    let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
    apply(settings) { [log] error in
      if let error {
        log.error("apply failed: \(error.localizedDescription, privacy: .public)")
      } else {
        log.info("Filter settings applied (defaultAction = filterData)")
      }
      completionHandler(error)
    }
  }

  override func stopFilter(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    log.info("stopFilter reason=\(String(describing: reason), privacy: .public)")
    completionHandler()
  }

  override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
    guard let socketFlow = flow as? NEFilterSocketFlow,
      let endpoint = socketFlow.remoteFlowEndpoint,
      case .hostPort(let host, _) = endpoint
    else {
      return .allow()
    }

    let hostname: String
    switch host {
    case .name(let name, _):
      hostname = name.lowercased()
    case .ipv4(let addr):
      hostname = "\(addr)"
    case .ipv6(let addr):
      hostname = "\(addr)"
    @unknown default:
      return .allow()
    }

    if hostname == "example.com" || hostname.hasSuffix(".example.com") {
      log.info("DROP \(hostname, privacy: .public)")
      return .drop()
    }
    return .allow()
  }
}
