import Foundation
import OSLog
import ServiceManagement

/// Registers FoqosMac to launch automatically at user login via the modern
/// SMAppService API (macOS 13+). The user can manage the toggle in
/// System Settings → General → Login Items, where it shows up as "FoqosMac".
///
/// We register unconditionally on every launch from `FoqosMacApp.init`; the
/// `register()` call is idempotent — it returns success without modifying
/// state if the service is already enabled. If the user explicitly disabled
/// the login item in System Settings, `service.status` will report
/// `.requiresApproval` or `.notFound`; in those cases re-registering would
/// reactivate it, so we early-out on `.requiresApproval` to respect the
/// user's choice. (`.notFound` is the "never registered" baseline.)
enum LoginItem {
  private static let log = Logger(subsystem: "com.usetessera.mybrick", category: "LoginItem")

  static func ensureRegistered() {
    let service = SMAppService.mainApp
    let initial = service.status

    switch initial {
    case .enabled:
      log.info("Login item already enabled; no-op")
      return
    case .requiresApproval:
      // User disabled it in System Settings; do not re-enable.
      log.info("Login item requires user approval; respecting setting")
      return
    case .notRegistered, .notFound:
      break
    @unknown default:
      log.info(
        "Login item status unknown (\(String(describing: initial), privacy: .public)); attempting registration"
      )
    }

    do {
      try service.register()
      log.info(
        "Login item registered (new status=\(String(describing: service.status), privacy: .public))"
      )
    } catch {
      log.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
