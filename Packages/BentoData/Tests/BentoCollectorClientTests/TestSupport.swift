import Foundation

@testable import BentoCollectorClient

/// `services/testdata`, shared with the Rust tests.
let testdata = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .appending(path: "../../../../services/testdata")
  .standardized

/// The Rust collector's SQL migrations, in order.
func collectorMigrations() throws -> [String] {
  let directory = testdata.appending(path: "../crates/bento-store-sqlite/src/migrations").standardized
  return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "sql" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map { try String(contentsOf: $0, encoding: .utf8) }
}

struct Vectors: Decodable {
  struct StableIDCase: Decodable {
    let source_id: UUID
    let external_id: String
    let expected: UUID
  }
  struct DetailCase: Decodable {
    let markdown: String
    let encoded_base64: String
  }
  let namespace: UUID
  let stable_ids: [StableIDCase]
  let details: [DetailCase]

  static func load() throws -> Vectors {
    try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: testdata.appending(path: "vectors.json")))
  }
}
