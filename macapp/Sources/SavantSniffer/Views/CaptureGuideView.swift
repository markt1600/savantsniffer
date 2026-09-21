import SwiftUI
import AppKit

struct CaptureGuideView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var iface = "en0"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Credentials & LEAP").font(.largeTitle.bold())

                GroupBox("Do you need Savant's credentials?") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No. To control the lights you need the Lutron integration login (LIP user/password) or a LEAP pairing — not Savant's own login. This app talks to the Lutron processor directly and bypasses Savant.")
                        Text("For music / AV integration buttons, you also don't need Savant's password. You capture the plain-TCP command Savant sends to each device and replay it as a Savant step in a custom scene.")
                            .foregroundStyle(.secondary)
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("If the default LIP login fails — recover it from your own traffic") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LIP telnet is plaintext, so the login the Savant host sends to the processor is readable in a capture of your own network. Mirror the Mac mini's switch port to your laptop (UniFi: switch → Ports → Port Mirror), or run tcpdump on the mini itself (read-only).")
                            .foregroundStyle(.secondary).font(.callout)
                        HStack { Text("interface"); TextField("en0", text: $iface).frame(width: 80) }
                        cmd(tcpdumpCmd)
                        cmd(tsharkCmd)
                        Text("Then read the login/password out of the reassembled telnet stream and enter them on the Monitor tab.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("LEAP systems (QSX / RadioRA 3 / Caseta)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LEAP is TLS, so credentials can't be sniffed — you pair instead. Use the bundled Python tool, which handles the certificate pairing and dumps the full device tree:")
                            .foregroundStyle(.secondary).font(.callout)
                        cmd("pip install pylutron-caseta")
                        cmd("python3 -m savantsniffer.leap pair \(store.map.processor ?? "<processor-ip>")")
                        cmd("python3 -m savantsniffer.leap dump \(store.map.processor ?? "<processor-ip>")")
                        Text("Press the pairing button on the bridge/processor when prompted. Native LEAP support in the app is a planned follow-up.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Later: capture Savant → AV / music traffic") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Same idea, filtered to the Savant host so cameras and streaming never enter the capture:")
                            .foregroundStyle(.secondary).font(.callout)
                        cmd("sudo tcpdump -i \(iface) -s 0 -w ~/savant.pcap 'host \(store.map.savantHost ?? "<savant-ip>")'")
                        Text("Use the Savant app, watch which device IP receives commands when you press Music, then paste that command into a Savant step in a custom scene.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tcpdumpCmd: String {
        "sudo tcpdump -i \(iface) -s 0 -w ~/lutron.pcap 'host \(store.map.processor ?? "<processor-ip>") and tcp port 23'"
    }
    private var tsharkCmd: String {
        "tshark -r ~/lutron.pcap -q -z follow,tcp,ascii,0"
    }

    private func cmd(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(6).background(Color.black.opacity(0.06)).cornerRadius(5)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
            Spacer()
        }
    }
}
