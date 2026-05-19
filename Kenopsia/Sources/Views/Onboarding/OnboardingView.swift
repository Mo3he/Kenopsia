import SwiftUI

// MARK: - OnboardingView
/// Shown on first launch. Walks the user through adding their first source.
struct OnboardingView: View {
    @EnvironmentObject var sources: SourceViewModel
    @Environment(\.dismiss) var dismiss
    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "music.note.house.fill",
            title: "Your music.\nEvery source.",
            body: "Kenopsia plays from your iPhone, NAS drives, Subsonic servers, web radio, and cloud storage — all in one queue."
        ),
        OnboardingPage(
            icon: "waveform",
            title: "Zero compromise\naudio.",
            body: "FLAC, ALAC, DSD, WAV, MP3, AAC — every format, true gapless playback, and a 10-band parametric EQ."
        ),
        OnboardingPage(
            icon: "lock.fill",
            title: "No subscription.\nNo lock-in.",
            body: "One-time purchase. Your music stays on your hardware. No account required — ever."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    OnboardingPageView(page: pages[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // CTA
            VStack(spacing: 12) {
                if page == pages.count - 1 {
                    Button("Get Started") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.horizontal, 32)
                } else {
                    Button("Next") { withAnimation { page += 1 } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.horizontal, 32)

                    Button("Skip") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 40)
        }
        .interactiveDismissDisabled()
    }
}

struct OnboardingPage {
    let icon: String
    let title: String
    let body: String
}

struct OnboardingPageView: View {
    let page: OnboardingPage
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: page.icon)
                .font(.system(size: 80))
                .foregroundStyle(Color.accentColor)
            Text(page.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}
