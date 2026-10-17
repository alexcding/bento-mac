import BentoData
import SwiftUI

struct AddSourceView: View {
  @Bindable var model: AddSourceViewModel

  var body: some View {
    NavigationStack {
      Group {
        switch model.step {
        case .choose:
          chooseList
        case .setup:
          if let plugin = model.plugin { SetupForm(model: model, plugin: plugin) }
        case .details:
          if let plugin = model.plugin { detailsForm(plugin) }
        }
      }
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { model.cancel() }
        }
        if model.step != .choose {
          ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { model.back() }
          }
        }
        if case .details = model.step {
          ToolbarItem(placement: .confirmationAction) {
            Button("Add") { model.add() }.disabled(!model.canAdd)
          }
        }
      }
    }
    .frame(minWidth: 480, minHeight: 420)
    .task { await model.load() }
    .sheet(item: $model.login) { LoginView(model: $0) }
  }

  private var title: String {
    switch model.step {
    case .choose: "Add Source"
    case .setup: "Set Up \(model.plugin?.name ?? "")"
    case .details: model.plugin?.name ?? "Add Source"
    }
  }

  private var chooseList: some View {
    List(model.plugins) { plugin in
      Button {
        model.choose(plugin)
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(plugin.name)
            if !plugin.summary.isEmpty {
              Text(plugin.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          Spacer()
          badge(model.setup(for: plugin))
          Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  @ViewBuilder
  private func badge(_ setup: AddSourceViewModel.Setup) -> some View {
    if !setup.missingPrograms.isEmpty {
      Text("Needs \(setup.missingPrograms.map(\.name).formatted())").font(.caption).foregroundStyle(.orange)
    } else if setup.needsSignIn {
      Text("Needs sign-in").font(.caption).foregroundStyle(.orange)
    } else if model.checksSetup {
      Text("Ready").font(.caption).foregroundStyle(.green)
    }
  }

  private func detailsForm(_ plugin: PluginInfo) -> some View {
    Form {
      Section {
        TextField(plugin.queryHint ?? "Query", text: $model.query)
          .onSubmit { model.add() }
        TextField("Name (optional)", text: $model.name)
        Toggle("Skip posts that already exist", isOn: $model.skipsBacklog)
      } footer: {
        Text(
          plugin.id == "rss"
            ? "The feed's web address."
            : "Leave the query empty for the plugin's default feed, where it has one."
        )
      }
    }
    .formStyle(.grouped)
  }
}

/// What a plugin is missing: programs to install, and a sign-in or secrets to enter.
private struct SetupForm: View {
  @Bindable var model: AddSourceViewModel
  let plugin: PluginInfo

  var body: some View {
    let setup = model.setup(for: plugin)
    Form {
      if !setup.missingPrograms.isEmpty {
        Section {
          ForEach(setup.missingPrograms, id: \.name) { program in
            VStack(alignment: .leading, spacing: 4) {
              Text(program.name).bold()
              if !program.install.isEmpty {
                Text(program.install).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              }
            }
          }
          HStack {
            Button("Check Again") { Task { await model.checkAgain() } }
            if model.isWorking { ProgressView().controlSize(.small) }
          }
        } header: {
          Text("Install")
        } footer: {
          Text("Install these in Terminal, then check again.")
        }
      }
      if setup.needsSignIn {
        Section("Sign in") {
          if plugin.hasInteractiveLogin {
            Button("Sign In to \(plugin.name)…") { model.signIn() }
          } else {
            ForEach(plugin.secretFields, id: \.key) { field in
              VStack(alignment: .leading, spacing: 4) {
                SecureField(field.label, text: binding(field.key))
                if let help = field.help {
                  Text(help).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            HStack {
              Button("Save and Continue") { Task { await model.saveSecrets() } }
                .disabled(!model.canSaveSecrets || model.isWorking)
              if model.isWorking { ProgressView().controlSize(.small) }
            }
          }
        }
      }
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.orange)
      }
    }
    .formStyle(.grouped)
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(get: { model.secretValues[key, default: ""] }, set: { model.secretValues[key] = $0 })
  }
}
