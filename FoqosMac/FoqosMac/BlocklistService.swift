import Foundation

/// XPC interface between the FoqosMac container app (client) and the
/// FoqosMacFilter system extension (server). The same `@objc protocol`
/// declaration must exist in both targets so NSXPCInterface(with:) introspects
/// matching Objective-C runtime metadata on each end. The explicit @objc name
/// keeps that metadata stable across module renames.
///
/// Wire format: JSON-encoded BlocklistSnapshot in `data`. Reply `true` on
/// successful decode + apply, `false` on decode failure.
@objc(FoqosBlocklistService) protocol BlocklistService {
  func updateBlocklist(_ data: Data, withReply reply: @escaping (Bool) -> Void)
}
