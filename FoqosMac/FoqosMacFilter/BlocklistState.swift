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

  /// User-friendly aliases for popular distractor services.
  ///
  /// When the user adds a high-level domain (e.g. `youtube.com`) to their
  /// iOS Foqos profile, the Mac filter expands it to the full set of
  /// domains the service actually depends on — including its video CDN,
  /// thumbnail CDN, short-link domain, etc. The user's iOS profile stays
  /// the SSOT for *which services* to block, and stays under Foqos's
  /// 50-entry profile limit; the Mac filter handles the per-service
  /// domain coverage. Aliases are additive: the base entry is always
  /// blocked too.
  ///
  /// Conservative criteria for inclusion: a domain joins an alias only if
  /// it's exclusively (or near-exclusively) used by the named service.
  /// Deliberately excluded:
  ///   - `ggpht.com` (used by Gmail avatars + Google Photos profile pics
  ///     — over-blocks).
  ///   - `googleapis.com` (every Google service — over-blocks).
  ///   - `fbcdn.net` (shared across Instagram + Facebook + Messenger +
  ///     WhatsApp — user can add explicitly to their iOS profile if
  ///     they want broader Meta coverage).
  ///
  /// To extend: add the new mapping here and ship. No rebuild of the iOS
  /// profile is needed; the Mac filter alone owns this expansion.
  private static let domainAliases: [String: [String]] = [
    "youtube.com": [
      "googlevideo.com",  // video data CDN
      "ytimg.com",  // image / thumbnail CDN
      "youtu.be",  // short-link domain
      "youtube-nocookie.com",  // embedded-player domain
    ],
    "instagram.com": [
      "cdninstagram.com",  // Instagram-specific image / video CDN
    ],
  ]

  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "BlocklistState")
  private let lock = NSLock()
  private var snapshot: BlocklistSnapshot = .empty

  /// Pre-expanded effective blocklist (user's profile entries + alias
  /// substitutions). Recomputed once per `update(_:)`; reads on the hot
  /// path are O(domains) suffix-match scans against this set.
  private var effectiveDomains: Set<String> = []

  private init() {
    log.info("BlocklistState initialized (default snapshot = empty)")
  }

  /// True iff blocking is active and `host` matches one of the blocklist
  /// entries (after alias expansion). Suffix match means "youtube.com" also
  /// blocks "m.youtube.com", "studio.youtube.com", etc.
  func shouldBlock(host: String) -> Bool {
    lock.lock()
    let snap = snapshot
    let domains = effectiveDomains
    lock.unlock()
    guard snap.isBlocked, !snap.isBreakActive, !snap.isPauseActive else { return false }
    return matches(host, against: domains)
  }

  /// Atomically swap the in-memory snapshot. Called by IPCService when a new
  /// snapshot arrives over XPC.
  func update(_ new: BlocklistSnapshot) {
    let expanded = Self.expand(new.domains)
    lock.lock()
    snapshot = new
    effectiveDomains = expanded
    lock.unlock()
    log.info(
      "Updated: blocked=\(new.isBlocked, privacy: .public) break=\(new.isBreakActive, privacy: .public) pause=\(new.isPauseActive, privacy: .public) profileDomains=\(new.domains.count, privacy: .public) effectiveDomains=\(expanded.count, privacy: .public)"
    )
  }

  /// Expand the user's profile domain list with our static alias map.
  /// Lowercases for case-insensitive matching. Returns a Set so that
  /// duplicate entries (user explicitly adds an alias domain that's also
  /// covered by another entry's alias list) collapse cleanly.
  private static func expand(_ domains: [String]) -> Set<String> {
    var out = Set<String>()
    for entry in domains where !entry.isEmpty {
      let lowered = entry.lowercased()
      out.insert(lowered)
      if let aliases = domainAliases[lowered] {
        for alias in aliases { out.insert(alias) }
      }
    }
    return out
  }

  private func matches(_ host: String, against domains: Set<String>) -> Bool {
    let h = host.lowercased()
    for entry in domains where !entry.isEmpty {
      if h == entry || h.hasSuffix(".\(entry)") { return true }
    }
    return false
  }
}
