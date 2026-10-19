import AppKit
import SwiftUI

// MARK: - Tokens

/// Bento grid metrics. The content is 336 wide: two halves of 164 or three thirds of 106.67, 8 apart.
enum Bento {
    static let width: CGFloat = 368
    static let padding: CGFloat = 16
    static let gap: CGFloat = 8
    static let row: CGFloat = 80
    static let radius: CGFloat = 16
    static let orb: CGFloat = 36

    static let content = width - 2 * padding
    static let half = (content - gap) / 2
}

enum Palette {
    /// Ice blue (#5CB8FF), the only accent: lit fills, the slider fill, accent glyphs on dark.
    static let accent = Color(red: 0.361, green: 0.722, blue: 1.0)
    /// #7CC9FF, the light end of the accent gradients.
    static let accentHigh = Color(red: 0.486, green: 0.788, blue: 1.0)
    /// #439FF3, the dark end of the accent gradients.
    static let accentLow = Color(red: 0.263, green: 0.624, blue: 0.953)
    /// #2F7BEA: the power glyph on its white orb, the lit glow, accent glyphs on light surfaces.
    static let accentDeep = Color(red: 0.184, green: 0.482, blue: 0.918)
    /// Text on accent fills. White on ice blue is about 2:1, so text there is deep navy (#031933).
    static let ink = Color(red: 0.012, green: 0.098, blue: 0.2).opacity(0.88)
    static let inkSecondary = Color(red: 0.012, green: 0.098, blue: 0.2).opacity(0.58)
    /// Accent glyphs on neutral surfaces: ice blue on dark, deep blue on light (ice blue is 1.8:1 there).
    static let accentGlyph = Color(light: accentDeep, dark: accent)

    // Module surfaces: rest, hover, pressed. Light mode uses frosted white cards, like Control Center.
    static let module = Color(light: .white.opacity(0.62), dark: .white.opacity(0.06))
    static let moduleHover = Color(light: .white.opacity(0.85), dark: .white.opacity(0.085))
    static let modulePressed = Color(light: .black.opacity(0.07), dark: .white.opacity(0.115))
    /// An active toggle while the unit runs. Light mode is the accent at 22/28/34% over white, so it
    /// stays a clean ice blue instead of graying over the panel.
    static let tint = Color(light: Color(red: 0.859, green: 0.937, blue: 1.0), dark: accent.opacity(0.17))
    static let tintHover = Color(light: Color(red: 0.82, green: 0.922, blue: 1.0), dark: accent.opacity(0.22))
    static let tintPressed = Color(light: Color(red: 0.78, green: 0.906, blue: 1.0), dark: accent.opacity(0.27))
    /// An active toggle while the unit is off: still visible, but without color.
    static let selected = Color(light: .black.opacity(0.08), dark: .white.opacity(0.13))
    static let selectedHover = Color(light: .black.opacity(0.1), dark: .white.opacity(0.16))
    static let selectedPressed = Color(light: .black.opacity(0.13), dark: .white.opacity(0.19))
    /// Inner hairline on every module.
    static let hairline = Color(light: .black.opacity(0.06), dark: .white.opacity(0.04))
    /// Light mode lifts cards with a soft shadow; dark mode doesn't need one.
    static let moduleShadow = Color(light: .black.opacity(0.07), dark: .clear)
    /// Icon circle inside 2x1 modules.
    static let orb = Color(light: .black.opacity(0.05), dark: .white.opacity(0.09))
    /// The slider fill while the unit is off.
    static let fillOff = Color(light: .black.opacity(0.1), dark: .white.opacity(0.17))
    /// "Desligado" on the power module: dimmer than a value, brighter than a caption.
    static let dimValue = Color(light: .black.opacity(0.68), dark: .white.opacity(0.72))
    /// Header room temperature.
    static let strongMeta = Color(light: .black.opacity(0.75), dark: .white.opacity(0.78))
    /// Footer status text and dot.
    static let footer = Color(light: .black.opacity(0.45), dark: .white.opacity(0.36))
    /// Footer text that needs reading (offline message) and the settings glyph on hover.
    static let footerStrong = Color(light: .black.opacity(0.6), dark: .white.opacity(0.6))
    static let warning = Color.orange

