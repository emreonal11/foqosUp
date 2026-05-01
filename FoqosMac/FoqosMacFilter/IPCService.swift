import Foundation
import OSLog

/// XPC server inside the FoqosMacFilter system extension.
///
/// Why XPC instead of App Group UserDefaults: the filter sysext runs as root
/// (UID 0) under its own per-root sandbox container; the container app runs
/// as the logged-in user. Their App Group `UserDefaults(suiteName:)` paths
/// resolve to physically separate plists under `/var/root/...` vs
/// `/Users/<user>/...`, so writes from the container are invisible to the
/// filter. Apple DTS recommends NSXPCConnection for this exact pattern
/// (developer.apple.com/forums/thread/133543, /706503, /763433); the
/// SimpleFirewall sample uses it as well.
///
/// Mach service name reuses the filter target's NEMachServiceName from
/// Info.plist. NetworkExtension's internal sysextd↔filter channel is
/// kernel-private and disjoint from this user-facing XPC listener, so the
/// same name does not collide. Single name → single NSXPCListener.
final class IPCService: NSObject, NSXPCListenerDelegate, BlocklistService, @unchecked Sendable {
  static let shared = IPCService()

  /// Reused from FoqosMacFilter/Info.plist:NetworkExtension.NEMachServiceName.
  /// Must also equal IPCClient.machServiceName on the container side.
  static let machServiceName = "group.com.usetessera.mybrick.FoqosMacFilter"

  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "IPCService")
  private var listener: NSXPCListener?

  /// Idempotent: NEFilterDataProvider.startFilter can be invoked multiple
  /// times across an extension's lifetime (settings reload, replace flow);
  /// we only want one listener bound to the Mach name.
  func startListener() {
    guard listener == nil else {
      log.info("XPC listener already running; skipping re-bind")
      return
    }
    let l = NSXPCListener(machServiceName: Self.machServiceName)
    l.delegate = self
    l.resume()
    listener = l
    log.info("XPC listener started on \(Self.machServiceName, privacy: .public)")
  }

  // MARK: NSXPCListenerDelegate

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection conn: NSXPCConnection
  ) -> Bool {
    log.info("XPC client connected pid=\(conn.processIdentifier, privacy: .public)")
    conn.exportedInterface = NSXPCInterface(with: BlocklistService.self)
    conn.exportedObject = self
    conn.invalidationHandler = { [log] in
      log.info("XPC client invalidated")
    }
    conn.interruptionHandler = { [log] in
      log.info("XPC client interrupted")
    }
    conn.resume()
    return true
  }

  // MARK: BlocklistService

  func updateBlocklist(_ data: Data, withReply reply: @escaping (Bool) -> Void) {
    do {
      let snap = try JSONDecoder().decode(BlocklistSnapshot.self, from: data)
      BlocklistState.shared.update(snap)
      log.info(
        "Snapshot received: blocked=\(snap.isBlocked, privacy: .public) break=\(snap.isBreakActive, privacy: .public) pause=\(snap.isPauseActive, privacy: .public) domains=\(snap.domains.count, privacy: .public)"
      )
      reply(true)
    } catch {
      log.error("Decode snapshot failed: \(error.localizedDescription, privacy: .public)")
      reply(false)
    }
  }
}
