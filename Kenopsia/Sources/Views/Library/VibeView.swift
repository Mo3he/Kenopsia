import SwiftUI

// MARK: - LibraryVibe
struct LibraryVibe: Identifiable {
    let id: String
    let name: String
    let icon: String          // SF Symbol name
    let subtitle: String
    let gradient: [Color]     // two-stop gradient
    let limit: Int
    let matcher: (Track) -> Bool

    func generate(from tracks: [Track]) -> [Track] {
        var matched = tracks.filter { matcher($0) }.shuffled()
        if matched.count < 10 {
            matched += tracks.filter { !matcher($0) }.shuffled()
        }
        return Array(matched.prefix(limit))
    }

    // MARK: - Catalogue
    static let all: [LibraryVibe] = [
        LibraryVibe(
            id: "chill",
            name: "Chill",
            icon: "water.waves",
            subtitle: "Laid-back & relaxed",
            gradient: [Color(red: 0.16, green: 0.50, blue: 0.82), Color(red: 0.00, green: 0.72, blue: 0.86)],
            limit: 40,
            matcher: { t in
                let g = t.genre.lowercased()
                return ["ambient", "folk", "acoustic", "jazz", "blues", "soft",
                        "mellow", "chillout", "chill", "lounge"].contains { g.contains($0) }
            }
        ),
        LibraryVibe(
            id: "focus",
            name: "Focus",
            icon: "brain.head.profile",
            subtitle: "Deep work",
            gradient: [Color(red: 0.34, green: 0.24, blue: 0.80), Color(red: 0.26, green: 0.38, blue: 0.94)],
            limit: 40,
            matcher: { t in
                let g = t.genre.lowercased()
                return ["instrumental", "classical", "post-rock", "minimal",
                        "neoclassical", "piano", "orchestral"].contains { g.contains($0) }
            }
        ),
        LibraryVibe(
            id: "energy",
            name: "Energy",
            icon: "bolt.fill",
            subtitle: "Pump it up",
            gradient: [Color(red: 0.90, green: 0.18, blue: 0.08), Color(red: 1.00, green: 0.50, blue: 0.08)],
            limit: 40,
            matcher: { t in
                let g = t.genre.lowercased()
                return ["rock", "punk", "metal", "rap", "hip-hop", "hip hop",
                        "drum and bass", "dnb", "hardcore", "hard"].contains { g.contains($0) }
            }
        ),
        LibraryVibe(
            id: "party",
            name: "Party",
            icon: "party.popper",
            subtitle: "Get the room moving",
            gradient: [Color(red: 0.85, green: 0.08, blue: 0.58), Color(red: 0.60, green: 0.18, blue: 0.90)],
            limit: 40,
            matcher: { t in
                let g = t.genre.lowercased()
                return ["pop", "dance", "club", "disco", "edm", "house",
                        "electro", "techno", "trance", "funk"].contains { g.contains($0) }
            }
        ),
        LibraryVibe(
            id: "late_night",
            name: "Late Night",
            icon: "moon.stars.fill",
            subtitle: "Dark hours, slow thoughts",
            gradient: [Color(red: 0.08, green: 0.08, blue: 0.38), Color(red: 0.22, green: 0.10, blue: 0.56)],
            limit: 35,
            matcher: { t in
                let g = t.genre.lowercased()
                return ["jazz", "blues", "dark", "noir", "soul",
                        "ambient", "neo-soul"].contains { g.contains($0) }
                    || t.durationSeconds > 300
            }
        ),
        LibraryVibe(
            id: "feel_good",
            name: "Feel Good",
            icon: "sun.max.fill",
            subtitle: "Sunny & uplifting",
            gradient: [Color(red: 0.96, green: 0.60, blue: 0.08), Color(red: 0.88, green: 0.34, blue: 0.08)],
            limit: 40,
            matcher: { t in
                let g = t.genre.lowercased()
                return ["indie", "soul", "r&b", "rnb", "reggae",
                        "ska", "country", "feel good"].contains { g.contains($0) }
            }
        ),
        LibraryVibe(
            id: "favourites",
            name: "Favourites",
            icon: "heart.fill",
            subtitle: "Your loved tracks",
            gradient: [Color(red: 0.84, green: 0.10, blue: 0.28), Color(red: 0.96, green: 0.20, blue: 0.56)],
            limit: 50,
            matcher: { $0.isFavourited }
        ),
        LibraryVibe(
            id: "rediscover",
            name: "Rediscover",
            icon: "clock.arrow.circlepath",
            subtitle: "Tracks you've forgotten",
            gradient: [Color(red: 0.40, green: 0.28, blue: 0.16), Color(red: 0.58, green: 0.46, blue: 0.32)],
            limit: 35,
            matcher: { $0.playCount <= 2 }
        ),
        LibraryVibe(
            id: "new_arrivals",
            name: "New Arrivals",
            icon: "sparkles",
            subtitle: "Recently added",
            gradient: [Color(red: 0.04, green: 0.60, blue: 0.52), Color(red: 0.16, green: 0.74, blue: 0.34)],
            limit: 40,
            matcher: { t in
                t.dateAdded > Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            }
        ),
        LibraryVibe(
            id: "shuffle_all",
            name: "Shuffle All",
            icon: "shuffle",
            subtitle: "Anything goes",
            gradient: [Color(red: 0.22, green: 0.22, blue: 0.28), Color(red: 0.40, green: 0.40, blue: 0.50)],
            limit: 50,
            matcher: { _ in true }
        ),
    ]
}

