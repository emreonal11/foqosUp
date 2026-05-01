import Foundation
import OSLog

/// JSON-encoded wire payload sent from container → filter over XPC. Identical
/// schema to FoqosMacFilter/BlocklistState.swift's struct of the same name —
/// the two sides must round-trip the same bytes through Codable.
struct BlocklistSnapshot: Codable, Equatable, Sendable {
  let isBlocked: Bool
  let isBreakActive: Bool
  let isPauseActive: Bool
  let domains: [String]
  let lastUpdated: Double
}

/// XPC client in the container app. Connects to the filter sysext's
/// NSXPCListener.
///
/// See FoqosMacFilter/IPCService.swift for the architectural rationale: NE
/// sysext runs as root and its App Group UserDefaults storage path is disjoint
/// from the container's user-side path, so XPC over a Mach service is the
/// canonical IPC channel (Apple DTS thread 133543).
///
/// Resilience: during dev iteration a rolling sysext replace creates a window
/// where the container's first publish lands on the dying old filter, fails,
/// and the new filter's listener isn't yet up. In production the same race
/// can happen on reboot or whenever the filter's process restarts. To absorb
/// it we keep the most recent requested snapshot in `lastRequested`, retry on
/// any failure with capped exponential backoff, and clear `lastDelivered` on
/// connection invalidation so the next attempt always re-sends current state.
@MainActor
final class IPCClient {
  static let shared = IPCClient()

  /// Must match IPCService.machServiceName on the filter side and the
  /// NEMachServiceName declared in FoqosMacFilter/Info.plist.
  static let machServiceName = "group.com.usetessera.mybrick.FoqosMacFilter"

  /// Retry delays in nanoseconds. After the last entry, we stop retrying and
  /// rely on the next iCloud refresh / forceSync / activator post-success
  /// callback to schedule a fresh attempt.
  private static let backoffNs: [UInt64] = [
    500_000_000,   // 0.5s
    1_500_000_000, // 1.5s
    3_500_000_000, // 3.5s
    7_500_000_000, // 7.5s
  ]

  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "IPCClient")
  private var connection: NSXPCConnection?
  private var lastRequested: BlocklistSnapshot?
  private var lastDelivered: BlocklistSnapshot?
  private var retryTask: Task<Void, Never>?

  private init() {}

  /// Send the current state to the filter. Idempotent: if the same snapshot
  /// is already delivered (or already in the retry queue with no material
  /// change), this is a no-op.
  func publish(
    isBlocked: Bool,
    isBreakActive: Bool,
    isPauseActive: Bool,
    domains: [String]
  ) {
    let snap = BlocklistSnapshot(
      isBlocked: isBlocked,
      isBreakActive: isBreakActive,
      isPauseActive: isPauseActive,
      domains: domains,
      lastUpdated: Date().timeIntervalSince1970
    )

    lastRequested = snap

    if let last = lastDelivered, snap.matches(last) {
      return
    }

    // New (or undelivered) state — cancel any pending retry and try now.
    retryTask?.cancel()
    retryTask = nil
    attemptPublish(attempt: 0)
  }

  /// Forces the next `publish(...)` to round-trip XPC even if state is
  /// unchanged. Called by ExtensionActivator on activation success so we
  /// republish after the filter listener comes up.
  func resetDedup() {
    lastDelivered = nil
  }

  // MARK: - Internals

  private func attemptPublish(attempt: Int) {
    guard let snap = lastRequested else { return }

    let conn = ensureConnection()
    let data: Data
    do {
      data = try JSONEncoder().encode(snap)
    } catch {
      log.error("Encode snapshot failed: \(error.localizedDescription, privacy: .public)")
      return
    }

    let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        self.log.error(
          "XPC publish error (attempt \(attempt + 1, privacy: .public)): \(error.localizedDescription, privacy: .public)"
        )
        self.scheduleRetry(after: attempt)
      }
    }
    guard let service = proxy as? BlocklistService else {
      log.error("Remote proxy did not vend BlocklistService — interface mismatch?")
      scheduleRetry(after: attempt)
      return
    }

    service.updateBlocklist(data) { [weak self] success in
      Task { @MainActor in
        guard let self else { return }
        if success {
          self.lastDelivered = snap
          self.retryTask?.cancel()
          self.retryTask = nil
          self.log.info(
            "Published (attempt \(attempt + 1, privacy: .public)): blocked=\(snap.isBlocked, privacy: .public) break=\(snap.isBreakActive, privacy: .public) pause=\(snap.isPauseActive, privacy: .public) domains=\(snap.domains.count, privacy: .public)"
          )
        } else {
          self.log.error("Filter rejected snapshot (decode failure on filter side)")
          // Filter explicitly NACK'd — same bytes won't succeed on retry.
          // Don't re-queue; wait for next refresh with different content.
        }
      }
    }
  }

  private func scheduleRetry(after attempt: Int) {
    guard attempt < Self.backoffNs.count else {
      log.error("XPC publish gave up after \(attempt + 1, privacy: .public) attempts")
      return
    }
    let delay = Self.backoffNs[attempt]
    log.info(
      "XPC retry queued in \(Double(delay) / 1e9, privacy: .public)s (attempt \(attempt + 2, privacy: .public))"
    )
    retryTask?.cancel()
    retryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      guard let self, !Task.isCancelled else { return }
      self.attemptPublish(attempt: attempt + 1)
    }
  }

  private func ensureConnection() -> NSXPCConnection {
    if let conn = connection { return conn }
    let conn = NSXPCConnection(machServiceName: Self.machServiceName, options: [])
    conn.remoteObjectInterface = NSXPCInterface(with: BlocklistService.self)
    conn.invalidationHandler = { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.log.info("XPC connection invalidated; will recreate on next attempt")
        self.connection = nil
        // Force a re-publish next time: the new filter (post-replace) needs
        // current state even if it semantically equals what we delivered to
        // the previous filter PID.
        self.lastDelivered = nil
        if self.lastRequested != nil {
          self.scheduleRetry(after: 0)
        }
      }
    }
    conn.interruptionHandler = { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.log.info("XPC connection interrupted; clearing for fresh handshake")
        self.connection = nil
        self.lastDelivered = nil
        if self.lastRequested != nil {
          self.scheduleRetry(after: 0)
        }
      }
    }
    conn.resume()
    connection = conn
    log.info("XPC connection established to \(Self.machServiceName, privacy: .public)")
    return conn
  }
}

extension BlocklistSnapshot {
  /// Material-equality check used for dedup. Excludes `lastUpdated` because
  /// it changes on every publish() call regardless of state, which would
  /// defeat dedup if compared.
  fileprivate func matches(_ other: BlocklistSnapshot) -> Bool {
    return isBlocked == other.isBlocked
      && isBreakActive == other.isBreakActive
      && isPauseActive == other.isPauseActive
      && domains == other.domains
  }
}
