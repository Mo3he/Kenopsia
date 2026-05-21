import SwiftUI

// MARK: - SmartPlaylistEditorView
/// Full-screen sheet for creating or editing a playlist (manual or smart).
struct SmartPlaylistEditorView: View {
    // Pass nil to create; pass an existing playlist to edit.
    var existing: Playlist?

    @EnvironmentObject var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.kAccent) private var accent

    // Local editable state
    @State private var name: String
    @State private var kind: PlaylistKind
    @State private var ruleOperator: SmartPlaylistOperator
    @State private var rules: [SmartPlaylistRule]
    @State private var limitEnabled: Bool
    @State private var limitCount: Int
    @State private var limitSortBy: SmartPlaylistLimit.SmartPlaylistSortField

    init(existing: Playlist? = nil) {
        self.existing = existing
        let p = existing
        _name          = State(initialValue: p?.name ?? "")
        _kind          = State(initialValue: p?.kind ?? .manual)
        _ruleOperator  = State(initialValue: p?.ruleOperator ?? .all)
        _rules         = State(initialValue: p?.rules ?? [SmartPlaylistRule(field: .artist, condition: .contains, value: "")])
        _limitEnabled  = State(initialValue: p?.limit != nil)
        _limitCount    = State(initialValue: p?.limit?.count ?? 25)
        _limitSortBy   = State(initialValue: p?.limit?.sortBy ?? .random)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Name + Kind
                Section {
                    TextField("Playlist Name", text: $name)
                    Picker("Type", selection: $kind) {
                        Text("Manual").tag(PlaylistKind.manual)
                        Text("Smart").tag(PlaylistKind.smart)
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: Smart rules
                if kind == .smart {
                    Section {
                        Picker("Match", selection: $ruleOperator) {
                            Text("ALL rules").tag(SmartPlaylistOperator.all)
                            Text("ANY rule").tag(SmartPlaylistOperator.any)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Rules")
                    }

                    Section {
                        ForEach($rules) { $rule in
                            RuleRowView(rule: $rule)
                        }
                        .onDelete { rules.remove(atOffsets: $0) }

                        Button {
                            rules.append(SmartPlaylistRule(field: .artist, condition: .contains, value: ""))
                        } label: {
                            Label("Add Rule", systemImage: "plus.circle")
                        }
                        .foregroundStyle(accent)
                    }

                    // MARK: Limit
                    Section {
                        Toggle("Limit to", isOn: $limitEnabled)
                        if limitEnabled {
                            Stepper("\(limitCount) tracks", value: $limitCount, in: 1...10000)
                            Picker("Sorted by", selection: $limitSortBy) {
                                ForEach(SmartPlaylistLimit.SmartPlaylistSortField.allCases, id: \.self) { field in
                                    Text(field.displayName).tag(field)
                                }
                            }
                        }
                    } header: {
                        Text("Limit")
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Playlist" : "Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        var playlist = existing ?? Playlist(name: name)
        playlist.name = name.trimmingCharacters(in: .whitespaces)
        playlist.kind = kind
        playlist.ruleOperator = ruleOperator
        playlist.rules = kind == .smart ? rules : []
        playlist.limit = (kind == .smart && limitEnabled)
            ? SmartPlaylistLimit(count: limitCount, sortBy: limitSortBy)
            : nil
        playlist.dateModified = .now
        library.save(playlist: playlist)
        dismiss()
    }
}

// MARK: - RuleRowView
/// Inline rule editor: field + condition + value on a single row.
private struct RuleRowView: View {
    @Binding var rule: SmartPlaylistRule

    // Valid conditions per field category
    private var allowedConditions: [SmartPlaylistCondition] {
        switch rule.field.category {
        case .string:  return [.contains, .doesNotContain, .is_, .isNot, .startsWith, .endsWith]
        case .numeric: return [.isGreaterThan, .isLessThan, .is_, .isNot]
        case .date:    return [.isInTheLast, .isNotInTheLast]
        case .bool:    return [.isTrue, .isFalse]
        }
    }

    private var showsValueField: Bool {
        switch rule.condition {
        case .isTrue, .isFalse: return false
        default: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Field", selection: $rule.field) {
                ForEach(SmartPlaylistField.allCases, id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .onChange(of: rule.field) { _, _ in
                // Reset to a valid condition when the field type changes
                if !allowedConditions.contains(rule.condition) {
                    rule.condition = allowedConditions.first ?? .contains
                }
            }

            Picker("Condition", selection: $rule.condition) {
                ForEach(allowedConditions, id: \.self) { cond in
                    Text(cond.displayName).tag(cond)
                }
            }

            if showsValueField {
                TextField(rule.field.valuePlaceholder, text: $rule.value)
                    .keyboardType(rule.field.category == .numeric ? .decimalPad : .default)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Display helpers

extension SmartPlaylistField {
    enum Category { case string, numeric, date, bool }

    var category: Category {
        switch self {
        case .title, .artist, .album, .genre, .format, .acoustID: return .string
        case .year, .playCount, .durationSeconds, .bitrateBps, .sampleRateHz, .rating, .bpm: return .numeric
        case .lastPlayed, .dateAdded: return .date
        case .isLossless, .isFavourited, .isExplicit: return .bool
        }
    }

    var displayName: String {
        switch self {
        case .title:          "Title"
        case .artist:         "Artist"
        case .album:          "Album"
        case .genre:          "Genre"
        case .year:           "Year"
        case .format:         "Format"
        case .playCount:      "Play Count"
        case .lastPlayed:     "Last Played"
        case .dateAdded:      "Date Added"
        case .rating:         "Rating"
        case .isFavourited:   "Favourited"
        case .isExplicit:     "Explicit"
        case .durationSeconds: "Duration (sec)"
        case .isLossless:     "Lossless"
        case .bitrateBps:     "Bitrate (bps)"
        case .sampleRateHz:   "Sample Rate (Hz)"
        case .bpm:            "BPM"
        case .acoustID:       "AcoustID"
        }
    }

    var valuePlaceholder: String {
        switch category {
        case .numeric: return "Number"
        case .date:    return "Days"
        default:       return "Value"
        }
    }
}

extension SmartPlaylistCondition {
    var displayName: String {
        switch self {
        case .contains:       "contains"
        case .doesNotContain: "does not contain"
        case .is_:            "is"
        case .isNot:          "is not"
        case .startsWith:     "starts with"
        case .endsWith:       "ends with"
        case .isGreaterThan:  "is greater than"
        case .isLessThan:     "is less than"
        case .isInTheLast:    "is in the last"
        case .isNotInTheLast: "is not in the last"
        case .isTrue:         "is true"
        case .isFalse:        "is false"
        }
    }
}

extension SmartPlaylistLimit.SmartPlaylistSortField: CaseIterable {
    public static var allCases: [SmartPlaylistLimit.SmartPlaylistSortField] {
        [.random, .mostPlayed, .leastPlayed, .recentlyAdded, .recentlyPlayed, .title]
    }

    var displayName: String {
        switch self {
        case .random:         "Random"
        case .mostPlayed:     "Most Played"
        case .leastPlayed:    "Least Played"
        case .recentlyAdded:  "Recently Added"
        case .recentlyPlayed: "Recently Played"
        case .title:          "Title"
        }
    }
}
