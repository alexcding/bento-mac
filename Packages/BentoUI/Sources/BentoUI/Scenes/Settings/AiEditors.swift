import BentoData
import SwiftUI

struct AiProfileEditor: View {
  @State var profile: AiProfile
  let collectorAvailable: Bool
  let save: (AiProfile, String) -> Void
  let cancel: () -> Void
  @State private var apiKey = ""
  @State private var command = ""

  init(profile: AiProfile, collectorAvailable: Bool, save: @escaping (AiProfile, String) -> Void, cancel: @escaping () -> Void) {
    _profile = State(initialValue: profile)
    _command = State(initialValue: Self.commandText(profile.commandJSON))
    self.collectorAvailable = collectorAvailable
    self.save = save
    self.cancel = cancel
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $profile.name)
        Picker("Kind", selection: $profile.kind) {
          Text("Command-line tool").tag(AiProfile.Kind.cli)
          Text("HTTP API").tag(AiProfile.Kind.http)
        }
        switch profile.kind {
        case .cli:
          Picker("Tool", selection: $profile.preset) {
            Text("Claude Code").tag("claude")
            Text("Codex").tag("codex")
            Text("Custom").tag("custom")
          }
          if profile.preset == "custom" {
            TextField("Command", text: $command, prompt: Text("my-ai --model {model} --schema {schema_file}"))
            Text("Arguments separated by spaces. {model}, {schema_file} and {output_file} are filled in; the prompt arrives on stdin.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        case .http:
          TextField("Base URL", text: $profile.baseURL, prompt: Text("https://api.deepseek.com"))
          if collectorAvailable {
            SecureField("API key", text: $apiKey, prompt: Text("Leave empty to keep the saved key"))
          }
        }
        TextField("Model", text: $profile.model, prompt: Text("Service default"))
        Stepper("Timeout: \(profile.timeoutSeconds) s", value: $profile.timeoutSeconds, in: 10...900, step: 10)
      }
      .formStyle(.grouped)
      .navigationTitle(profile.name)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            profile.commandJSON = Self.commandJSON(command)
            save(profile, apiKey)
          }
          .disabled(profile.name.isEmpty || (profile.kind == .http && URL(string: profile.baseURL)?.host() == nil))
        }
      }
    }
    .frame(minWidth: 480, minHeight: 380)
  }

  static func commandText(_ json: String) -> String {
    ((try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []).joined(separator: " ")
  }

  static func commandJSON(_ text: String) -> String {
    let parts = text.split(separator: " ").map(String.init)
    return String(decoding: (try? JSONEncoder().encode(parts)) ?? Data("[]".utf8), as: UTF8.self)
  }
}

struct AiTaskEditor: View {
  @State var task: AiTask
  let profiles: [AiProfile]
  let save: (AiTask) -> Void
  let cancel: () -> Void

  init(task: AiTask, profiles: [AiProfile], save: @escaping (AiTask) -> Void, cancel: @escaping () -> Void) {
    _task = State(initialValue: task)
    self.profiles = profiles
    self.save = save
    self.cancel = cancel
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $task.name)
          Picker("Profile", selection: $task.profileID) {
            Text("First profile").tag(AiProfile.ID?.none)
            ForEach(profiles) { Text($0.name).tag(AiProfile.ID?.some($0.id)) }
          }
          ForEach(profiles.filter { $0.id != task.profileID }) { profile in
            Toggle("Fall back to \(profile.name)", isOn: Binding(
              get: { task.fallback.contains(profile.id) },
              set: { on in
                task.fallback.removeAll { $0 == profile.id }
                if on { task.fallback.append(profile.id) }
              }
            ))
          }
        }
        Section("Instructions") {
          TextEditor(text: $task.instructions).frame(minHeight: 120).font(.body)
        }
        Section {
          ForEach(task.outputs.indices, id: \.self) { index in
            OutputRow(output: $task.outputs[index]) { task.outputs.remove(at: index) }
          }
          Button("Add Output", systemImage: "plus") {
            task.outputs.append(.init(name: "field\(task.outputs.count + 1)", target: "summary", description: ""))
          }
        } header: {
          Text("Outputs")
        } footer: {
          Text("Each output is a field the AI returns per item, written into the item's translated title, summary, text or article detail.")
        }
        Section("Limits") {
          Stepper("Items per call: \(task.batchSize)", value: $task.batchSize, in: 1...20)
          Stepper("Input per call: \(task.maxInputChars) characters", value: $task.maxInputChars, in: 1_000...50_000, step: 500)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(task.name)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save(task) }
            .disabled(task.instructions.isEmpty || task.outputs.isEmpty || task.outputs.contains { $0.name.isEmpty })
        }
      }
    }
    .frame(minWidth: 540, minHeight: 560)
  }
}

private struct OutputRow: View {
  @Binding var output: AiTask.Output
  let remove: () -> Void

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        TextField("Field name", text: $output.name)
        Picker("Writes to", selection: $output.target) {
          ForEach(AiTask.targets, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
        }
        .fixedSize()
        Button("Remove", systemImage: "minus.circle", action: remove).labelStyle(.iconOnly).buttonStyle(.borderless)
      }
      TextField("What the AI should return", text: $output.description)
        .font(.caption)
    }
  }
}
