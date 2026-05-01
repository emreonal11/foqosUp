import Network
import NetworkExtension
import OSLog

/// macOS Tahoe surfaces `remoteFlowEndpoint` as resolved IP for nearly every
/// client (Safari, Chrome, curl). Hostname-based blocking only works via SNI
/// inspection from `handleOutboundData`. So `handleNewFlow` always asks for
/// peek-outbound when the endpoint is an IP, and the actual block decision
/// happens in `handleOutboundData` after parsing the TLS ClientHello.
final class FilterDataProvider: NEFilterDataProvider {
  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "FilterDataProvider")
  private static let peekBytes = 4096  // ample for ClientHello (typical < 700 bytes)

  override func startFilter(completionHandler: @escaping (Error?) -> Void) {
    log.info("startFilter")
    #if DEBUG
      SNIParserSanityCheck.runOnce { [log] msg in log.info("\(msg, privacy: .public)") }
    #endif

    // Initial state load + observer for live updates from the container.
    BlocklistState.shared.reloadFromAppGroup()
    setupDarwinObserver()

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
    removeDarwinObserver()
    completionHandler()
  }

  override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
    guard let socketFlow = flow as? NEFilterSocketFlow,
      let endpoint = socketFlow.remoteFlowEndpoint
    else {
      return .allow()
    }

    // QUIC blackhole: drop all UDP/443. HTTP/3 carries its TLS handshake in
    // encrypted CRYPTO frames, so SNI inspection from outbound data doesn't
    // work the way it does for TCP+TLS. Rather than parse QUIC (complex, key
    // derivation involved), we drop UDP/443 wholesale and let browsers fall
    // back to TCP+TLS — which they do automatically and quickly. Net effect:
    // every HTTPS connection we care about goes through SNI inspection.
    let isUDP = socketFlow.socketProtocol == Int32(IPPROTO_UDP)
    if isUDP, case .hostPort(_, let port) = endpoint, port.rawValue == 443 {
      log.info("flow DROP udp/443 (QUIC blackhole → TCP fallback)")
      return .drop()
    }

    guard case .hostPort(let host, _) = endpoint else { return .allow() }

    switch host {
    case .name(let name, _):
      // Should rarely fire on Tahoe — kernel resolves DNS before flows reach
      // the filter. Kept as a fast path in case any client surfaces a name.
      let lowered = name.lowercased()
      let drop = BlocklistState.shared.shouldBlock(host: lowered)
      log.info(
        "flow \(drop ? "DROP" : "allow", privacy: .public) \(lowered, privacy: .public) [direct hostname]"
      )
      return drop ? .drop() : .allow()

    case .ipv4, .ipv6:
      // IP-only TCP flow → peek outbound for ClientHello SNI.
      return .filterDataVerdict(
        withFilterInbound: false,
        peekInboundBytes: 0,
        filterOutbound: true,
        peekOutboundBytes: Self.peekBytes
      )

    @unknown default:
      return .allow()
    }
  }

  override func handleOutboundData(
    from flow: NEFilterFlow,
    readBytesStartOffset offset: Int,
    readBytes: Data
  ) -> NEFilterDataVerdict {
    guard let sni = SNIParser.extractSNI(from: readBytes) else {
      // Not parseable as a ClientHello with SNI. Could be: non-TLS protocol,
      // truncated ClientHello (unlikely, peek is 4KB), TLS resumption with
      // session ticket but no SNI, or ECH-encrypted (~zero deployment 2026).
      // Log enough context to spot patterns later.
      let proto = (flow as? NEFilterSocketFlow)?.socketProtocol ?? -1
      let port: UInt16 = {
        guard let s = flow as? NEFilterSocketFlow,
          let ep = s.remoteFlowEndpoint,
          case .hostPort(_, let p) = ep
        else { return 0 }
        return p.rawValue
      }()
      log.info(
        "SNI nil [proto=\(proto, privacy: .public) port=\(port, privacy: .public) bytes=\(readBytes.count, privacy: .public)] — allowing"
      )
      return .allow()
    }
    let drop = BlocklistState.shared.shouldBlock(host: sni)
    log.info("SNI \(drop ? "DROP" : "allow", privacy: .public) \(sni, privacy: .public)")
    return drop ? .drop() : .allow()
  }

  // MARK: - Darwin notification (container → filter signal to reload state)

  private func setupDarwinObserver() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      center,
      observer,
      { (_, observerPtr, _, _, _) in
        guard let observerPtr else { return }
        let me = Unmanaged<FilterDataProvider>.fromOpaque(observerPtr).takeUnretainedValue()
        me.log.info("Darwin: state.changed — reloading from App Group")
        BlocklistState.shared.reloadFromAppGroup()
      },
      AppGroupConstants.stateChangedDarwinName as CFString,
      nil,
      .deliverImmediately
    )
  }

  private func removeDarwinObserver() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterRemoveEveryObserver(center, observer)
  }
}
