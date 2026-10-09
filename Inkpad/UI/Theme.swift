import SwiftUI

/// The desktop app's look: its colours (Adwaita's, plus the blue of the editor header)
/// and the handful of controls its stylesheet defines.
enum Theme {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    static func dyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }

    static let header = Color(rgb(0x37629f))        // the editor's header bar
    static let headerInk = Color(rgb(0x2b5290))     // icons on its white, checked buttons
    static let accentUI = rgb(0x3584e4)
    static let accent = Color(accentUI)
    static let accentText = Color(dyn(0x0461be, 0x81d0ff))
    static let dangerUI = dyn(0xc30000, 0xff938c)
    static let danger = Color(dangerUI)
    static let starOn = Color(rgb(0xe8563f))
    static let mark = Color(rgb(0xe5484d))
    /// Text and icon colour that stays solid inside popovers (system "primary" turns
    /// translucent on their material).
    static let ink = Color(UIColor.label)
    static let viewBg = Color(dyn(0xffffff, 0x1d1d20))
    static let windowBg = Color(dyn(0xfafafb, 0x222226))
    static let sidebarBg = Color(dyn(0xebebed, 0x2e2e32))
    static let popoverUI = dyn(0xffffff, 0x36363a)
    static let popoverBg = Color(popoverUI)
    static let cardBg = Color(dyn(0xffffff, 0x3f3f44))
    static let canvasUI = dyn(0xe1e1e2, 0x1f1f22)   // shade(window_bg, 0.9)
}

// MARK: floating bars

/// The rounded bar that floats over the canvas (.pill).
struct Pill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Theme.popoverBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.black.opacity(0.05), lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 6)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }
}

/// A button's look inside a pill: 36 points square, tinted when checked.
struct PillButtonStyle: ButtonStyle {
    var checked = false
    var tint: Color?        // .drop: the accent-tinted dropdown
    var round = false       // .swatch
    var wide = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, wide ? 8 : 0)
            .frame(minWidth: round ? 34 : 36, minHeight: round ? 34 : 36)
            .background((tint ?? Color.primary).opacity(tint != nil ? (configuration.isPressed ? 0.26 : 0.16) : checked ? 0.12 : configuration.isPressed ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: round ? 17 : 12, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

struct PillSeparator: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 7)
    }
}

/// The little page-and-zoom label in the canvas corner (.status).
struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Theme.popoverBg, in: Capsule())
            .overlay(Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
    }
}

// MARK: popovers

/// A button that opens a popover; the content gets a closure that closes it.
struct PopButton<Label: View, Content: View>: View {
    var edge: Edge = .top
    @ViewBuilder var content: (_ close: @escaping () -> Void) -> Content
    @ViewBuilder var label: () -> Label
    @State private var open = false
    @State private var middle: CGFloat = 0   // where the button is, down the screen

    /// Low on the screen there is no room underneath: the popover opens upwards instead.
    private var side: Edge {
        edge == .top && middle > UIScreen.main.bounds.height * 0.6 ? .bottom : edge
    }

    var body: some View {
        Button { open = true } label: { label() }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { middle = $0 }
            .popover(isPresented: $open, arrowEdge: side) {
                // Opaque, like the desktop's popovers: nothing of the page shows through.
                // Where there is not room for all of it, it scrolls.
                ViewThatFits(in: .vertical) {
                    content { open = false }
                    ScrollView { content { open = false } }
                }
                .foregroundStyle(Theme.ink)
                .presentationBackground(Theme.popoverBg)
                .presentationCompactAdaptation(.popover)
            }
    }
}

struct MenuItem: Identifiable {
    let id = UUID()
    var label = ""
    var icon: String?
    var danger = false
    var separator = false
    var action: () -> Void = {}

    init(_ label: String, _ icon: String? = nil, danger: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.danger = danger
        self.action = action
    }

    private init() { separator = true }
    static var line: MenuItem { MenuItem() }
}

/// Rows of a menu popover (popover.menu with .menu-row buttons).
struct MenuList: View {
    let items: [MenuItem]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.separator {
                    Divider().padding(.horizontal, 6).padding(.vertical, 5)
                } else {
                    Button {
                        close()
                        item.action()
                    } label: {
                        HStack(spacing: 12) {
                            if let icon = item.icon { Icon(icon) }
                            Text(item.label)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(item.danger ? Theme.danger : Theme.ink)
                    }
                    .buttonStyle(RowStyle())
                }
            }
        }
        .padding(6)
        .frame(minWidth: 200)
    }
}

/// .menu-row: a flat row that lights up while pressed.
struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// A popover's body with its heading (the desktop's _panel).
struct Panel<Content: View>: View {
    let title: String
    var width: CGFloat? = 300
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { Text(title).font(.system(size: 18, weight: .bold)) }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: width.map { $0 + 28 })
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Big side-by-side radio buttons with an icon above a label (.choice).
struct ChoiceRow<Value: Hashable, IconView: View>: View {
    let entries: [(Value, String)]
    @Binding var value: Value
    @ViewBuilder var icon: (Value) -> IconView

    var body: some View {
        HStack(spacing: 6) {
            ForEach(entries, id: \.0) { entry in
                let on = entry.0 == value
                Button { value = entry.0 } label: {
                    VStack(spacing: 4) {
                        icon(entry.0)
                        Text(entry.1).font(.subheadline)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(on ? Theme.cardBg : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(on ? 0.07 : 0), lineWidth: 1))
                    .shadow(color: .black.opacity(on ? 0.10 : 0), radius: 3, y: 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SwitchRow: View {
    let text: String
    var icon: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                if let icon { Icon(icon) }
                Text(text)
            }
        }
        .tint(Theme.accent)
    }
}

/// A 0–100 slider with its name and value above it.
struct ScaleRow: View {
    let text: String
    @Binding var value: Double
    var format: (Double) -> String = { "\(Int($0))%" }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(text).font(.caption)
                Spacer()
                Text(format(value)).font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...100, step: 1).tint(Theme.accent)
        }
    }
}

/// Buttons joined into one control (.linked).
struct Linked<Value: Hashable>: View {
    let entries: [(Value, String)]
    @Binding var value: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                let on = entry.0 == value
                Button { value = entry.0 } label: {
                    Text(entry.1)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Color.primary.opacity(on ? 0.2 : 0.08))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < entries.count - 1 { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 34) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// .pill-btn: the rounded action buttons of the library.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case plain, suggested, destructive }
    var kind = Kind.plain

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .foregroundStyle(kind == .plain ? Color.primary : .white)
            .background(kind == .suggested ? Theme.accent : kind == .destructive ? Color(Theme.rgb(0xe01b24)) : Color.primary.opacity(0.1), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// .thumb: a small sheet of paper, with the accent ring when chosen.
struct ThumbFrame: ViewModifier {
    var selected = false
    var radius: CGFloat = 2

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.black.opacity(selected ? 0 : 0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
            .overlay(RoundedRectangle(cornerRadius: radius + 2).strokeBorder(Theme.accent, lineWidth: 2).padding(-2).opacity(selected ? 1 : 0))
            .shadow(color: Theme.accent.opacity(selected ? 0.3 : 0), radius: 4, y: 2)
    }
}

extension View {
    func thumb(selected: Bool = false, radius: CGFloat = 2) -> some View { modifier(ThumbFrame(selected: selected, radius: radius)) }
}