    /// Lit power module and prominent capsules, CSS 150°: top-left to bottom-right.
    static let litGradient = LinearGradient(stops: [.init(color: accentHigh, location: 0),
                                                    .init(color: accent, location: 0.45),
                                                    .init(color: Color(red: 0.278, green: 0.639, blue: 0.961), location: 1)],
                                            startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1))
    /// Slider fill, top to bottom over the full module height.
    static let fillGradient = LinearGradient(stops: [.init(color: accentHigh, location: 0),
                                                     .init(color: accent, location: 0.42),
                                                     .init(color: accentLow, location: 1)],
                                             startPoint: .top, endPoint: .bottom)
}

extension Color {
    /// A color that follows the appearance, resolved by SwiftUI from the environment's color scheme.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

extension EnvironmentValues {
    /// True while the module around this view is hovered or pressed (set by `ModuleButtonStyle`).
    @Entry var moduleHighlighted = false
    /// False while the panel is closed (set by `PanelView`). MenuBarExtra keeps its window alive
    /// offscreen, so repeating symbol effects must check this or they keep rendering behind it.
    @Entry var panelOnScreen = true
}

// MARK: - Module surface

enum ModuleTone: Equatable {
    /// Resting surface.
    case neutral
    /// Active toggle while the unit runs.
    case tinted
    /// Active toggle while the unit is off.
    case selected
    /// Power while on: accent gradient, navy text.
    case lit
}

enum ModuleHighlight {
    case rest, hover, pressed
}

/// The rounded card behind every module.
struct ModuleBackground: View {
    var tone: ModuleTone = .neutral
    var highlight: ModuleHighlight = .rest

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Bento.radius, style: .continuous)
        if tone == .lit {
            shape.fill(Palette.litGradient)
                .brightness(highlight == .hover ? 0.04 : highlight == .pressed ? -0.04 : 0)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: Palette.accentDeep.opacity(0.28), radius: 9, y: 6)
        } else {
            shape.fill(fill)
                .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: Palette.moduleShadow, radius: 1.5, y: 0.5)
        }
    }

    private var fill: Color {
        switch (tone, highlight) {
        case (.tinted, .rest): return Palette.tint
        case (.tinted, .hover): return Palette.tintHover
        case (.tinted, .pressed): return Palette.tintPressed
        case (.selected, .rest): return Palette.selected
        case (.selected, .hover): return Palette.selectedHover
        case (.selected, .pressed): return Palette.selectedPressed
        case (_, .hover): return Palette.moduleHover
        case (_, .pressed): return Palette.modulePressed
        default: return Palette.module
        }
    }
}

/// Every module button: card background, hover and pressed feedback, and a slight press-in.
/// Drawn entirely in SwiftUI, because system button styles render as yellow placeholders in
/// ImageRenderer snapshots.
struct ModuleButtonStyle: ButtonStyle {
    var tone: ModuleTone = .neutral

    func makeBody(configuration: Configuration) -> some View {
        ModuleButton(configuration: configuration, tone: tone)
    }

    private struct ModuleButton: View {
        let configuration: Configuration
        let tone: ModuleTone
        @State private var hovering = false

        var body: some View {
            let highlight: ModuleHighlight = configuration.isPressed ? .pressed : hovering ? .hover : .rest
            configuration.label
                .environment(\.moduleHighlighted, highlight != .rest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ModuleBackground(tone: tone, highlight: highlight))
                .contentShape(RoundedRectangle(cornerRadius: Bento.radius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.965 : 1)
                .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.18), value: hovering)
                .animation(.easeInOut(duration: 0.22), value: tone)
                .onHover { inside in
                    if hovering != inside { hovering = inside }
                }
        }
    }
}

/// The 36 pt icon circle of a 2x1 module.
struct Orb<Content: View>: View {
    var fill: Color = Palette.orb
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.system(size: 17))
            .frame(width: Bento.orb, height: Bento.orb)
            .background(Circle().fill(fill))
    }
}

// MARK: - Modules

/// 2x1 module that opens a menu: orb, caption, current value and a chevron.
struct MenuModule<Icon: View>: View {
    let title: String
    let value: String
    let help: String
    /// Off: the icon goes gray.
    let isPowered: Bool
    let action: () -> Void
    @ViewBuilder var icon: Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Orb { icon }
                    .foregroundStyle(isPowered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    // "Desumidificar" is the one value wider than the 78 pt column.
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.13)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(.primary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Chevron()
            }
            .padding(.horizontal, 12)
        }
        .buttonStyle(ModuleButtonStyle())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(help)
    }

    private struct Chevron: View {
        @Environment(\.moduleHighlighted) private var highlighted

        var body: some View {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(highlighted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .padding(.leading, -4)
        }
    }
}

