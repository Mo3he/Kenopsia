import SwiftUI

// MARK: - OnboardingView
/// Shown on first launch. Walks the user through the app and adding their first source.
struct OnboardingView: View {
    @EnvironmentObject var sources: SourceViewModel
    @Environment(\.dismiss) var dismiss
    @State private var page = 0
    @State private var showingAddSource = false

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "music.note.house.fill",
            title: "Your music.\nEvery source.",
            body: "Kenopsia plays from your iPhone, NAS drives, Subsonic servers, web radio, and cloud storage — all in one queue."
        ),
        OnboardingPage(
            icon: "waveform",
            title: "Zero compromise\naudio.",
            body: "FLAC, ALAC, WAV, MP3, AAC — every format, true gapless playback, and a 10-band parametric EQ."
        ),
        OnboardingPage(
            icon: "lock.fill",
            title: "No subscription.\nNo lock-in.",
            body: "One-time purchase. Your music stays on your hardware. No account required — ever."
        )
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

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
                if isLastPage {
                    Button("Add Your First Source") {
                        showingAddSource = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 32)

                    Button("Skip for now") { dismiss() }
                        .foregroundStyle(.secondary)
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
        .sheet(isPresented: $showingAddSource, onDismiss: { dismiss() }) {
            NavigationStack {
                SourcesView()
                    .environmentObject(sources)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showingAddSource = false
                            }
                        }
                    }
            }
        }
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
