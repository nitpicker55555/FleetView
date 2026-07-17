import SwiftUI
import Charts

/// A compact per-turn "new tokens" *increment* bar chart for one project (each bar = tokens added in
/// that turn/bucket, not a running total). The x-axis includes the latest bar and a caption spells out
/// when the data last updated.
struct ProjectTokenChart: View {
    let samples: [TokenSample]        // increments (bar heights)
    var lastUpdated: Date? = nil
    var window: TimeInterval = 3600   // x-axis spans exactly this (the last 1h)

    private var lastDate: Date? { samples.last?.t }

    // Pin the x-axis to [now - window, now] so the axis literally shows the last 10 hours.
    private var domain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-window)...now
    }

    private static let updatedFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let l = lastUpdated ?? lastDate {
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
        Chart(samples, id: \.t) { s in
            BarMark(x: .value("Time", s.t), y: .value("New tokens", s.newTokens), width: .fixed(5))
                .foregroundStyle(.linearGradient(colors: [Theme.accent, Theme.accent.opacity(0.55)],
                                                 startPoint: .top, endPoint: .bottom))
                .cornerRadius(1.5)
        }
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
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
