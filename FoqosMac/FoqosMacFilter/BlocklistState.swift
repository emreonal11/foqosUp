import Foundation
import OSLog

/// JSON-encoded wire payload received over XPC from the container. Identical
/// schema to FoqosMac/IPCClient.swift's struct of the same name; both sides
/// must round-trip the same bytes through Codable.
struct BlocklistSnapshot: Codable, Equatable, Sendable {
  let isBlocked: Bool
  let isBreakActive: Bool
  let isPauseActive: Bool
  let domains: [String]
  let lastUpdated: Double

  static let empty = BlocklistSnapshot(
    isBlocked: false,
    isBreakActive: false,
    isPauseActive: false,
    domains: [],
    lastUpdated: 0
  )
}

/// In-memory blocklist consulted by the FilterDataProvider hot path. Pure
/// cache — no I/O. State is pushed in via `update(_:)` from IPCService when
/// the container app sends a fresh snapshot over XPC. Reads are lock-protected
/// because Apple does not document whether per-flow callbacks (`handleNewFlow`
/// / `handleOutboundData`) and XPC delivery threads share a serialization
/// queue, and the lock is cheap (~10 ns uncontended).
final class BlocklistState: @unchecked Sendable {
  static let shared = BlocklistState()

  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "BlocklistState")
  private let lock = NSLock()
  private var snapshot: BlocklistSnapshot = .empty

  private init() {
    log.info("BlocklistState initialized (default snapshot = empty)")
  }

  /// True iff blocking is active and `host` matches one of the blocklist
  /// entries. Suffix match means "youtube.com" also blocks "m.youtube.com",
  /// "studio.youtube.com", etc.
  func shouldBlock(host: String) -> Bool {
    lock.lock()
    let snap = snapshot
    lock.unlock()
    guard snap.isBlocked, !snap.isBreakActive, !snap.isPauseActive else { return false }
    let h = host.lowercased()
    for entry in snap.domains where !entry.isEmpty {
      let e = entry.lowercased()
      if h == e || h.hasSuffix(".\(e)") { return true }
    }
    return false
  }

  /// Atomically swap the in-memory snapshot. Called by IPCService when a new
  /// snapshot arrives over XPC.
  func update(_ new: BlocklistSnapshot) {
    lock.lock()
    snapshot = new
    lock.unlock()
    log.info(
      "Updated: blocked=\(new.isBlocked, privacy: .public) break=\(new.isBreakActive, privacy: .public) pause=\(new.isPauseActive, privacy: .public) domains=\(new.domains.count, privacy: .public)"
    )
  }
}
