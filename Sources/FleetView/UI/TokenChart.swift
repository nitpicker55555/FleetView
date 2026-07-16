import SwiftUI
import Charts

/// A compact "new tokens over time" line/area chart for one project. The x-axis always includes the
/// latest sample's time (rightmost tick), and a caption spells out when the data last updated.
struct ProjectTokenChart: View {
    let samples: [TokenSample]

    private var firstDate: Date? { samples.first?.t }
    private var lastDate: Date? { samples.last?.t }

    // Force ticks at the start, middle, and — crucially — the latest sample.
    private var xTicks: [Date] {
        guard let f = firstDate, let l = lastDate, f < l else { return samples.map { $0.t } }
        return [f, f.addingTimeInterval(l.timeIntervalSince(f) / 2), l]
    }

    private static let updatedFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let l = lastDate {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 8))
                    Text("updated \(Self.updatedFmt.string(from: l))").font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(Theme.subtext.opacity(0.85))
            }
            chart
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
        .background(Theme.card.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
    }

    private var chart: some View {
        Chart(Array(samples.enumerated()), id: \.offset) { _, s in
            AreaMark(x: .value("Time", s.t), y: .value("New tokens", s.newTokens))
                .interpolationMethod(.monotone)
                .foregroundStyle(.linearGradient(colors: [Theme.accent.opacity(0.30), Theme.accent.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", s.t), y: .value("New tokens", s.newTokens))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .foregroundStyle(Theme.accent)
        }
        .chartXAxis {
            AxisMarks(values: xTicks) { _ in
                AxisGridLine().foregroundStyle(Theme.stroke)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .foregroundStyle(Theme.subtext)
                    .font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.stroke)
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(TokenUsage.short(v)).foregroundStyle(Theme.subtext).font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 88)
    }
}
