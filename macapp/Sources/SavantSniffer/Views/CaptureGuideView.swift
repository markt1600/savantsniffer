import SwiftUI

struct CaptureGuideView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var iface = "en0"
    private var proc: String { store.map.processor ?? "<processor-ip>" }

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
                        Text("LIP telnet is plaintext, so the login the Savant host sends is readable. Mirror the Mac mini's switch port to this Mac (UniFi: switch → Ports → Port Mirror), or run tcpdump on the mini (read-only). The login is only sent when Savant opens its session, so capture across a reconnect. Alternatively, read it from Savant's configuration bundle on the mini.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        CommandLine(text: "sudo tcpdump -i \(iface) -s 0 -w ~/lutron.pcap 'host \(proc) and tcp port 23'")
                        CommandLine(text: "tshark -r ~/lutron.pcap -q -z follow,tcp,ascii,0")
                        Text("Read the login/password out of the reassembled stream, enter them on Monitor, and save to Keychain.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                SavantCaptureCard()
                LEAPCommandsCard()
            }
            .padding(26)
        }
    }
}
