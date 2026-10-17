import BentoData
import SwiftUI

public struct SettingsView: View {
  @Bindable var model: SettingsViewModel

  public init(model: SettingsViewModel) {
    self.model = model
  }

  public var body: some View {
    TabView(selection: $model.tab) {
      ForEach(model.tabs) { tab in
        Group {
          switch tab {
          case .general: GeneralSettingsView(model: model)
          case .plugins: PluginsSettingsView(model: model)
          case .ai: AISettingsView(model: model)
          }
        }
        .tabItem { Label(tab.rawValue, systemImage: icon(tab)) }
        .tag(tab)
      }
    }
    .frame(minWidth: 620, minHeight: 480)
    .sheet(item: $model.login) { LoginView(model: $0) }
    .sheet(item: $model.editingProfile) { profile in
      AiProfileEditor(profile: profile, collectorAvailable: model.collector != nil, save: model.save, cancel: { model.editingProfile = nil })
    }
    .sheet(item: $model.editingTask) { task in
      AiTaskEditor(task: task, profiles: model.profiles, save: model.save, cancel: { model.editingTask = nil })
    }
  }

  private func icon(_ tab: SettingsViewModel.Tab) -> String {
    switch tab {
    case .general: "gearshape"
    case .plugins: "puzzlepiece.extension"
    case .ai: "sparkles"
    }
  }
}

private struct GeneralSettingsView: View {
  let model: SettingsViewModel

  var body: some View {
    Form {
      Section("Collecting") {
        Stepper(
          "Skip posts older than \(model.settings.maxItemAgeHours) hours",
          value: Binding(get: { model.settings.maxItemAgeHours }, set: { v in model.updateSettings { $0.maxItemAgeHours = v } }),
          in: 1...24 * 30,
          step: 12
        )
        Toggle(
          "Pause collecting on weekends",
          isOn: Binding(get: { model.settings.skipWeekends }, set: { v in model.updateSettings { $0.skipWeekends = v } })
        )
      }
    }
    .formStyle(.grouped)
  }
}

private struct PluginsSettingsView: View {
  let model: SettingsViewModel

  var body: some View {
    Form {
      if model.plugins.isEmpty {
        Text("The collector has not reported its plugins yet. Start the collector from the menu bar.")
          .foregroundStyle(.secondary)
      }
      ForEach(model.plugins) { plugin in
        Section {
          PluginRow(plugin: plugin, model: model)
        } header: {
          HStack {
            Text(plugin.name)
            if !plugin.version.isEmpty { Text(plugin.version).foregroundStyle(.secondary) }
          }
        }
      }
      if let message = model.message {
        Text(message).foregroundStyle(.orange)
      }
    }
    .formStyle(.grouped)
  }
}

private struct PluginRow: View {
  let plugin: PluginInfo
  let model: SettingsViewModel
  @State private var values: [String: String] = [:]

  var body: some View {
    if let error = plugin.loadError {
      Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
    }
    if !plugin.summary.isEmpty {
      Text(plugin.summary).font(.callout).foregroundStyle(.secondary)
    }
    ForEach(plugin.requirements, id: \.name) { requirement in
      HStack {
        Image(systemName: requirement.installed ? "checkmark.circle.fill" : "exclamationmark.circle")
          .foregroundStyle(requirement.installed ? .green : .orange)
        VStack(alignment: .leading) {
          Text(requirement.name)
          Text(requirement.installed ? requirement.detail : requirement.install)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    }
    ForEach(plugin.secretFields, id: \.key) { field in
      HStack {
        SecureField(field.label, text: Binding(get: { values[field.key, default: ""] }, set: { values[field.key] = $0 }))
        Text(model.secretStatus[plugin.id]?[field.key] == true ? "Set" : "Not set")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Save") {
          let value = values[field.key, default: ""]
          values[field.key] = ""
          Task { await model.saveSecret(value, key: field.key, plugin: plugin) }
        }
        .disabled(values[field.key, default: ""].isEmpty)
      }
      if let help = field.help {
        Text(help).font(.caption).foregroundStyle(.secondary)
      }
    }
    if plugin.hasInteractiveLogin {
      HStack {
        Text(model.isSignedIn(plugin) ? "Signed in" : "Not signed in").foregroundStyle(.secondary)
        Spacer()
        if model.isSignedIn(plugin) {
          Button("Sign Out") { Task { await model.signOut(plugin) } }
        }
        Button(model.isSignedIn(plugin) ? "Sign In Again" : "Sign In") { model.signIn(plugin) }
      }
    }
    EmptyView()
      .task { await model.refreshSecrets(for: plugin) }
  }
}

private struct AISettingsView: View {
  let model: SettingsViewModel

  var body: some View {
    Form {
      Section {
        ForEach(model.profiles) { profile in
          HStack {
            VStack(alignment: .leading) {
              Text(profile.name)
              Text(profile.kind == .http ? profile.baseURL : "\(profile.preset) CLI").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { model.editingProfile = profile }
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(profile) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
          }
        }
        Button("Add Profile", systemImage: "plus") { model.newProfile() }
      } header: {
        Text("Profiles")
      } footer: {
        Text("A profile is a saved connection to an AI service. Tasks without a profile use the first one.")
      }
      Section("Tasks") {
        ForEach(AiPresets.keys, id: \.self) { key in
          HStack {
            VStack(alignment: .leading) {
              Text(AiPresets.name(key))
              Text(model.customized(key) == nil ? "Built in" : "Customized").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { model.editPreset(key) }
            if let task = model.customized(key) {
              Button("Reset") { model.delete(task) }
            }
          }
        }
        ForEach(model.customTasks) { task in
          HStack {
            Text(task.name.isEmpty ? "Untitled task" : task.name)
            Spacer()
            Button("Edit") { model.editingTask = task }
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(task) }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
          }
        }
        Button("Add Task", systemImage: "plus") { model.newTask() }
      }
    }
    .formStyle(.grouped)
  }
}
