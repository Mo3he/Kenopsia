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
    @State private var fixStatus: String = ""
    @State private var selectedAlbum: Album?
    @State private var photoPickerItem: PhotosPickerItem?

    private let minResolution: CGFloat = 500

    var body: some View {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fix All") { Task { await fixAll() } }
                    .disabled(problems.isEmpty || isFixingAll)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isScanning || isFixingAll)
            }
        }
        .overlay(alignment: .bottom) {
            if isFixingAll {
                VStack(spacing: 8) {
                    ProgressView(value: fixProgress)
                    Text(fixStatus.isEmpty
                         ? "Fetching artwork… \(Int(fixProgress * 100))%"
                         : fixStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .task { await scan() }
    }

    private var problemList: some View {
        List(problems) { problem in
            ArtworkProblemRow(problem: problem) { album in
                selectedAlbum = album
            }
            .swipeActions(edge: .trailing) {
                Button("Auto-Fix") {
                    Task { await autoFix(id: problem.id) }
                }
                .tint(Color.accentColor)
                .disabled(isFixingAll)
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
                guard let item = photoPickerItem else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let key = album.artworkCacheKey
                            ?? ArtworkFetchService.generateCacheKey(artist: album.artist, album: album.title)
                        ArtworkCache.shared.store(imageData: data, forKey: key)
                        library.setArtworkCacheKey(key, forAlbumID: album.id)
                        await scan()
                    }
                    photoPickerItem = nil
                    selectedAlbum = nil
                }
            }
            .navigationTitle(album.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        photoPickerItem = nil
                        selectedAlbum = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Scan
    private func scan() async {
        await MainActor.run { isScanning = true }
        let albums = await MainActor.run { library.albums }
        var found: [ArtworkProblem] = []
        // autoreleasepool per album so any transient ImageIO allocations are
        // released as we go rather than piling up until the loop ends. With a
        // 6000-track library this loop runs several hundred times.
        for album in albums {
            autoreleasepool {
                if let p = checkArtwork(album: album) { found.append(p) }
            }
        }
        let sorted = found.sorted { $0.severity.sortPriority > $1.severity.sortPriority }
        await MainActor.run {
            problems = sorted
            isScanning = false
        }
    }

    private func checkArtwork(album: Album) -> ArtworkProblem? {
        guard let key = album.artworkCacheKey else {
            return ArtworkProblem(album: album, severity: .missing)
        }
        // Read the dimensions from the file header. Decoding the image here
        // (fullImage) allocates ~4 MB per album and kills large libraries.
        guard let size = ArtworkCache.shared.pixelSize(forKey: key) else {
            return ArtworkProblem(album: album, severity: .missing)
        }
        if size.width < minResolution || size.height < minResolution {
            return ArtworkProblem(
                album: album,
                severity: .lowResolution(width: Int(size.width), height: Int(size.height))
            )
        }
        return nil
    }

    // MARK: - Fix
    /// Single-row fix. Updates status in-place so the row reflects what's
    /// happening, and removes the row on success after a brief delay.
    private func autoFix(id: UUID) async {
        guard let idx = problems.firstIndex(where: { $0.id == id }) else { return }
        let album = problems[idx].album
        problems[idx].status = .fetching
        let success = await ArtworkApplier.fetchAndApply(album: album, library: library)
        if let i = problems.firstIndex(where: { $0.id == id }) {
            if success {
                problems[i].status = .applied
                try? await Task.sleep(nanoseconds: 700_000_000)
                problems.removeAll { $0.id == id }
            } else {
                problems[i].status = .notFound
            }
        }
    }

    private func fixAll() async {
        isFixingAll = true
        fixProgress = 0
        // Snapshot the IDs so we don't iterate over rows being removed mid-flight.
        let ids = problems.filter { $0.status == .pending || $0.status == .notFound }.map { $0.id }
        for (i, id) in ids.enumerated() {
            if let p = problems.first(where: { $0.id == id }) {
                fixStatus = "Fetching: \(p.album.title)"
            }
            await autoFix(id: id)
            fixProgress = Double(i + 1) / Double(ids.count)
        }
        fixStatus = "Done."
        try? await Task.sleep(nanoseconds: 600_000_000)
        isFixingAll = false
        fixStatus = ""
    }
}

// MARK: - ArtworkApplier
/// Shared helper that fetches artwork for an album and stamps the key onto every
/// track. Used by both ArtworkFixerView and the per-album fix in AlbumDetailView.
enum ArtworkApplier {
    /// Returns true if the cache contains artwork for this album after the call.
    @discardableResult
    static func fetchAndApply(album: Album, library: LibraryViewModel) async -> Bool {
        let key = album.artworkCacheKey
            ?? ArtworkFetchService.generateCacheKey(artist: album.artist, album: album.title)
        await ArtworkFetchService.shared.fetch(artist: album.artist, album: album.title, cacheKey: key)
        await MainActor.run {
            library.setArtworkCacheKey(key, forAlbumID: album.id)
        }
        return ArtworkCache.shared.hasArtwork(forKey: key)
    }
}

// MARK: - ArtworkProblem
struct ArtworkProblem: Identifiable {
    let id = UUID()
    let album: Album
    let severity: Severity
    var status: Status = .pending

    enum Status: Equatable {
        case pending
        case fetching
        case applied
        case notFound
        case error(String)
    }

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
            MiniArtworkView(cacheKey: problem.album.artworkCacheKey)

            VStack(alignment: .leading, spacing: 2) {
                Text(problem.album.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(problem.album.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusLine
            }
            Spacer()
            trailingControl
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch problem.status {
        case .pending:
            HStack(spacing: 4) {
                Circle()
                    .fill(problem.severity.color)
                    .frame(width: 6, height: 6)
                Text(severityDetail)
                    .font(.caption2)
                    .foregroundStyle(problem.severity.color)
            }
        case .fetching:
            Label("Fetching…", systemImage: "arrow.down.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .applied:
            Label("Applied", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .notFound:
            Label("No artwork found online — try Photos", systemImage: "questionmark.circle")
                .font(.caption2).foregroundStyle(.orange)
        case .error(let msg):
            Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch problem.status {
        case .fetching:
            ProgressView().scaleEffect(0.7)
        case .applied:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default:
            Button {
                onTap(problem.album)
            } label: {
                Image(systemName: "photo.badge.plus")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
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