/// 2x1 power module, lit with the accent gradient while the unit runs.
struct PowerModule: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Orb(fill: isOn ? .white.opacity(0.96) : Palette.orb) {
                    Image(systemName: "power")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isOn ? AnyShapeStyle(Palette.accentDeep) : AnyShapeStyle(.secondary))
                }
                .shadow(color: isOn ? Palette.ink.opacity(0.2) : .clear, radius: 1.5, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ar-condicionado")
                        .font(.system(size: 11))
                        .foregroundStyle(isOn ? AnyShapeStyle(Palette.inkSecondary) : AnyShapeStyle(.secondary))
                    Text(isOn ? "Ligado" : "Desligado")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.13)
                        .foregroundStyle(isOn ? Palette.ink : Palette.dimValue)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
        }
        .buttonStyle(ModuleButtonStyle(tone: isOn ? .lit : .neutral))
        .help(isOn ? "Desligar" : "Ligar")
        .accessibilityLabel("Ar-condicionado")
        .accessibilityValue(isOn ? "Ligado" : "Desligado")
        .accessibilityAddTraits(.isToggle)
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }
}

/// 1/3-width on/off module: icon over name. Active shows the filled symbol under its outline.
struct ToggleModule: View {
    let title: String
    /// Outline symbol name; the `.fill` variant must exist.
    let symbol: String
    let isOn: Bool
    /// Off: an active toggle goes gray instead of blue.
    let isPowered: Bool
    let help: (on: String, off: String)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Image(systemName: symbol + ".fill")
                        .opacity(isOn ? (isPowered ? 0.22 : 0.16) : 0)
                    Image(systemName: symbol)
                }
                .font(.system(size: 19))
                .foregroundStyle(iconStyle)
                .frame(height: 24)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(ModuleButtonStyle(tone: isOn ? (isPowered ? .tinted : .selected) : .neutral))
        .help(isOn ? help.on : help.off)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Ligado" : "Desligado")
        .accessibilityAddTraits(.isToggle)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }

    private var iconStyle: AnyShapeStyle {
        if isOn { return isPowered ? AnyShapeStyle(Palette.accentGlyph) : AnyShapeStyle(.primary) }
        return AnyShapeStyle(.primary.opacity(0.85))
    }
}

// MARK: - Temperature slider

/// The tall temperature module: a vertical fill slider in whole degrees. Drag or click to set,
/// scroll to step. The numeral and marks are drawn twice, light over the card and navy over the
/// fill, so they stay readable wherever the fill edge is.
struct TemperatureSlider: View {
    static let range: ClosedRange<Double> = 16...30

    let value: Double
    let room: Double?
    let roomName: String
    /// Off: the fill turns gray. The slider still works.
    let isPowered: Bool
    /// False in Ventilar, where the unit ignores the setpoint.
    let isEnabled: Bool
    /// Called with a new whole-degree value, only when it differs from `value`.
    let onChange: (Double) -> Void
    /// Called with +1 or -1 (scroll wheel, VoiceOver).
    let onStep: (Double) -> Void

    @State private var hovering = false
    @GestureState private var dragging = false
    @State private var wheel = ScrollWheelMonitor()

    /// One slot per degree, plus one below the minimum so 16° still shows some fill.
    fileprivate static let slots = range.upperBound - range.lowerBound + 1
    fileprivate static let base = range.lowerBound - 1

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let fillHeight = height * Self.fraction(value)

