import ServiceManagement
import SwiftUI

struct MenuBarView: View {
  let service: CollectorService
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if service.isThisMacCollector {
      Text("Collector: \(service.agentStatus.label)")
    } else {
      Text("Collecting on \(service.collectorDeviceName ?? "no Mac yet")")
    }
    if let sync = service.lastSync {
      Text("Last sync \(sync.date.formatted(date: .omitted, time: .standard)) · \(sync.saved) new")
    }
    if let error = service.lastError {
      Text("Error: \(error)")
    }
    Divider()
    Button("Open Bento") {
      openWindow(id: BentoApp.mainWindowID)
      NSApplication.shared.activate()
    }
    Button("Collector Diagnostics…") {
      openWindow(id: BentoApp.collectorWindowID)
      NSApplication.shared.activate()
    }
    Button("Sync Now") { Task { await service.sync() } }
    Divider()
    switch service.isThisMacCollector ? service.agentStatus : nil {
    case nil:
      Button("Collect on This Mac") { Task { try? await service.becomeCollector() } }
    case .enabled:
      Button("Restart Collector") { Task { await service.restart() } }
      Button("Stop Collector") { Task { await service.stop() } }
    case .requiresApproval:
      Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
    default:
      Button("Start Collector") { service.start() }
    }
    Divider()
    Button("Quit Bento") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}
