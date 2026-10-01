import SwiftUI

/// A thin horizontal dashed rule (used to separate projects in the sidebar).
struct DashedLine: View {
    var body: some View {
        DashShape()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundColor(Theme.stroke)
            .frame(height: 1)
    }
}

private struct DashShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Inline-editable text. Double-click to edit, or drive `editing` externally (e.g. from a
/// menu / pencil button). Commits on Return, cancels on Esc.
struct EditableText: View {
    let text: String
    var font: Font = .system(size: 14, weight: .semibold)
    var color: Color = Theme.text
    var placeholder: String = "name"
    let onCommit: (String) -> Void
    @Binding var editing: Bool

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundColor(color)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
            } else {
                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { editing = true }
            }
        }
        .onChange(of: editing) { _, isEditing in
            if isEditing {
                draft = text
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onCommit(t) }
    }
}

/// A ring that grows out of a dot and fades, over and over: a working card's status dot, the
/// session tree's current leaf. Played by Core Animation, not SwiftUI.
///
/// Both were SwiftUI `repeatForever` animations, and SwiftUI plays those from the app's main thread
/// a frame at a time, laying out the board's hosting view and committing its layers for every one.
/// A 10 s sample of the running app with two cards working had the main thread busy half the time,
/// most of it in exactly that. A CAAnimation is played by the render server; the app does nothing
/// per frame.
struct PulseRing: NSViewRepresentable {
    var color: Color
    /// Kept apart from `color` because that is usually dynamic (dark and light differ), and the
    /// alpha has to go on after it has been resolved for an appearance.
    var alpha: CGFloat
    /// nil fills the disc; a width draws only its outline, centred on the circle the way a SwiftUI
    /// stroke is.
    var lineWidth: CGFloat? = nil
    var scale: ClosedRange<CGFloat>
    /// At the start of each pulse; it fades to nothing.
    var opacity: Float
    var duration: CFTimeInterval

    func makeNSView(context: Context) -> PulseRingView { PulseRingView() }
    func updateNSView(_ view: PulseRingView, context: Context) { view.show(self) }
}

final class PulseRingView: NSView {
    private let ring = CALayer()
    private var spec: PulseRing?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // What shows if the animation is ever not running: nothing, rather than a still halo.
        ring.opacity = 0
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    /// Called on every update of the view around it, which for a card is every re-render of the
    /// board — so only what changed is touched. Restarting the animation would visibly restart the
    /// pulse, and a dynamic colour compares unequal to itself, so the colour is compared resolved.
    func show(_ new: PulseRing) {
        let old = spec
        spec = new
        if old?.lineWidth != new.lineWidth { place() }
        paint()
        if old?.scale != new.scale || old?.opacity != new.opacity || old?.duration != new.duration {
            restart()
        }
    }

    // Clicks belong to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    private func place() {
        // A border is drawn inside the layer's bounds; grow them by half the width so the line is
        // centred on the circle instead.
        let r = bounds.insetBy(dx: -(spec?.lineWidth ?? 0) / 2, dy: -(spec?.lineWidth ?? 0) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = r
        ring.cornerRadius = min(r.width, r.height) / 2
        CATransaction.commit()
    }

    private func paint() {
        guard let spec else { return }
        var c: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            c = NSColor(spec.color).withAlphaComponent(spec.alpha).cgColor
        }
        let fill = spec.lineWidth == nil ? c : nil
        let line = spec.lineWidth == nil ? nil : c
        guard ring.backgroundColor != fill || ring.borderColor != line
                || ring.borderWidth != (spec.lineWidth ?? 0) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.backgroundColor = fill
        ring.borderColor = line
        ring.borderWidth = spec.lineWidth ?? 0
        CATransaction.commit()
    }

    private func restart() {
        ring.removeAnimation(forKey: "pulse")
        guard window != nil, let spec else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = spec.scale.lowerBound
        grow.toValue = spec.scale.upperBound
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = spec.opacity
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = spec.duration
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.repeatCount = .infinity
        ring.add(pulse, forKey: "pulse")
    }
}
