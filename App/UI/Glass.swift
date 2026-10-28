/// A faint accent glow at the top that fades into the system background.
import SwiftUI

/// Large title, a short line of context and the screen's content on the soft backdrop.

/// A rounded glass container for a text field.

/// The one main action on a screen.

/// A calm secondary action: grey text, no chrome.

/// A short error line under a field.
struct SoftBackdrop: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), .clear],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.55)
            )
        }
        .ignoresSafeArea()
    }
}
struct ScreenLayout<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.largeTitle.bold())
                    if let subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background { SoftBackdrop() }
    }
}
struct GlassField<Field: View>: View {
    @ViewBuilder var field: Field

    var body: some View {
        field
            .font(.title3)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}
struct PrimaryButton: View {
    let title: String
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().tint(.white) }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(isWorking)
    }
}
struct QuietButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
struct ErrorLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
