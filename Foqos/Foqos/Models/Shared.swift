import FamilyControls
import Foundation
import OSLog

enum SharedData {
  private static let suite = UserDefaults(
    suiteName: "group.com.usetessera.mybrick"
  )!

  // MARK: – Keys
  private enum Key: String {
    case profileSnapshots
    case activeScheduleSession
    case completedScheduleSessions
  }

  // MARK: – Serializable snapshot of a profile (no sessions)
  struct ProfileSnapshot: Codable, Equatable {
    var id: UUID
    var name: String
    var selectedActivity: FamilyActivitySelection
    var createdAt: Date
    var updatedAt: Date
    var blockingStrategyId: String?
    var strategyData: Data?
    var order: Int

    var enableLiveActivity: Bool
    var reminderTimeInSeconds: UInt32?
    var customReminderMessage: String?
    var enableBreaks: Bool
    var breakTimeInMinutes: Int = 15
    var enableStrictMode: Bool
    var enableAllowMode: Bool
    var enableAllowModeDomains: Bool
    var enableSafariBlocking: Bool
    var enableAdultContentBlocking: Bool? = nil

    var domains: [String]?

    @available(*, deprecated, message: "Use physicalUnblockItems instead")
    var physicalUnblockNFCTagId: String? = nil

    @available(*, deprecated, message: "Use physicalUnblockItems instead")
    var physicalUnblockQRCodeId: String? = nil

    var physicalUnblockItems: [PhysicalUnblockItem]? = nil

    var schedule: BlockedProfileSchedule?

    var disableBackgroundStops: Bool?
    var enableEmergencyUnblock: Bool?
  }

  // MARK: – Serializable snapshot of a session (no profile object)
  struct SessionSnapshot: Codable, Equatable {
    var id: String
    var tag: String
    var blockedProfileId: UUID

    var startTime: Date
    var endTime: Date?

    var breakStartTime: Date?
    var breakEndTime: Date?

    var pauseStartTime: Date?
    var pauseEndTime: Date?

    var forceStarted: Bool
  }

  // MARK: – Persisted snapshots keyed by profile ID (UUID string)
  static var profileSnapshots: [String: ProfileSnapshot] {
    get {
      guard let data = suite.data(forKey: Key.profileSnapshots.rawValue) else { return [:] }
      return (try? JSONDecoder().decode([String: ProfileSnapshot].self, from: data)) ?? [:]
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.profileSnapshots.rawValue)
      } else {
        suite.removeObject(forKey: Key.profileSnapshots.rawValue)
      }
    }
  }

  static func snapshot(for profileID: String) -> ProfileSnapshot? {
    profileSnapshots[profileID]
  }

  static func setSnapshot(_ snapshot: ProfileSnapshot, for profileID: String) {
    var all = profileSnapshots
    all[profileID] = snapshot
    profileSnapshots = all

    if let active = activeSharedSession,
      active.blockedProfileId.uuidString == profileID
    {
      ICloudStateBridge.setDomains(snapshot.domains ?? [])
    }
  }

  static func removeSnapshot(for profileID: String) {
    var all = profileSnapshots
    all.removeValue(forKey: profileID)
    profileSnapshots = all
  }

  // MARK: – Persisted array of scheduled sessions
  static var completedSessionsInSchedular: [SessionSnapshot] {
    get {
      guard let data = suite.data(forKey: Key.completedScheduleSessions.rawValue) else { return [] }
      return (try? JSONDecoder().decode([SessionSnapshot].self, from: data)) ?? []
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.completedScheduleSessions.rawValue)
      } else {
        suite.removeObject(forKey: Key.completedScheduleSessions.rawValue)
      }
    }
  }

  // MARK: – Persisted array of scheduled sessions
  static var activeSharedSession: SessionSnapshot? {
    get {
      guard let data = suite.data(forKey: Key.activeScheduleSession.rawValue) else { return nil }
      return (try? JSONDecoder().decode(SessionSnapshot.self, from: data)) ?? nil
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        suite.set(data, forKey: Key.activeScheduleSession.rawValue)
      } else {
        suite.removeObject(forKey: Key.activeScheduleSession.rawValue)
      }
    }
  }

  static func createSessionForSchedular(for profileID: UUID) {
    activeSharedSession = SessionSnapshot(
      id: UUID().uuidString,
      tag: profileID.uuidString,
      blockedProfileId: profileID,
      startTime: Date(),
      forceStarted: true)

    let domains = profileSnapshots[profileID.uuidString]?.domains ?? []
    ICloudStateBridge.sessionStarted(profileId: profileID, domains: domains)
  }

  static func createActiveSharedSession(for session: SessionSnapshot) {
    activeSharedSession = session

    let domains = profileSnapshots[session.blockedProfileId.uuidString]?.domains ?? []
    ICloudStateBridge.sessionStarted(profileId: session.blockedProfileId, domains: domains)
  }

  static func getActiveSharedSession() -> SessionSnapshot? {
    activeSharedSession
  }

  static func endActiveSharedSession() {
    guard var existingScheduledSession = activeSharedSession else { return }

    existingScheduledSession.endTime = Date()
    completedSessionsInSchedular.append(existingScheduledSession)

    activeSharedSession = nil
    ICloudStateBridge.sessionEnded()
  }

  static func flushActiveSession() {
    activeSharedSession = nil
    ICloudStateBridge.sessionEnded()
  }

  static func getCompletedSessionsForSchedular() -> [SessionSnapshot] {
    completedSessionsInSchedular
  }

  static func flushCompletedSessionsForSchedular() {
    completedSessionsInSchedular = []
  }

  static func setBreakStartTime(date: Date) {
    guard activeSharedSession != nil else { return }
    activeSharedSession?.breakStartTime = date
    ICloudStateBridge.setBreakActive(true)
  }

  static func setBreakEndTime(date: Date) {
    guard activeSharedSession != nil else { return }
    activeSharedSession?.breakEndTime = date
    ICloudStateBridge.setBreakActive(false)
  }

  static func setEndTime(date: Date) {
    activeSharedSession?.endTime = date
  }

  static func resetPause() {
    activeSharedSession?.pauseStartTime = nil
    activeSharedSession?.pauseEndTime = nil
  }

  static func setPauseStartTime(date: Date) {
    guard activeSharedSession != nil else { return }
    activeSharedSession?.pauseStartTime = date
    ICloudStateBridge.setPauseActive(true)
  }

  static func setPauseEndTime(date: Date) {
    guard activeSharedSession != nil else { return }
    activeSharedSession?.pauseEndTime = date
    ICloudStateBridge.setPauseActive(false)
  }
}

