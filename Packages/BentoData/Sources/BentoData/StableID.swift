import CryptoKit
import Foundation

/// Deterministic IDs, identical to `bento_domain::stable_id`. Checked against
/// `services/testdata/vectors.json`.
public enum StableID {
  /// Never change it: every stored feed item ID depends on it.
  public static let feedItemNamespace = UUID(uuidString: "f3433bf7-7680-4fa1-b060-63c040a86a9a")!

  public static func feedItem(sourceID: UUID, externalID: String) -> UUID {
    uuidV5(namespace: feedItemNamespace, name: "\(sourceID.uuidString.lowercased()):\(externalID)")
  }

  static func uuidV5(namespace: UUID, name: String) -> UUID {
    var input = withUnsafeBytes(of: namespace.uuid) { Data($0) }
    input.append(Data(name.utf8))
    var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }
}
