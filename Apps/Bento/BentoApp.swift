import BentoData
import BentoUI
import SQLiteData
import SwiftUI

@main
struct BentoApp: App {
  @State private var collector: CollectorController

  init() {
    let directory = try! BentoDatabase.defaultDirectory()
    let container = (Bundle.main.object(forInfoDictionaryKey: "BentoICloudContainer") as? String)
      .flatMap { $0.isEmpty ? nil : $0 }
    try! prepareDependencies {
      try $0.bootstrapBento(
        databaseURL: directory.appending(path: "bento.sqlite"),
        iCloudContainer: container
      )
    }
    _collector = State(initialValue: CollectorController(dataDirectory: directory))
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .task { await collector.start() }
    }

    MenuBarExtra("Bento", systemImage: "tray.full") {
      CollectorMenu(collector: collector)
    }
  }
}
