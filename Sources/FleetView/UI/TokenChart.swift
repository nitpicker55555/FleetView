import SwiftUI
import Charts

/// A compact "new tokens over time" line/area chart for one project.
struct ProjectTokenChart: View {
    let samples: [TokenSample]

    var body: some View {
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
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
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
        .frame(height: 92)
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
        .background(Theme.card.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
    }
}
