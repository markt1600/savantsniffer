import SwiftUI

enum Theme {
    static let ground     = Color(red: 0.953, green: 0.949, blue: 0.933)
    static let sidebar    = Color(red: 0.922, green: 0.914, blue: 0.890)
    static let panel      = Color.white
    static let border     = Color(red: 0.894, green: 0.886, blue: 0.863)
    static let ink        = Color(red: 0.106, green: 0.106, blue: 0.122)
    static let muted      = Color(red: 0.420, green: 0.420, blue: 0.447)
    static let faint      = Color(red: 0.541, green: 0.541, blue: 0.565)
    static let accent     = Color(red: 0.059, green: 0.463, blue: 0.431)
    static let accentTint = Color(red: 0.902, green: 0.957, blue: 0.945)
    static let green      = Color(red: 0.133, green: 0.627, blue: 0.420)
    static let greenTint  = Color(red: 0.941, green: 0.980, blue: 0.961)
    static let greenInk   = Color(red: 0.086, green: 0.416, blue: 0.278)
    static let amber      = Color(red: 0.851, green: 0.604, blue: 0.0)
    static let amberTint  = Color(red: 0.992, green: 0.969, blue: 0.906)
    static let amberInk   = Color(red: 0.478, green: 0.337, blue: 0.0)
    static let grey       = Color(red: 0.776, green: 0.769, blue: 0.745)
    static let greyTint   = Color(red: 0.961, green: 0.957, blue: 0.945)
    static let blue       = Color(red: 0.114, green: 0.306, blue: 0.847)
    static let blueTint   = Color(red: 0.890, green: 0.925, blue: 1.0)
    static let purple     = Color(red: 0.427, green: 0.157, blue: 0.851)
    static let purpleTint = Color(red: 0.953, green: 0.910, blue: 1.0)
    static let red        = Color(red: 0.80, green: 0.20, blue: 0.20)
}

/// White rounded panel with a hairline border.
struct Card<Content: View>: View {
    var padding: CGFloat
    let content: Content
    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }
}

struct LED: View {
    var color: Color
    var glow = false
    var size: CGFloat = 10
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
            .background(glow ? Circle().fill(color.opacity(0.18)).frame(width: size + 6, height: size + 6) : nil)
    }
}

struct StatusDot: View {
    let status: DeviceMap.CaptureStatus
    var size: CGFloat = 11
    var body: some View { LED(color: StatusDot.color(status), size: size) }
    static func color(_ s: DeviceMap.CaptureStatus) -> Color {
        switch s {
        case .captured: return Theme.green
        case .identified: return Theme.amber
        case .pending: return Theme.grey
        }
    }
}

struct BoolDot: View {
    let ok: Bool
    var body: some View { LED(color: ok ? Theme.green : Theme.grey) }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.faint)
    }
}

struct Chip: View {
    var text: String
    var bg: Color
    var fg: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.3)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
    }
    static func kind(_ k: String) -> Chip {
        switch k {
        case "DEVICE", "press": return Chip(text: k.uppercased(), bg: Theme.blueTint, fg: Theme.blue)
        case "OUTPUT", "output": return Chip(text: k.uppercased(), bg: Theme.greenTint, fg: Theme.greenInk)
        case "savant", "integration": return Chip(text: k.uppercased(), bg: Theme.purpleTint, fg: Theme.purple)
        case "macro": return Chip(text: k.uppercased(), bg: Theme.amberTint, fg: Theme.amberInk)
        default: return Chip(text: k.uppercased(), bg: Theme.greyTint, fg: Theme.muted)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    let trailing: Trailing
    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(spacing: 8) { trailing }
        }
    }
}

extension View {
    func mono(_ size: CGFloat = 12) -> some View { font(.system(size: size, design: .monospaced)) }
}
