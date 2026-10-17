import BentoData
import BentoUI
import SQLiteData
import SwiftUI

@main
struct BentoApp: App {
  static let mainWindowID = "main"
  static let collectorWindowID = "collector"

  @State private var coordinator: AppCoordinator
  @State private var collector: CollectorService
  @State private var collectorModel: CollectorViewModel
  @State private var settingsModel: SettingsViewModel

  init() {
    let directory = try! BentoDatabase.defaultDirectory()
    let container = (Bundle.main.object(forInfoDictionaryKey: "BentoICloudContainer") as? String)
      .flatMap { $0.isEmpty ? nil : $0 }
    try! prepareDependencies {
      try $0.bootstrapBento(databaseURL: directory.appending(path: "bento.sqlite"), iCloudContainer: container)
    }
    @Dependency(\.defaultDatabase) var database
    let collector = CollectorService(dataDirectory: directory, database: database)
    _collector = State(initialValue: collector)
    _collectorModel = State(initialValue: CollectorViewModel(service: collector))
    let store = NativeLibraryStore(database: database)
    _coordinator = State(
      initialValue: AppCoordinator(container: .native(store: store, statuses: collector, collector: collector))
    )
    _settingsModel = State(
      initialValue: NativeSettingsFeatureFactory(store: store, collector: collector).makeSettings()
    )
  }

  var body: some Scene {
    Window("Bento", id: Self.mainWindowID) {
      AppCoordinatorView(coordinator: coordinator)
    }
    .commands {
      CommandGroup(after: .windowArrangement) {
        OpenCollectorButton()
      }
    }

    Window("Collector", id: Self.collectorWindowID) {
      CollectorView(model: collectorModel)
    }

    Settings {
      SettingsView(model: settingsModel)
    }

    MenuBarExtra("Bento", systemImage: "tray.full") {
      MenuBarView(service: collector)
    }
  }
}

private struct OpenCollectorButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Collector Diagnostics") { openWindow(id: BentoApp.collectorWindowID) }
      .keyboardShortcut("l", modifiers: [.command, .option])
  }
}
