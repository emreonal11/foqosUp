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

  /// Hardcoded blocklist for C4/D verification. C5 replaces this with values
  /// read from the App Group / iCloud-mirrored state.
  private static let blocklist: Set<String> = ["example.com"]

  private static let peekBytes = 4096  // ample for ClientHello (typical < 700 bytes)

  override func startFilter(completionHandler: @escaping (Error?) -> Void) {
    log.info("startFilter")
    #if DEBUG
      SNIParserSanityCheck.runOnce { [log] msg in log.info("\(msg, privacy: .public)") }
    #endif
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

    switch host {
    case .name(let name, _):
      // Should rarely fire on Tahoe — kernel resolves DNS before flows reach
      // the filter. Kept as a fast path in case any client surfaces a name.
      let lowered = name.lowercased()
      let drop = Self.matches(host: lowered)
      log.info("flow \(drop ? "DROP" : "allow", privacy: .public) \(lowered, privacy: .public) [direct hostname]")
      return drop ? .drop() : .allow()

    case .ipv4, .ipv6:
      // IP-only flow → peek outbound for ClientHello SNI.
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
      // Not parseable as a ClientHello with SNI. Most likely: not TLS, or
      // the ClientHello hadn't fully arrived. We'd ideally request more bytes
      // for the latter case, but distinguishing the two from the parser's nil
      // is non-trivial — most non-TLS flows we'd peek aren't HTTP either, so
      // allowing is the right trade-off for a personal-use blocker.
      log.info("SNI nil — allowing")
      return .allow()
    }
    let drop = Self.matches(host: sni)
    log.info("SNI \(drop ? "DROP" : "allow", privacy: .public) \(sni, privacy: .public)")
    return drop ? .drop() : .allow()
  }

  /// Suffix-match against blocklist: blocking `youtube.com` also blocks
  /// `m.youtube.com`, `studio.youtube.com`, etc.
  private static func matches(host: String) -> Bool {
    for entry in blocklist {
      if host == entry || host.hasSuffix(".\(entry)") { return true }
    }
    return false
  }
}