// MARK: – iCloud State Bridge (Phase A)
//
// Mirrors session state to NSUbiquitousKeyValueStore so the macOS companion
// (FoqosMac) can observe iOS blocking state. iOS writes; Mac reads.
// Inlined here to avoid registering a new file with all 4 Xcode targets.
private enum ICloudStateBridge {
  private static let log = Logger(
    subsystem: "com.usetessera.mybrick", category: "iCloudBridge")
  private static let store = NSUbiquitousKeyValueStore.default

  private enum Key {
    static let isBlocked = "mybrick.isBlocked"
    static let isBreakActive = "mybrick.isBreakActive"
    static let isPauseActive = "mybrick.isPauseActive"
    static let activeBlocklistDomains = "mybrick.activeBlocklistDomains"
    static let activeProfileId = "mybrick.activeProfileId"
    static let lastUpdated = "mybrick.lastUpdated"
  }

  static func sessionStarted(profileId: UUID, domains: [String]) {
    store.set(true, forKey: Key.isBlocked)
    store.set(false, forKey: Key.isBreakActive)
    store.set(false, forKey: Key.isPauseActive)
    store.set(profileId.uuidString, forKey: Key.activeProfileId)
    writeDomains(domains)
    touch()
    log.info(
      "sessionStarted profile=\(profileId.uuidString, privacy: .public) domains=\(domains.count, privacy: .public)"
    )
  }

  static func sessionEnded() {
    store.set(false, forKey: Key.isBlocked)
    store.set(false, forKey: Key.isBreakActive)
    store.set(false, forKey: Key.isPauseActive)
    store.removeObject(forKey: Key.activeProfileId)
    store.removeObject(forKey: Key.activeBlocklistDomains)
    touch()
    log.info("sessionEnded")
  }

  static func setBreakActive(_ active: Bool) {
    store.set(active, forKey: Key.isBreakActive)
    touch()
    log.info("breakActive=\(active, privacy: .public)")
  }

  static func setPauseActive(_ active: Bool) {
    store.set(active, forKey: Key.isPauseActive)
    touch()
    log.info("pauseActive=\(active, privacy: .public)")
  }

  static func setDomains(_ domains: [String]) {
    writeDomains(domains)
    touch()
    log.info("domainsUpdated count=\(domains.count, privacy: .public)")
  }

  private static func writeDomains(_ domains: [String]) {
    if let data = try? JSONEncoder().encode(domains) {
      store.set(data, forKey: Key.activeBlocklistDomains)
    } else {
      store.removeObject(forKey: Key.activeBlocklistDomains)
    }
  }

  private static func touch() {
    store.set(Date().timeIntervalSince1970, forKey: Key.lastUpdated)
    store.synchronize()
  }
}
