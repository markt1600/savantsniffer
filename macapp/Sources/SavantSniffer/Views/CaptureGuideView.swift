import SwiftUI
import AppKit

struct CaptureGuideView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var iface = "en0"

    private var proc: String { store.map.processor ?? "<processor-ip>" }
    private var savant: String { store.map.savantHost ?? "<savant-ip>" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Credentials & LEAP",
                           subtitle: "What you need, and how to get it from your own network when the defaults don't work.") {
                    HStack(spacing: 6) {
                        Text("interface").font(.caption).foregroundStyle(Theme.muted)
                        TextField("en0", text: $iface).textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Do you need Savant's credentials?").font(.system(size: 13, weight: .bold))
                        Text("No. To control the lights you need the Lutron integration login (LIP user/password) or a LEAP pairing, not Savant's own login. This app talks to the Lutron processor directly.")
                            .font(.system(size: 13))
                        Text("For music, AV and audio-zone buttons you also don't need Savant's password: you capture the commands the Savant host sends to each device and replay them as Savant steps in a custom scene.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If the default LIP login fails: recover it from your own traffic").font(.system(size: 13, weight: .bold))
                        Text("LIP telnet is plaintext, so the login the Savant host sends is readable. Mirror the Mac mini's switch port to this Mac (UniFi: switch → Ports → Port Mirror), or run tcpdump on the mini (read-only). The filter keeps everything else out.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        cmd("sudo tcpdump -i \(iface) -s 0 -w ~/lutron.pcap 'host \(proc) and tcp port 23'")
                        cmd("tshark -r ~/lutron.pcap -q -z follow,tcp,ascii,0")
                        Text("Read the login/password out of the reassembled stream, then enter them on the Monitor screen and save to Keychain.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Savant capture: audio zones, music, AV").font(.system(size: 13, weight: .bold))
                        Text("Lutron only reports the keypad press. Savant hears that same press and sends its own commands to the audio hardware. Capture the Savant host's traffic while you press those buttons, then correlate by time.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Text("1. Capture, filtered to the Savant host (cameras and streaming never enter it):").font(.system(size: 12.5))
                        cmd("sudo tcpdump -i \(iface) -s 0 -w ~/savant.pcap 'host \(savant)'")
                        Text("2. Keep the Monitor screen running and press the buttons (Music, Broadcast, office lights). The monitor log timestamps every press.").font(.system(size: 12.5))
                        Text("3. Export the packets as text and correlate with the Python tool:").font(.system(size: 12.5))
                        cmd("tshark -r ~/savant.pcap -Y 'ip.src==\(savant)' -T fields -E separator=/t -e frame.time_epoch -e ip.dst -e tcp.dstport -e udp.dstport -e tcp.payload -e udp.payload > ~/savant.txt")
                        cmd("lutron correlate --savant ~/savant.txt --monitor-log <latest monitor log>")
                        Text("It lists, per press, which device IP and port Savant talked to and the command bytes. Note the zones that came on, then save them on the button (Monitor → capture → Savant side fields). Plain-TCP commands can be replayed as Savant steps; encrypted or session-bound protocols can be identified but not replayed.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LEAP systems (QSX / RadioRA 3 / Caseta)").font(.system(size: 13, weight: .bold))
                        Text("LEAP is TLS, so credentials can't be read from traffic; you pair instead, using the bundled Python tool.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        cmd("pip install pylutron-caseta")
                        cmd("python3 -m savantsniffer.leap pair \(proc)")
                        cmd("python3 -m savantsniffer.leap dump \(proc)")
                        Text("Press the pairing button on the bridge/processor when prompted.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(26)
        }
    }

    private func cmd(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).mono(12).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink)).foregroundStyle(.white)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .controlSize(.small)
            .accessibilityLabel("Copy command")
        }
    }
}
