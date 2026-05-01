import Network
import NetworkExtension
import OSLog

/// macOS Tahoe surfaces `remoteFlowEndpoint` as a resolved IP for nearly every
/// client (Safari, Chrome, curl). Hostname-based blocking only works via SNI
/// inspection from `handleOutboundData`, so `handleNewFlow` always asks for
/// peek-outbound when the endpoint is an IP, and the actual block decision
/// happens in `handleOutboundData` after parsing the TLS ClientHello.
///
/// State arrives via XPC from the container app — see IPCService.swift for
/// the rationale (NE sysext UID-split makes App Group UserDefaults unusable).
final class FilterDataProvider: NEFilterDataProvider {
  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "FilterDataProvider")
  private static let peekBytes = 4096  // ample for ClientHello (typical < 700 bytes)
  /// `Int.max` for ongoing inspection — Apple's forum guidance for the
  /// "watch every flow" pattern. The system delivers in natural-sized
  /// chunks (typically 1 TCP segment, ~1-1.5 KB) rather than buffering up
  /// to a fixed threshold. This is critical for HTTP/2: a 64 KB peek
  /// threshold means a browsing session can fire dozens of small request
  /// headers before our callback wakes up — too slow for state-change
  /// reaction. With Int.max we're notified on each segment, so a state
  /// change (break-end, rebrick) propagates within one user interaction.
  private static let watchChunk = Int.max

  /// Every TLS flow we've extracted an SNI for. We keep them under
  /// continuing outbound-data inspection (rather than returning `.allow()`
  /// and detaching) so we can drop them the moment state transitions in a
  /// way that should now block them. Apple's NEFilterDataProvider has no
  /// retroactive kill API for already-allowed flows, so ongoing inspection
  /// is the only way to handle break-end / pause-end / blocklist-mutation
  /// without leaving stale connections alive in the browser. Idle flows
  /// cost nothing — `handleOutboundData` only fires when bytes actually
  /// move. Keyed by NEFilterFlow.identifier.
  ///
  /// Lifetime: an entry is added when a flow's SNI is first inspected and
  /// removed when the flow is retroactively dropped. The kernel does not
  /// notify us when an allowed flow ends naturally (browser closes the
  /// connection), so entries for naturally-closed flows linger until process
  /// exit. In practice the dict tracks "TLS flows seen since filter started",
  /// which is on the order of thousands per day of heavy use and bounded
  /// by available file descriptors anyway. The growth-milestone log below
  /// surfaces it if anything ever goes pathological.
  private let watchedLock = NSLock()
  private var watchedSNI: [UUID: String] = [:]
  private var nextGrowthMilestone = 1_000

  override func startFilter(completionHandler: @escaping (Error?) -> Void) {
    log.info("startFilter")
    #if DEBUG
      SNIParserSanityCheck.runOnce { [log] msg in log.info("\(msg, privacy: .public)") }
    #endif

    // State pushes in over XPC; until the container connects and publishes,
    // BlocklistState stays at .empty and we fail open.
    IPCService.shared.startListener()

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
    let flowID = flow.identifier

    // Subsequent chunk on an already-watched flow. Re-check whether the
    // current BlocklistState says this SNI should now be blocked. This is
    // where break-end / pause-end / blocklist-mutation cases get caught —
    // the state may have changed since the previous chunk.
    if let sni = cachedSNI(for: flowID) {
      if BlocklistState.shared.shouldBlock(host: sni) {
        forgetFlow(flowID)
        log.info(
          "SNI DROP \(sni, privacy: .public) [retroactive — state changed, bytes=\(readBytes.count, privacy: .public)]"
        )
        return .drop()
      }
      // Still allowed. Pass these bytes through and peek the next chunk.
      return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: Self.watchChunk)
    }

    // First-time inspection. Try to extract SNI from the ClientHello.
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

    if BlocklistState.shared.shouldBlock(host: sni) {
      log.info("SNI DROP \(sni, privacy: .public)")
      return .drop()
    }

    // Allowed right now. Keep the flow under continuing data inspection so
    // we can react to *any* future state change — break end, blocklist
    // mutation (user adds the SNI's domain to the active profile after
    // unbrick + rebrick), pause toggle, etc. Apple's NEFilterDataProvider
    // has no retroactive kill API for `.allow()`d flows; ongoing inspection
    // is the only mechanism that actually works. The cost is bounded by
    // active flow throughput — `peekBytes = Int.max` lets the system
    // deliver in natural-sized chunks (typically per TCP segment, ~1-1.5
    // KB), so idle flows fire zero callbacks. See `watchChunk` for full
    // rationale.
    rememberFlow(flowID, sni: sni)
    log.info("SNI watch \(sni, privacy: .public)")
    return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: Self.watchChunk)
  }

  // MARK: - Watched-flow tracking

  private func cachedSNI(for id: UUID) -> String? {
    watchedLock.lock()
    let v = watchedSNI[id]
    watchedLock.unlock()
    return v
  }

  private func rememberFlow(_ id: UUID, sni: String) {
    watchedLock.lock()
    watchedSNI[id] = sni
    let count = watchedSNI.count
    var milestone = -1
    if count >= nextGrowthMilestone {
      milestone = nextGrowthMilestone
      // Log at 1K, 5K, 10K, 50K, 100K — diagnostic only.
      switch nextGrowthMilestone {
      case 1_000: nextGrowthMilestone = 5_000
      case 5_000: nextGrowthMilestone = 10_000
      case 10_000: nextGrowthMilestone = 50_000
      case 50_000: nextGrowthMilestone = 100_000
      default: nextGrowthMilestone = .max
      }
    }
    watchedLock.unlock()

    if milestone > 0 {
      log.info(
        "watchedSNI crossed \(milestone, privacy: .public) entries (now \(count, privacy: .public)) — diagnostic only"
      )
    }
  }

  private func forgetFlow(_ id: UUID) {
    watchedLock.lock()
    watchedSNI.removeValue(forKey: id)
    watchedLock.unlock()
  }
}
