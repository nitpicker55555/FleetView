import SwiftUI

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
                NameText(name: text, font: font, color: color)
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

/// A card's name on one line, its distinguishing tail — the `(2)` a taken name was given, or the time
/// an older duplicate got — kept whole while the rest gives way. Cut at the end, two cards called
/// `code_sense review (2)` and `code_sense review (3)` read the same.
struct NameText: View {
    let name: String
    var font: Font = .fvBody
    /// nil leaves the colour to the caller's own `foregroundColor`, which an inner one would override.
    var color: Color? = nil

    var body: some View {
        let (base, suffix) = TerminalNames.split(name)
        let line = HStack(spacing: 0) {
            Text(base).lineLimit(1).truncationMode(.tail)
            if let suffix { Text(suffix).lineLimit(1).fixedSize() }
        }
        .font(font)
        if let color { line.foregroundColor(color) } else { line }
    }
}

/// A terminal's status as a shape. Still, always: nothing on screen moves unless you moved it.
///
/// Every state has its own shape, so they read without colour and without a word — the word is in
/// the tooltip. Running is a scalloped "soft burst" (Material 3's shape for an active indicator),
/// deliberately not a ring with an arc, which reads as progress, and not a dashed ring, which reads
/// as loading. Needs-you is the only angular mark on the board.
///
/// `onColor` paints the live states in a container's foreground instead of their own colour, for a
/// glyph that sits on a running or needs-you card.
struct StatusGlyph: View {
    let status: TermStatus
    var size: CGFloat = 16
    var onColor: Color? = nil

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .help(status.label)
            .accessibilityLabel(Text(status.label))
    }

    @ViewBuilder private var glyph: some View {
        let s = size
        switch status {
        case .working:
            SoftBurst().fill(onColor ?? Theme.primary)
                .frame(width: s * 0.92, height: s * 0.92)
        case .needsYou:
            // The "!" is a hole in the path (even-odd fill), not a second shape blended out of the
            // first: a blend needs an offscreen pass that not every renderer gives it.
            AlertDiamond().fill(onColor ?? Theme.warn, style: FillStyle(eoFill: true))
                .frame(width: s * 0.9, height: s * 0.9)
        case .idle:
            Circle().fill(Theme.outline).frame(width: s * 0.5, height: s * 0.5)
        case .shell:
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.17)
                    .stroke(Theme.outline, lineWidth: 1.4)
                    .frame(width: s * 0.75, height: s * 0.68)
                PromptMark().stroke(Theme.outline, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: s * 0.75, height: s * 0.68)
            }
        case .exited:
            ZStack {
                Circle().stroke(lineWidth: 1.5).frame(width: s * 0.7, height: s * 0.7)
                Cross().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: s * 0.24, height: s * 0.24)
            }
            .foregroundColor(Theme.onSurface.opacity(Theme.endedOpacity))
        case .closed:
            Circle().stroke(Theme.onSurface.opacity(Theme.endedOpacity), lineWidth: 1.5)
                .frame(width: s * 0.7, height: s * 0.7)
        }
    }
}

/// A run that has just finished: a disc with a check through it. The check is drawn in the colour
/// under the glyph rather than cut out, so it reads as a hole without needing an even-odd outline
/// of a stroked path.
struct FinishedGlyph: View {
    let color: Color
    let cutout: Color
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: size * 0.88, height: size * 0.88)
            CheckMark().stroke(cutout, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.44, height: size * 0.34)
        }
        .frame(width: size, height: size)
        .help(L(.cardJustFinished))
        .accessibilityLabel(Text(L(.cardJustFinished)))
    }
}

struct CheckMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// Nine soft scallops around a disc.
struct SoftBurst: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        var p = Path()
        let n = 96
        for i in 0...n {
            let t = Double(i) / Double(n) * 2 * .pi
            let r = R * (0.87 + 0.13 * cos(9 * t))
            let pt = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// A diamond with an exclamation mark cut through it.
struct AlertDiamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Diamond().path(in: r)
        let w = r.width, h = r.height
        p.addRoundedRect(in: CGRect(x: r.midX - w * 0.065, y: r.minY + h * 0.24,
                                    width: w * 0.13, height: h * 0.32),
                         cornerSize: CGSize(width: w * 0.065, height: w * 0.065))
        p.addEllipse(in: CGRect(x: r.midX - w * 0.075, y: r.minY + h * 0.63,
                                width: w * 0.15, height: w * 0.15))
        return p
    }
}

struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }
}

/// "›_" inside the shell glyph's frame.
private struct PromptMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.33))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.46, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.67))
        p.move(to: CGPoint(x: r.minX + r.width * 0.54, y: r.minY + r.height * 0.7))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.7))
        return p
    }
}

private struct Cross: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}
