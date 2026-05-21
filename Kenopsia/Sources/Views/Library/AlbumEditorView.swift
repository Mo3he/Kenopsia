import SwiftUI
import PhotosUI

// MARK: - AlbumEditorView
/// Sheet for editing all metadata fields of an album.
/// Propagates changes to every track in the album via LibraryStore.
struct AlbumEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var library: LibraryViewModel

    let album: Album

    @State private var title: String
    @State private var artist: String
    @State private var year: String
    @State private var genre: String
    @State private var artworkPhotoItem: PhotosPickerItem?
    @State private var artworkImage: UIImage?
    @State private var pendingArtworkData: Data?

    init(album: Album) {
        self.album = album
        _title  = State(initialValue: album.title)
        _artist = State(initialValue: album.artist)
        _year   = State(initialValue: album.year.map(String.init) ?? "")
        _genre  = State(initialValue: album.genre)
    }

    private var tracks: [Track] {
        album.trackIDs.compactMap { library.track(for: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Album Info") {
                    LabeledTextField("Title",  text: $title)
                    LabeledTextField("Artist", text: $artist)
                    TextField("Year", text: $year)
                        .keyboardType(.numberPad)
                    LabeledTextField("Genre",  text: $genre)
                }

                Section("Artwork") {
                    HStack(spacing: 16) {
                        Group {
                            if let img = artworkImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                                    .overlay {
                                        Image(systemName: "music.note")
                                            .foregroundStyle(.secondary)
                                    }
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        PhotosPicker(selection: $artworkPhotoItem, matching: .images) {
                            Label("Change Artwork", systemImage: "photo")
                        }
                        .onChange(of: artworkPhotoItem) { _, item in
                            guard let item else { return }
                            Task {
                                guard let data = try? await item.loadTransferable(type: Data.self),
                                      let img = UIImage(data: data) else { return }
                                pendingArtworkData = data
                                artworkImage = img
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .bold()
                }
            }
        }
        .onAppear { loadCurrentArtwork() }
    }

    // MARK: - Artwork

    private func loadCurrentArtwork() {
        guard let key = album.artworkCacheKey else { return }
        artworkImage = ArtworkCache.shared.fullImage(forKey: key)
    }

    // MARK: - Save

    private func save() {
        let yearInt = Int(year)

        // Derive (or reuse) the artwork cache key
        var artworkKey: String? = album.artworkCacheKey
        if let data = pendingArtworkData {
            let key = artworkKey
                ?? ArtworkFetchService.generateCacheKey(artist: album.artist, album: album.title)
            ArtworkCache.shared.store(imageData: data, forKey: key)
            artworkKey = key
        }

        // Propagate to all tracks
        for var track in tracks {
            if !title.isEmpty  { track.album = title }
            if !artist.isEmpty { track.albumArtist = artist }
            if let y = yearInt { track.year = y }
            if !genre.isEmpty  { track.genre = genre }
            if let key = artworkKey { track.artworkCacheKey = key }
            library.update(track: track)
        }

        // Write metadata to local files so edits survive a rescan.
        let updatedTracks = tracks.compactMap { library.track(for: $0.id) }
        Task {
            let writer = TagWriter()
            for track in updatedTracks {
                guard case .localFile(let path) = track.uri else { continue }
                let url = URL(fileURLWithPath: path)
                var tags = TrackTags(track: track)
                // Only write the fields this editor controls; preserve the rest.
                if !title.isEmpty  { tags.album = title }
                if !artist.isEmpty { tags.albumArtist = artist }
                tags.year = yearInt ?? track.year
                if !genre.isEmpty  { tags.genre = genre }
                tags.artworkData = pendingArtworkData   // nil = preserve existing artwork
                try? await writer.write(tags: tags, to: url)
            }
        }

        dismiss()
    }
}
