import SwiftUI
import PhotosUI

// MARK: - ArtworkFixerView
/// Scans the library for tracks with missing or low-resolution artwork
/// and queues up auto-fetch replacements in one pass.
/// Manual override: tap any row to pick replacement art yourself.
struct ArtworkFixerView: View {
    @EnvironmentObject var library: LibraryViewModel
    @State private var problems: [ArtworkProblem] = []
    @State private var isScanning = false
    @State private var isFixingAll = false
    @State private var fixProgress: Double = 0
    @State private var selectedAlbum: Album?
    @State private var photoPickerItem: PhotosPickerItem?

    private let minResolution: CGFloat = 500

    var body: some View {
        NavigationStack {
            Group {
                if isScanning {
                    ProgressView("Scanning artwork...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if problems.isEmpty {
                    ContentUnavailableView(
                        "All Good",
                        systemImage: "checkmark.seal.fill",
                        description: Text("Every album has high-quality artwork.")
                    )
                } else {
                    problemList
                }
            }
            .navigationTitle("Artwork Fixer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Scan") { Task { await scan() } }
                        .disabled(isScanning || isFixingAll)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fix All") { Task { await fixAll() } }
                        .disabled(problems.isEmpty || isFixingAll)
                }
            }
            .overlay(alignment: .bottom) {
                if isFixingAll {
                    VStack(spacing: 8) {
                        ProgressView(value: fixProgress)
                        Text("Fetching artwork… \(Int(fixProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            }
            .task { await scan() }
        }
    }

    private var problemList: some View {
        List(problems) { problem in
            ArtworkProblemRow(problem: problem) { album in
                selectedAlbum = album
            }
            .swipeActions(edge: .trailing) {
                Button("Auto-Fix") {
                    Task { await autoFix(problem: problem) }
                }
                .tint(Color.accentColor)
            }
        }
        .sheet(item: $selectedAlbum) { album in
            manualPickerSheet(for: album)
        }
    }

    private func manualPickerSheet(for album: Album) -> some View {
        NavigationStack {
            PhotosPicker(
                selection: $photoPickerItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .onChange(of: photoPickerItem) {
                if let item = photoPickerItem {
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let key = album.artworkCacheKey {
                            ArtworkCache.shared.store(imageData: data, forKey: key)
                            await scan()   // refresh problem list
                        }
                        photoPickerItem = nil
                    }
                }
            }
            .navigationTitle(album.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    // MARK: - Scan
    private func scan() async {
        isScanning = true
        var found: [ArtworkProblem] = []
        for album in library.albums {
            let problem = checkArtwork(album: album)
            if let p = problem { found.append(p) }
        }
        await MainActor.run {
            problems = found.sorted { $0.severity.sortPriority > $1.severity.sortPriority }
            isScanning = false
        }
    }

    private func checkArtwork(album: Album) -> ArtworkProblem? {
        guard let key = album.artworkCacheKey else {
            return ArtworkProblem(album: album, severity: .missing)
        }
        guard let image = ArtworkCache.shared.fullImage(forKey: key) else {
            return ArtworkProblem(album: album, severity: .missing)
        }
        let size = image.size
        if size.width < minResolution || size.height < minResolution {
            return ArtworkProblem(
                album: album,
                severity: .lowResolution(width: Int(size.width), height: Int(size.height))
            )
        }
        return nil
    }

    // MARK: - Fix
    private func autoFix(problem: ArtworkProblem) async {
        let album = problem.album
        let key = album.artworkCacheKey ?? album.id
        await ArtworkFetchService.shared.fetch(artist: album.artist, album: album.title, cacheKey: key)
        await scan()
    }

    private func fixAll() async {
        isFixingAll = true
        for (i, problem) in problems.enumerated() {
            await autoFix(problem: problem)
            await MainActor.run {
                fixProgress = Double(i + 1) / Double(problems.count)
            }
        }
        isFixingAll = false
    }
}

// MARK: - ArtworkProblem
struct ArtworkProblem: Identifiable {
    let id = UUID()
    let album: Album
    let severity: Severity

    enum Severity {
        case missing
        case lowResolution(width: Int, height: Int)

        var sortPriority: Int {
            switch self {
            case .missing:         return 2
            case .lowResolution:   return 1
            }
        }

        var label: String {
            switch self {
            case .missing:          "Missing"
            case .lowResolution:    "Low Resolution"
            }
        }

        var color: Color {
            switch self {
            case .missing:         .red
            case .lowResolution:   .orange
            }
        }
    }
}

// MARK: - ArtworkProblemRow
struct ArtworkProblemRow: View {
    let problem: ArtworkProblem
    let onTap: (Album) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Current (bad) artwork or placeholder
            MiniArtworkView(cacheKey: problem.album.artworkCacheKey)

            VStack(alignment: .leading, spacing: 2) {
                Text(problem.album.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(problem.album.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Severity badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(problem.severity.color)
                        .frame(width: 6, height: 6)
                    Text(severityDetail)
                        .font(.caption2)
                        .foregroundStyle(problem.severity.color)
                }
            }
            Spacer()
            Button {
                onTap(problem.album)
            } label: {
                Image(systemName: "photo.badge.plus")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var severityDetail: String {
        switch problem.severity {
        case .missing:
            return "No artwork"
        case .lowResolution(let w, let h):
            return "\(w)×\(h)px — below 500px minimum"
        }
    }
}
