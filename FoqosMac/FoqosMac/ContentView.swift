import SwiftUI

struct ContentView: View {
  @EnvironmentObject var state: BridgeState
  @State private var mode: Mode = .main
  @State private var pinInput: String = ""
  @State private var pinError: String?
  @FocusState private var pinFocused: Bool

  enum Mode {
    case main
    case settingPIN
    case enteringPIN
  }

  var body: some View {
    Group {
      switch mode {
      case .main: mainView
      case .settingPIN:
        pinEntryView(
          title: "Set Emergency PIN",
          prompt:
            "Choose a 4-digit PIN. You can use it later to disable Mac blocking locally if your iPhone can't reach iCloud (e.g. dead battery). Stored only on this Mac.",
          buttonLabel: "Set",
          action: doSetPIN
        )
      case .enteringPIN:
        pinEntryView(
          title: "Emergency Unblock",
          prompt:
            "Enter your 4-digit emergency PIN. Mac blocking will lift locally and auto-resume on the next iPhone state change.",
          buttonLabel: "Unblock",
          action: doUnblock
        )
      }
    }
    .padding()
    .frame(width: 320)
  }

  // MARK: - Main view

  private var mainView: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      filterCaption
      Divider()
      domainCount
      emergencyRow
      Divider()
      footer
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: state.menuBarSymbol)
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text("FoqosMac").font(.caption).foregroundStyle(.secondary)
        Text(state.summary).font(.title3.bold())
      }
    }
  }

  private var filterCaption: some View {
    Text(state.filterStatus.summary)
      .font(.caption)
      .foregroundStyle(filterStatusColor)
  }

  private var domainCount: some View {
    Text(domainCountText)
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var emergencyRow: some View {
    if state.emergencyOverrideActive {
      VStack(alignment: .leading, spacing: 6) {
        Text("Emergency override active").font(.callout).bold()
        Text("Auto-resumes when your iPhone state changes.")
          .font(.caption).foregroundStyle(.secondary)
        Button("End override now") { state.disengageEmergencyOverride() }
      }
    } else if !state.emergencyPINSet {
      Button("Set emergency PIN") {
        beginPINFlow(.settingPIN)
      }
    } else if state.isBlocked {
      Button("Emergency unblock") {
        beginPINFlow(.enteringPIN)
      }
    }
    // pinSet && !isBlocked → no row (nothing to do)
  }

  private var footer: some View {
    HStack {
      Text(footerText).font(.caption).foregroundStyle(.tertiary)
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
  }

  // MARK: - PIN entry view

  private func pinEntryView(
    title: String,
    prompt: String,
    buttonLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.title3.bold())
      Text(prompt).font(.caption).foregroundStyle(.secondary)

      SecureField("4-digit PIN", text: $pinInput)
        .focused($pinFocused)
        .textFieldStyle(.roundedBorder)
        .onChange(of: pinInput) { _, new in
          pinInput = String(new.filter(\.isNumber).prefix(4))
          pinError = nil
        }
        .onSubmit { if pinInput.count == 4 { action() } }

      if let err = pinError {
        Text(err).font(.caption).foregroundStyle(.red)
      }

      HStack {
        Button("Cancel") { mode = .main }
        Spacer()
        Button(buttonLabel, action: action)
          .disabled(pinInput.count != 4)
          .keyboardShortcut(.defaultAction)
      }
    }
    .onAppear { pinFocused = true }
  }

  // MARK: - Actions

  private func beginPINFlow(_ next: Mode) {
    pinInput = ""
    pinError = nil
    mode = next
  }

  private func doSetPIN() {
    do {
      try state.setEmergencyPIN(pinInput)
      mode = .main
    } catch {
      pinError = error.localizedDescription
    }
  }

  private func doUnblock() {
    if state.engageEmergencyOverride(pin: pinInput) {
      mode = .main
    } else {
      pinError = "Incorrect PIN."
      pinInput = ""
    }
  }

  // MARK: - Computed

  private var domainCountText: String {
    let n = state.domains.count
    return n == 1 ? "1 domain blocked" : "\(n) domains blocked"
  }

  private var footerText: String {
    guard let last = state.lastUpdated else { return "Never synced" }
    return "Synced \(Self.timeFmt.string(from: last))"
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
    f.timeStyle = .short
    return f
  }()
}