            ZStack(alignment: .bottom) {
                ModuleBackground(highlight: dragging ? .pressed : hovering ? .hover : .rest)
                Layer(model: model, height: height, onFill: false)
                fill(height: height)
                    .frame(height: fillHeight)
                Layer(model: model, height: height, onFill: isPowered)
                    .mask(alignment: .bottom) { Rectangle().frame(height: fillHeight) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Bento.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Bento.radius, style: .continuous))
            .animation(.snappy(duration: dragging ? 0.12 : 0.2), value: value)
            .animation(.easeInOut(duration: 0.22), value: isPowered)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, active, _ in active = true }
                    .onChanged { drag in
                        let target = Self.value(atY: drag.location.y, height: height)
                        if target != value { onChange(target) }
                    }
            )
        }
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
        .onHover { inside in
            if hovering != inside { hovering = inside }
            if inside, isEnabled { wheel.start(onStep) } else { wheel.stop() }
        }
        // A poll can switch to Ventilar while the pointer is here.
        .onChange(of: isEnabled) { _, enabled in if !enabled { wheel.stop() } }
        .onDisappear { wheel.stop() }
        .help(isEnabled ? "Arraste para ajustar a temperatura" : "Sem ajuste ao ventilar")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperatura")
        .accessibilityValue(isEnabled ? "\(Format.number(value)) graus" : "Sem ajuste ao ventilar")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }

    /// The room marker stays on the tick marks (16° to 29°), inside the module, even when the room is
    /// hotter or colder than the range. It's hidden in Ventilar, where the setpoint doesn't apply and
    /// the longer caption needs the room.
    private var model: Layer.Model {
        let marker = isEnabled ? room : nil
        return Layer.Model(value: value, caption: isEnabled ? "Temperatura" : "Sem ajuste ao ventilar",
                           roomText: marker.map { "\(roomName) \(Format.degrees($0))" },
                           roomFraction: marker.map { min(max(Self.fraction($0), 1 / Self.slots), 14 / Self.slots) })
    }

    /// Gray base with the accent gradient on top; the gradient spans the whole module, so its color
    /// at the edge depends on the level.
    private func fill(height: CGFloat) -> some View {
        Rectangle()
            .fill(Palette.fillOff)
            .overlay(alignment: .bottom) {
                Palette.fillGradient
                    .frame(height: height)
                    .opacity(isPowered ? 1 : 0)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.white.opacity(isPowered ? 0.55 : 0.35))
                    .frame(height: 1)
            }
            .clipped()
    }

    static func fraction(_ degrees: Double) -> CGFloat {
        CGFloat(min(max((degrees - base) / slots, 0), 1))
    }

    static func value(atY y: CGFloat, height: CGFloat) -> Double {
        let level = 1 - Double(y / max(height, 1))
        return min(max((level * slots).rounded() + base, range.lowerBound), range.upperBound)
    }

    /// One copy of the module's content: caption, numeral, tick marks and the room marker.
    private struct Layer: View {
        struct Model {
            let value: Double
            let caption: String
            let roomText: String?
            let roomFraction: CGFloat?
        }

        let model: Model
        let height: CGFloat
        /// The navy copy drawn over the accent fill.
        let onFill: Bool

        var body: some View {
            let primary = onFill ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.primary)
            let secondary = onFill ? AnyShapeStyle(Palette.inkSecondary) : AnyShapeStyle(.secondary)
            let roomSlot = model.roomFraction.map { Int(($0 * TemperatureSlider.slots).rounded()) }

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                    Spacer(minLength: 0)
                    HStack(alignment: .top, spacing: 1) {
                        Text(Format.number(model.value))
                            .font(.system(size: 50, weight: .semibold, design: .rounded))
                            .tracking(-1.2)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: model.value))
                        Text("°")
                            .font(.system(size: 28, weight: .medium, design: .rounded))
                            .opacity(0.55)
                            .padding(.top, 3)
                    }
                    .foregroundStyle(primary)
                }
                .padding(.top, 13)
                .padding(.leading, 14)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                TickMarks(major: false, skip: roomSlot)
                    .fill(primary).opacity(0.16)
                TickMarks(major: true, skip: roomSlot)
                    .fill(primary).opacity(0.26)

                if let text = model.roomText, let fraction = model.roomFraction {
                    HStack(spacing: 5) {
                        Text(text)
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(secondary)
                        Capsule()
                            .fill(primary)
                            .opacity(0.85)
                            .frame(width: 12, height: 2)
                    }
                    .fixedSize()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .offset(y: height * (0.5 - fraction))
                }
            }
        }
    }

    /// Short marks at the trailing edge, one per degree boundary; 20° and 25° are longer.
    private struct TickMarks: Shape {
        let major: Bool
        let skip: Int?

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let slots = Int(TemperatureSlider.slots)
            for slot in 1..<slots where slot != skip {
                let isMajor = (Int(TemperatureSlider.base) + slot) % 5 == 0
                guard isMajor == major else { continue }
                let width: CGFloat = major ? 8 : 5
                let y = rect.maxY - rect.height * CGFloat(slot) / CGFloat(slots)
                path.addRoundedRect(in: CGRect(x: rect.maxX - 12 - width, y: y - 0.5, width: width, height: 1),
                                    cornerSize: CGSize(width: 0.5, height: 0.5))
            }
            return path
        }
    }
}

