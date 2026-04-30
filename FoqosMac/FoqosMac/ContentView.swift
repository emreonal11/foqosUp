import SwiftUI

struct ContentView: View {
  @EnvironmentObject var state: BridgeState

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: state.isBlocked ? "lock.fill" : "lock.open")
          .font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text("FoqosMac").font(.caption).foregroundStyle(.secondary)
          Text(state.summary).font(.title3.bold())
        }
      }

      Text(state.filterStatus.summary)
        .font(.caption)
        .foregroundStyle(filterStatusColor)

      Divider()

      Group {
        InfoRow(label: "isBlocked", value: state.isBlocked.description)
        InfoRow(label: "isBreakActive", value: state.isBreakActive.description)
        InfoRow(label: "isPauseActive", value: state.isPauseActive.description)
        InfoRow(label: "Profile", value: state.activeProfileId.map(prefix12) ?? "—")
        InfoRow(label: "Domains", value: "\(state.domains.count)")
      }

      if !state.domains.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(state.domains, id: \.self) { d in
              Text(d).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 100)
      }

      Divider()

      InfoRow(
        label: "Last updated",
        value: state.lastUpdated.map { Self.timeFmt.string(from: $0) } ?? "never"
      )

      HStack {
        Button("Force sync") { state.forceSync() }
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut("q")
      }
    }
    .padding()
    .frame(width: 320)
  }

  private func prefix12(_ s: String) -> String {
    s.count > 12 ? String(s.prefix(12)) + "…" : s
  }

  private var filterStatusColor: Color {
    switch state.filterStatus {
    case .activeAndConfigured: return .secondary
    case .error: return .red
    case .needsApproval, .willActivateAfterReboot: return .orange
    case .installing, .unknown: return .secondary
    }
  }

  private static let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .medium
    return f
  }()
}

private struct InfoRow: View {
  let label: String
  let value: String
  var body: some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).font(.system(.body, design: .monospaced))
    }
  }
}
