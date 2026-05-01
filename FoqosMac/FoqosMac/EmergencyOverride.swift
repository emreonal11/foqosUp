import Foundation
import OSLog
import Security

/// Keychain-backed emergency override PIN, stored locally on this Mac only.
///
/// Use case: iPhone is dead / iCloud is broken / user genuinely needs to lift
/// blocking before the iPhone can do it. The PIN is per-Mac, never written to
/// iCloud — so engaging the override does NOT propagate back to iPhone state.
/// (The iPhone is still authoritative; this only affects what the Mac filter
/// sees.)
///
/// Recovery if forgotten:
///   security delete-generic-password -s 'com.usetessera.mybrick.emergency'
///
/// PIN material is stored as raw UTF-8 bytes under `kSecClassGenericPassword`
/// with the default access control (`kSecAttrAccessibleWhenUnlocked`). No
/// Touch ID gate — the PIN itself is the friction. The constant-time compare
/// is overkill against a 10⁴-keyspace, but keeps reviewers from pattern-
/// matching `==` on secret material.
enum EmergencyOverride {
  private static let log = Logger(subsystem: "com.usetessera.mybrick", category: "EmergencyOverride")
  private static let service = "com.usetessera.mybrick.emergency"
  private static let account = "pin"

  static var isPINSet: Bool {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    let status = SecItemCopyMatching(q as CFDictionary, nil)
    return status == errSecSuccess
  }

  /// Set or replace the PIN. Caller is responsible for validating the input
  /// (e.g. exactly 4 numeric digits) before passing it in.
  static func setPIN(_ pin: String) throws {
    guard let data = pin.data(using: .utf8) else {
      throw EmergencyOverrideError.encoding
    }

    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let updateAttrs: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
    if updateStatus == errSecSuccess {
      log.info("PIN updated")
      return
    }

    guard updateStatus == errSecItemNotFound else {
      throw EmergencyOverrideError.keychain(updateStatus)
    }

    var addQuery = baseQuery
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw EmergencyOverrideError.keychain(addStatus)
    }
    log.info("PIN created")
  }

  /// Constant-time PIN check.
  static func verifyPIN(_ pin: String) -> Bool {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    guard
      status == errSecSuccess,
      let data = out as? Data,
      let stored = String(data: data, encoding: .utf8)
    else {
      return false
    }
    return constantTimeEquals(stored, pin)
  }

  static func clearPIN() throws {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(q as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      throw EmergencyOverrideError.keychain(status)
    }
    log.info("PIN cleared")
  }

  private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count {
      diff |= aBytes[i] ^ bBytes[i]
    }
    return diff == 0
  }
}

enum EmergencyOverrideError: LocalizedError {
  case encoding
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .encoding: return "PIN could not be encoded."
    case .keychain(let status): return "Keychain error \(status)"
    }
  }
}
