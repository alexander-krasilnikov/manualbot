import Core
import SwiftUI

/// The Answer style page: one slider from Strict to Open. Its position is the relevance distance a passage must be
/// within to be used, and the stop it falls in decides what is said when the documents do not answer.
struct AnswerStyleView: View {
    @Bindable var settings: AnswerSettings

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(heading)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .accessibilityIdentifier("answerStyleHeading")
                    Slider(value: $settings.offset, in: AnswerStyle.range, step: AnswerStyle.step)
                        .accessibilityLabel("Answer style")
                        .accessibilityValue("\(settings.style.stop.name), distance \(Self.format(settings.distance))")
                        .accessibilityIdentifier("answerStyleSlider")
                    StopNames(current: settings.style.stop)
                }
                .padding(.vertical, 6)
            } footer: {
                Text(Self.hint(for: settings.style.stop, distance: settings.distance))
                    .accessibilityIdentifier("answerStyleHint")
            }

            Section {
                Button("Reset to Balanced") { settings.reset() }
                    .disabled(settings.style == .balanced)
                    .accessibilityIdentifier("answerStyleReset")
            } footer: {
                Text("Replies that are not from your documents are always marked “Not from your documents” and carry no sources.")
            }
        }
        .navigationTitle("Answer style")
    }

    private var heading: String { "\(settings.style.stop.name) · \(Self.format(settings.distance))" }

    static func format(_ distance: Double) -> String { String(format: "%.2f", distance) }

    static func hint(for stop: AnswerStyle.Stop, distance: Double) -> String {
        let cutoff = "A passage is used only when it is within \(format(distance)) of your question; lower is stricter."
        return switch stop {
        case .strict:
            "\(cutoff) Fewer, surer answers. When nothing matches, it says it couldn't find an answer and lists the closest passages. The language model is not asked."
        case .balanced:
            "\(cutoff) When nothing matches, it says it couldn't find an answer and lists the closest passages. The language model is not asked."
        case .conversational:
            "\(cutoff) Questions your documents don't answer get a short reply that isn't from them, such as what the app can do, in your language. It states no facts."
        case .open:
            "\(cutoff) Questions your documents don't answer get an answer from the language model's general knowledge, with the closest passages below. These replies can be wrong."
        }
    }
}

/// The four stop names under the slider, each under its own stretch of it, the current one emphasised.
private struct StopNames: View {
    let current: AnswerStyle.Stop

    var body: some View {
        GeometryReader { geometry in
            let total = Double(AnswerStyle.Stop.allCases.map(\.steps.count).reduce(0, +))
            HStack(spacing: 0) {
                ForEach(AnswerStyle.Stop.allCases, id: \.self) { stop in
                    Text(stop.name)
                        .font(.caption.weight(stop == current ? .bold : .regular))
                        .foregroundStyle(stop == current ? Color.accentColor : .secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: geometry.size.width * Double(stop.steps.count) / total)
                }
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)  // the slider's value already names the stop
    }
}