/// Reports whether the window hosting it is on screen, from the window's occlusion state.
struct OnScreenReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            // viewDidMoveToWindow can run inside a SwiftUI update, where state must not change.
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}

/// Turns scroll wheel and trackpad scrolls over the slider into ±1 steps. Installed only while the
/// pointer is over the slider, so it never sees other scrolls.
@MainActor
final class ScrollWheelMonitor {
    /// Trackpad points per degree.
    private static let threshold: CGFloat = 24

    private var token: Any?
    private var pending: CGFloat = 0

    func start(_ onStep: @escaping (Double) -> Void) {
        guard token == nil else { return }
        // Local monitors run on the main thread.
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, onStep)
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        pending = 0
    }

    private func handle(_ event: NSEvent, _ onStep: (Double) -> Void) -> NSEvent? {
        // Momentum after a flick would overshoot; horizontal swipes aren't for this control.
        guard event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return nil }
        // Positive means "up", whichever way natural scrolling is set.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            onStep(delta > 0 ? 1 : -1)
            return nil
        }
        pending += delta
        while abs(pending) >= Self.threshold {
            onStep(pending > 0 ? 1 : -1)
            pending -= pending > 0 ? Self.threshold : -Self.threshold
        }
        if event.phase == .ended || event.phase == .cancelled { pending = 0 }
        return nil
    }
}

// MARK: - Buttons

/// Text capsule for recovery actions: accent with navy text, or a quiet neutral one.
struct CapsuleButton: View {
    let title: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(CapsuleStyle(prominent: prominent))
    }

    private struct CapsuleStyle: ButtonStyle {
        let prominent: Bool

        func makeBody(configuration: Configuration) -> some View {
            CapsuleLabel(configuration: configuration, prominent: prominent)
        }

        struct CapsuleLabel: View {
            let configuration: Configuration
            let prominent: Bool
            @State private var hovering = false

            var body: some View {
                let highlight: ModuleHighlight = configuration.isPressed ? .pressed : hovering ? .hover : .rest
                configuration.label
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(prominent ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background {
                        if prominent {
                            Capsule().fill(Palette.litGradient)
                                .brightness(highlight == .hover ? 0.04 : highlight == .pressed ? -0.04 : 0)
                        } else {
                            Capsule().fill(highlight == .rest ? Palette.selected : highlight == .hover
                                           ? Palette.selectedHover : Palette.selectedPressed)
                        }
                    }
                    .contentShape(Capsule())
                    .scaleEffect(configuration.isPressed ? 0.97 : 1)
                    .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
                    .animation(.easeOut(duration: 0.18), value: hovering)
                    .onHover { inside in
                        if hovering != inside { hovering = inside }
                    }
            }
        }
    }
}

/// Small borderless glyph button (the footer's settings), with a circle that appears on hover.
struct GlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlyphLabel(configuration: configuration)
    }

    private struct GlyphLabel: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering || configuration.isPressed ? Palette.footerStrong : Palette.footer)
                .frame(width: 26, height: 26)
                .background(Circle().fill(configuration.isPressed ? Palette.modulePressed
                                          : hovering ? Palette.orb : .clear))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.16), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { inside in
                    if hovering != inside { hovering = inside }
                }
        }
    }
}

// MARK: - Menus

/// Native popup menu at the mouse location. SwiftUI's Menu can't take a fully custom label in
/// a menu bar window, so the modules are plain buttons that open this.
@MainActor
enum PopupMenu {
    enum Entry {
        case item(String, symbol: String? = nil, checked: Bool = false, action: () -> Void)
        case separator
    }

    /// With `selectionUnderPointer`, the checked item opens under the pointer, like a pop-up button.
    static func show(_ entries: [Entry], selectionUnderPointer: Bool = false) {
        let menu = NSMenu()
        let target = Target()
        var selected: NSMenuItem?
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let symbol, let checked, let action):
                let item = NSMenuItem(title: title, action: #selector(Target.fire(_:)), keyEquivalent: "")
                item.target = target
                item.state = checked ? .on : .off
                item.tag = target.actions.count
                if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                target.actions.append(action)
                menu.addItem(item)
                if checked, selected == nil { selected = item }
            }
        }
        // popUp blocks until the menu closes, keeping `target` alive for the duration.
        menu.popUp(positioning: selectionUnderPointer ? selected : nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
    }

    private final class Target: NSObject {
        var actions: [() -> Void] = []
        @objc func fire(_ sender: NSMenuItem) { actions[sender.tag]() }
    }
}
