import Foundation

/// Extracts the Server Name Indication (SNI) hostname from a TLS ClientHello.
///
/// We see only the first peeked outbound bytes (typically 1024). For TLS 1.2 and
/// 1.3 the ClientHello is the very first record on the wire, plaintext until ECH
/// is widely deployed. ECH adoption among major distractor sites is ~zero in 2026
/// (CLAUDE.md §3); this parser will need to be replaced or augmented if/when ECH
/// matters.
///
/// References:
///   RFC 8446 §4.1.2 — ClientHello structure (TLS 1.3)
///   RFC 5246 §7.4.1.2 — ClientHello structure (TLS 1.2)
///   RFC 6066 §3 — SNI extension
///
/// Defensive design: every read is bounds-checked through `Cursor`. Any malformed
/// input causes an immediate nil return — never a crash, never an out-of-range read.
enum SNIParser {
  /// Returns the lowercased SNI hostname, or nil if the bytes are not a parseable
  /// ClientHello with a present-and-valid host_name SNI entry.
  static func extractSNI(from data: Data) -> String? {
    var cursor = Cursor(data: data)

    // TLS record layer: ContentType(1) + ProtocolVersion(2) + length(2)
    guard let recordType = cursor.read1(), recordType == 0x16 else { return nil }
    guard cursor.skip(2) else { return nil }  // record version
    guard cursor.read2() != nil else { return nil }  // record length (unused)

    // Handshake header: msg_type(1) + length(3)
    guard let hsType = cursor.read1(), hsType == 0x01 else { return nil }  // ClientHello
    guard cursor.skip(3) else { return nil }  // handshake length (unused)

    // ClientHello body: legacy_version(2) + random(32)
    guard cursor.skip(2 + 32) else { return nil }

    // legacy_session_id<0..32>
    guard let sidLen = cursor.read1(), cursor.skip(Int(sidLen)) else { return nil }

    // cipher_suites<2..2^16-2>
    guard let cipherLen = cursor.read2(), cursor.skip(Int(cipherLen)) else { return nil }

    // legacy_compression_methods<1..2^8-1>
    guard let compLen = cursor.read1(), cursor.skip(Int(compLen)) else { return nil }

    // extensions<8..2^16-1>
    guard let extLen = cursor.read2() else { return nil }
    let extensionsEnd = cursor.position + Int(extLen)
    guard extensionsEnd <= data.count else { return nil }

    while cursor.position < extensionsEnd {
      guard let extType = cursor.read2(),
        let extDataLen = cursor.read2()
      else { return nil }
      let extEnd = cursor.position + Int(extDataLen)
      guard extEnd <= extensionsEnd else { return nil }

      if extType == 0x0000 {  // server_name extension
        return parseServerNameList(cursor: &cursor, end: extEnd)
      }
      cursor.position = extEnd
    }
    return nil
  }

  /// Parses a server_name_list and returns the first host_name entry.
  /// `cursor` is positioned at the start of the extension's data; `end` is the
  /// extension's data end position (absolute index into the buffer).
  private static func parseServerNameList(cursor: inout Cursor, end: Int) -> String? {
    guard let listLen = cursor.read2() else { return nil }
    let listEnd = cursor.position + Int(listLen)
    guard listEnd <= end else { return nil }

    while cursor.position < listEnd {
      guard let nameType = cursor.read1(),
        let nameLen = cursor.read2()
      else { return nil }
      let nameEnd = cursor.position + Int(nameLen)
      guard nameEnd <= listEnd else { return nil }

      if nameType == 0x00 {  // host_name
        guard let bytes = cursor.readBytes(Int(nameLen)),
          let hostname = String(bytes: bytes, encoding: .ascii)
        else { return nil }
        return hostname.lowercased()
      }
      cursor.position = nameEnd
    }
    return nil
  }
}

/// Bounds-checked read cursor over a Data buffer. Returns nil on any read past end.
private struct Cursor {
  let data: Data
  var position: Int = 0

  mutating func skip(_ n: Int) -> Bool {
    guard n >= 0, position + n <= data.count else { return false }
    position += n
    return true
  }

  mutating func read1() -> UInt8? {
    guard position < data.count else { return nil }
    let v = data[data.startIndex + position]
    position += 1
    return v
  }

  mutating func read2() -> UInt16? {
    guard position + 2 <= data.count else { return nil }
    let hi = data[data.startIndex + position]
    let lo = data[data.startIndex + position + 1]
    position += 2
    return (UInt16(hi) << 8) | UInt16(lo)
  }

  mutating func readBytes(_ n: Int) -> [UInt8]? {
    guard n >= 0, position + n <= data.count else { return nil }
    let start = data.startIndex + position
    let bytes = Array(data[start..<start + n])
    position += n
    return bytes
  }
}

#if DEBUG
  /// Runtime sanity-check the parser at extension startup. Logs the result.
  /// If this ever fails, the SNI logic regressed — investigate before shipping.
  enum SNIParserSanityCheck {
    /// Minimal hand-built TLS 1.2 ClientHello with SNI = "example.com".
    /// Fields:
    ///   record: type=0x16, version=0x0301, length=0x0034 (52)
    ///   handshake: type=0x01, length=0x000030 (48)
    ///   client_hello body:
    ///     legacy_version: 0x0303
    ///     random: 32 bytes of zero
    ///     legacy_session_id: 0x00 (empty)
    ///     cipher_suites: length=0x0002, one suite 0x0035
    ///     legacy_compression_methods: length=0x01, 0x00
    ///     extensions: length=0x0014 (20)
    ///       server_name extension:
    ///         extType=0x0000, extDataLen=0x0010 (16)
    ///         server_name_list length=0x000e (14)
    ///         entry: nameType=0x00, hostnameLen=0x000b (11), "example.com"
    static let goldenClientHello: Data = {
      var b: [UInt8] = []
      b += [0x16, 0x03, 0x01, 0x00, 0x34]  // record header
      b += [0x01, 0x00, 0x00, 0x30]  // handshake header
      b += [0x03, 0x03]  // legacy_version
      b += Array(repeating: 0x00, count: 32)  // random
      b += [0x00]  // legacy_session_id length
      b += [0x00, 0x02, 0x00, 0x35]  // cipher_suites
      b += [0x01, 0x00]  // compression_methods
      b += [0x00, 0x14]  // extensions length = 20
      b += [0x00, 0x00, 0x00, 0x10]  // server_name extType + len
      b += [0x00, 0x0e]  // list length
      b += [0x00, 0x00, 0x0b]  // entry: type=host_name, len=11
      b += Array("example.com".utf8)
      return Data(b)
    }()

    static func runOnce(log: (String) -> Void) {
      let result = SNIParser.extractSNI(from: goldenClientHello)
      if result == "example.com" {
        log("SNIParser sanity ✓ (golden ClientHello → example.com)")
      } else {
        log("SNIParser sanity ✗ — got \(result ?? "nil"), expected example.com")
      }
      // Truncated input must return nil, never crash.
      let truncated = goldenClientHello.prefix(20)
      let nilResult = SNIParser.extractSNI(from: Data(truncated))
      if nilResult == nil {
        log("SNIParser sanity ✓ (truncated input → nil)")
      } else {
        log("SNIParser sanity ✗ — truncated input returned \(nilResult!)")
      }
    }
  }
#endif
