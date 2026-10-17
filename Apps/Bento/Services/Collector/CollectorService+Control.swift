import BentoCollectorClient
import BentoData
import BentoUI
import Foundation

/// Plugin secrets, logins, Fetch Now and Preview, through the bundled `bento-collector`. Secret
/// values go to it on stdin and never come back.
extension CollectorService: CollectorControlling {
  func secretStatus(pluginID: String) async throws -> [String: Bool] {
    let output = try await CollectorCommand.run(["secrets", "status", pluginID])
    return (try JSONSerialization.jsonObject(with: output) as? [String: Bool]) ?? [:]
  }

  func setSecret(pluginID: String, key: String, value: String) async throws {
    _ = try await CollectorCommand.run(["secrets", "set", pluginID, key], input: Data(value.utf8))
  }

  func deleteSecret(pluginID: String, key: String) async throws {
    _ = try await CollectorCommand.run(["secrets", "delete", pluginID, key])
  }

  func startLogin(pluginID: String) -> any LoginSession {
    CollectorLoginSession(pluginID: pluginID)
  }

  func fetchNow(sourceID: Source.ID) async throws -> RunSummary {
    await sync()  // the collector reads the latest config
    let output = try await CollectorCommand.run(["run-once", "--source", sourceID.uuidString.lowercased()])
    let json = try JSONSerialization.jsonObject(with: output) as? [String: Any] ?? [:]
    await sync()  // bring the new items in
    return RunSummary(
      fetched: json["fetched"] as? Int ?? 0,
      new: json["new"] as? Int ?? 0,
      backlogSkipped: json["backlog_skipped"] as? Int ?? 0,
      aiFailures: json["ai_failures"] as? [String] ?? [],
      error: json["error"] as? String
    )
  }

  func preview(sourceID: Source.ID) async throws -> PreviewResult {
    await sync()
    let output = try await CollectorCommand.run(["run-once", "--source", sourceID.uuidString.lowercased(), "--dry-run"])
    let json = try JSONSerialization.jsonObject(with: output) as? [String: Any] ?? [:]
    let items = try (json["items"] as? [[String: Any]] ?? []).compactMap { entry -> FeedItem? in
      guard let item = entry["item"] else { return nil }
      return try decodeCollectorFeedItem(JSONSerialization.data(withJSONObject: item))
    }
    return PreviewResult(
      items: items,
      aiFailures: json["ai_failures"] as? [String] ?? [],
      backlogSkipped: json["backlog_skipped"] as? Int ?? 0
    )
  }
}

enum CollectorCommand {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static var executable: URL? { Bundle.main.url(forAuxiliaryExecutable: "bento-collector") }

  /// Runs `bento-collector` and returns its stdout. A non-zero exit throws with its stderr.
  static func run(_ arguments: [String], input: Data? = nil) async throws -> Data {
    guard let executable else { throw Failure(message: "bento-collector is missing from the app bundle") }
    return try await Task.detached {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      let stdout = Pipe()
      let stderr = Pipe()
      let stdin = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      process.standardInput = stdin
      try process.run()
      if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
      try stdin.fileHandleForWriting.close()
      let output = stdout.fileHandleForReading.readDataToEndOfFile()
      let errors = stderr.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let message = String(decoding: errors, as: UTF8.self)
          .split(separator: "\n").last.map(String.init) ?? "bento-collector exited with \(process.terminationStatus)"
        throw Failure(message: message)
      }
      return output
    }.value
  }
}

/// `bento-collector plugin auth <id> --json`: one JSON step per line on stdout, typed input on
/// stdin.
@MainActor
final class CollectorLoginSession: LoginSession {
  let events: AsyncStream<LoginEvent>
  private let process = Process()
  private let input = Pipe()

  init(pluginID: String) {
    let process = process
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = CollectorCommand.executable
    process.arguments = ["plugin", "auth", pluginID, "--json"]
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = input
    // A write racing the process's exit must fail with EPIPE, not kill the app with SIGPIPE.
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    events = AsyncStream { continuation in
      Task.detached {
        do {
          try process.run()
        } catch {
          continuation.yield(.failed(error.localizedDescription))
          continuation.finish()
          return
        }
        var sawDone = false
        do {
          for try await line in output.fileHandleForReading.bytes.lines {
            guard let step = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let event = Self.event(step)
            if event == .done { sawDone = true }
            continuation.yield(event)
          }
        } catch {
          continuation.yield(.failed(error.localizedDescription))
        }
        process.waitUntilExit()
        if process.terminationStatus != 0, !sawDone {
          let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? "Sign-in failed"
          continuation.yield(.failed(message.replacingOccurrences(of: "Error: ", with: "")))
        }
        continuation.finish()
      }
    }
  }

  nonisolated static func event(_ step: [String: Any]) -> LoginEvent {
    switch step["status"] as? String {
    case "done":
      return .done
    case "failed":
      return .failed(step["error"] as? String ?? "Sign-in failed")
    default:
      let prompt = step["prompt"] as? [String: Any]
      let kind = LoginEvent.PromptKind(rawValue: prompt?["kind"] as? String ?? "") ?? .qr
      return .prompt(kind: kind, message: prompt?["message"] as? String ?? "", qr: prompt?["qr"] as? String)
    }
  }

  func send(_ text: String) {
    // Writing after the process exited would raise SIGPIPE (see init); skip it.
    guard process.isRunning else { return }
    try? input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
  }

  func cancel() {
    if process.isRunning { process.terminate() }
  }
}
