import SwiftUI

struct PortCheckView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Port check",
                           subtitle: "Opens a TCP connection to 23 / 8081 / 8083 to see which answers. Sends nothing beyond the handshake.") {
                    EmptyView()
                }
                PortCheckCard()
            }
            .padding(26)
        }
    }
}
