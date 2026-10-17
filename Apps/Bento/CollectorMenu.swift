import ServiceManagement
import SwiftUI

struct CollectorMenu: View {
  let collector: CollectorController

  var body: some View {
    Text("Collector: \(collector.agentStatus.label)")
    if let lastIngest = collector.lastIngest {
      Text("Last sync \(lastIngest.date.formatted(date: .omitted, time: .standard)) · \(lastIngest.saved) new")
    }
    if let error = collector.lastError {
      Text("Error: \(error)")
    }
    Divider()
    Button("Emit Test Item") { Task { await collector.emitTestItem() } }
    Button("Sync Outbox Now") { Task { await collector.ingestNow() } }
    Divider()
    switch collector.agentStatus {
    case .enabled:
      Button("Stop Collector") { Task { await collector.unregister() } }
    case .requiresApproval:
      Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
    default:
      Button("Start Collector") { collector.register() }
    }
    Divider()
    Button("Quit Bento") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}
