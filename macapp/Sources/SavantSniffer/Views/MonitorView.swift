import SwiftUI

struct MonitorView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Monitor & label",
                       subtitle: "Read-only. Walk the house, press a button, then label the event that appears.") {
                ConnectionStatusPill()
            }
            ConnectionCard()
            MonitorWorkspace()
        }
        .padding(26)
    }
}

struct CapturePanel: View {
    @ObservedObject var recorder: MacroRecorder
    var live: Bool
    var onSave: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Capture a button").font(.system(size: 13, weight: .bold))
                    Spacer()
                    if recorder.active { Chip(text: "CAPTURING", bg: Theme.amberTint, fg: Theme.amberInk) }
                    else { Chip(text: "IDLE", bg: Theme.greyTint, fg: Theme.muted) }
                }
                Text("Arm, press the physical button, let the burst settle, then name it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if recorder.active {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(guessText).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(recorder.steps.count) events · \(recorder.loadsAffected) loads").font(.system(size: 11.5)).foregroundStyle(Theme.muted).monospacedDigit()
                        }
                        ForEach(recorder.effect(), id: \.id) { e in
                            HStack { Text("output \(e.id)").mono(12); Spacer(); Text("→ \(Int(e.level))%").mono(12).foregroundStyle(Theme.muted) }
                        }
                        HStack(spacing: 8) {
                            LED(color: recorder.triggerDevice != nil ? Theme.amber : Theme.grey)
                            Text(recorder.triggerDevice != nil
                                 ? "trigger: keypad \(recorder.triggerDevice!), button \(recorder.triggerButton ?? 0)"
                                 : "no keypad press seen yet").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.greyTint))
                    HStack(spacing: 8) {
                        Button("Discard") { recorder.finish() }
                        Button("Name & save…", action: onSave)
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(recorder.triggerDevice == nil && recorder.steps.isEmpty)
                    }
                } else {
                    Button("Arm capture") { recorder.begin() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(!live)
                    if !live { Text("Connect first.").font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                }
            }
        }
    }

    private var guessText: String {
        switch recorder.classify() {
        case "macro": return "Likely a macro / scene"
        case "output": return "Likely a single load"
        default: return "No Lutron output yet (integration?)"
        }
    }
}