// MARK: - VibeView
struct VibeView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.kAccent) var accent
    @State private var activeVibeID: String?
    @State private var generatedTracks: [Track] = []
    @State private var showingPlaylist = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.kBackground.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("VIBE")
                                .font(.system(size: 12, weight: .bold))
                                .tracking(2)
                                .foregroundStyle(.primary)
                            Text("Pick a mood. We'll find the tracks.")
                                .font(.system(size: 13))
                                .foregroundStyle(.primary.opacity(0.38))
                        }
                        .padding(.top, 8)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(LibraryVibe.all) { vibe in
                                VibeCard(vibe: vibe, isActive: activeVibeID == vibe.id)
                                    .onTapGesture { selectVibe(vibe) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, player.state.status != .stopped ? 80 : 24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(accent)
        .sheet(isPresented: $showingPlaylist) {
            if let vibe = LibraryVibe.all.first(where: { $0.id == activeVibeID }) {
                VibePlaylistSheet(vibe: vibe, tracks: generatedTracks)
                    .environmentObject(player)
            }
        }
    }

    private func selectVibe(_ vibe: LibraryVibe) {
        let generated = vibe.generate(from: Array(library.tracks))
        guard !generated.isEmpty else { return }
        activeVibeID = vibe.id
        generatedTracks = generated
        player.play(tracks: generated)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showingPlaylist = true
    }
}

// MARK: - VibeCard
struct VibeCard: View {
    let vibe: LibraryVibe
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Gradient fill
            LinearGradient(
                colors: vibe.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))

            // Noise/highlight layer
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.18), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: vibe.icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 34, height: 34)

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text(vibe.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(vibe.subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            // Active ring
            if isActive {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(height: 142)
        .scaleEffect(isActive ? 0.96 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isActive)
    }
}

// MARK: - VibePlaylistSheet
struct VibePlaylistSheet: View {
    let vibe: LibraryVibe
    let tracks: [Track]
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            HStack(spacing: 14) {
                ZStack {
                    LinearGradient(
                        colors: vibe.gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Image(systemName: vibe.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(vibe.name.uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.primary)
                    Text("\(tracks.count) TRACKS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(.primary.opacity(0.38))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.45))
                        .padding(9)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider().overlay(Color.primary.opacity(0.07))

            List {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                    TrackRowView(track: track)
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(tracks: tracks, startAt: idx) }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.primary.opacity(0.06))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color.kBackground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
