import SwiftUI

// MARK: - LyricsView
/// Auto-scrolling synced lyrics panel. Highlights the current line.
struct LyricsView: View {
    let lines: [LyricsLine]
    let position: Double   // current playback position in seconds

    private var currentIndex: Int? {
        guard !lines.isEmpty else { return nil }
        // Find the last line whose timestamp is <= position
        return lines.indices
            .filter { lines[$0].timestampSeconds <= position }
            .last
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(isActive(line) ? .title2.bold() : .title3)
                            .foregroundStyle(isActive(line) ? .white : .white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .id(line.id)
                            .animation(.easeInOut(duration: 0.2), value: currentIndex)
                    }
                }
                .padding(.vertical, 40)
            }
            .onChange(of: currentIndex) { _, newIndex in
                if let idx = newIndex {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(lines[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func isActive(_ line: LyricsLine) -> Bool {
        guard let idx = currentIndex else { return false }
        return lines[idx].id == line.id
    }
}
