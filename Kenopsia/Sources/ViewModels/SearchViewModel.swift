import Foundation
import Combine

// MARK: - SearchViewModel
/// Powers unified search across all library sources simultaneously.
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var trackResults:  [Track]  = []
    @Published private(set) var albumResults:  [Album]  = []
    @Published private(set) var artistResults: [Artist] = []
    @Published private(set) var isSearching = false

    private let store: LibraryStore
    private var cancellables = Set<AnyCancellable>()

    init(store: LibraryStore? = nil) {
        self.store = store ?? .shared
        $query
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] q in self?.search(q) }
            .store(in: &cancellables)
    }

    private func search(_ q: String) {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            trackResults = []
            albumResults = []
            artistResults = []
            return
        }
        isSearching = true
        let lower = q.lowercased()
        trackResults  = store.tracks.values.filter  { $0.matches(query: lower) }
        albumResults  = store.albums.values.filter  { $0.matches(query: lower) }
        artistResults = store.artists.values.filter { $0.matches(query: lower) }
        isSearching = false
    }
}

// MARK: - Search helpers
private extension Track {
    func matches(query: String) -> Bool {
        title.lowercased().contains(query)
        || artist.lowercased().contains(query)
        || album.lowercased().contains(query)
    }
}

private extension Album {
    func matches(query: String) -> Bool {
        title.lowercased().contains(query)
        || artist.lowercased().contains(query)
    }
}

private extension Artist {
    func matches(query: String) -> Bool {
        name.lowercased().contains(query)
    }
}
