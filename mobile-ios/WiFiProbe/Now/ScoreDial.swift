import SwiftUI

/// The score as a ring. Doubles as the progress indicator during a run,
/// so the screen does not change shape when the numbers arrive.
struct ScoreDial: View {
    /// 0 to 100 when a run has finished, nil while one is in progress.
    var score: Double?
    var label: String?
    /// 0 to 1 while running.
    var progress: Double = 0
    var isRunning = false

    private var fraction: Double {
        isRunning ? progress : (score ?? 0) / 100
    }

    private var tint: Color {
        guard let score, !isRunning else { return .accentColor }
        switch score {
        case 80...: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            VStack(spacing: 2) {
                if isRunning {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else if let score {
                    Text("\(Int(score.rounded()))")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if let label {
                        Text(label.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "wifi").font(.system(size: 34))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 168, height: 168)
        .accessibilityElement()
        // Gated on isRunning the same way the visuals are: without this a
        // screen-reader user hears the previous run's score for the whole
        // duration of a new one, while the ring visually fills with live
        // progress.
        .accessibilityLabel(isRunning
            ? "Testing, \(Int(progress * 100)) percent complete"
            : score.map { "Score \(Int($0.rounded())), \(label ?? "")" }
                ?? "Not measured yet")
    }
}
