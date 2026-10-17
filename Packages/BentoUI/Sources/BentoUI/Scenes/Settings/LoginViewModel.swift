import Foundation
import Observation

/// One interactive plugin login: shows the plugin's prompts (QR code or text) until it finishes.
@MainActor
@Observable
public final class LoginViewModel: Identifiable {
  public let id = UUID()
  let pluginName: String
  private(set) var prompt: LoginEvent?
  private(set) var failure: String?
  private(set) var isDone = false
  var input = ""
  @ObservationIgnored var onFinish: () -> Void = {}
  @ObservationIgnored private let session: any LoginSession
  @ObservationIgnored private var listener: Task<Void, Never>?

  init(pluginName: String, session: any LoginSession) {
    self.pluginName = pluginName
    self.session = session
  }

  func start() {
    guard listener == nil else { return }
    listener = Task { [weak self, session] in
      for await event in session.events {
        self?.handle(event)
      }
    }
  }

  func handle(_ event: LoginEvent) {
    switch event {
    case .prompt:
      prompt = event
      failure = nil
    case .done:
      isDone = true
    case .failed(let message):
      failure = message
    }
  }

  var wantsInput: Bool {
    if case .prompt(let kind, _, _) = prompt { kind != .qr } else { false }
  }

  func submit() {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    session.send(value)
    input = ""
  }

  func close() {
    if !isDone { session.cancel() }
    listener?.cancel()
    onFinish()
  }
}
