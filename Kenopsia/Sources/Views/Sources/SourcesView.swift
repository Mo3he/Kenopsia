import SwiftUI
import CryptoKit

// MARK: - SourcesView
struct SourcesView: View {
    @EnvironmentObject var sources: SourceViewModel
    @EnvironmentObject var player: PlayerViewModel
    @State private var isAddingSource = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(sources.sources.filter { $0.kind != .wifiTransfer }) { source in
                    NavigationLink(destination: SourceDetailView(source: source)) {
                        SourceRowView(source: source)
                    }
                }
                .onDelete { offsets in
                    let visible = sources.sources.filter { $0.kind != .wifiTransfer }
                    offsets.forEach { sources.delete(sourceID: visible[$0].id) }
                }
                Section("Wi-Fi Transfer") {
                    WiFiTransferRow()
                }
            }
            .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAddingSource = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isAddingSource) { AddSourceView() }
        }
    }
}

// MARK: - SourceRowView
struct SourceRowView: View {
    let source: MusicSource
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(source.kind.tintColor.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: source.kind.systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName).font(.subheadline).fontWeight(.semibold)
                HStack(spacing: 6) {
                    Text(source.kind.displayName).font(.caption).foregroundStyle(.secondary)
                    if source.trackCount > 0 {
                        Text("\u{00B7}").font(.caption).foregroundStyle(.tertiary)
                        Text("\(source.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
                    }
                    if let date = source.lastScanDate {
                        Text("\u{00B7}").font(.caption).foregroundStyle(.tertiary)
                        Text(date, style: .relative).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if !source.isEnabled {
                Image(systemName: "pause.circle.fill").foregroundStyle(.tertiary).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - WiFiTransferRow
struct WiFiTransferRow: View {
    @EnvironmentObject var sources: SourceViewModel
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.teal.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: "wifi")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Receive Files via Wi-Fi").font(.subheadline).fontWeight(.semibold)
                if sources.wifiTransferActive, let url = sources.wifiTransferURL {
                    Text(url).font(.caption).foregroundStyle(.green)
                } else {
                    Text("Open a browser on the same network to upload").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { sources.wifiTransferActive },
                set: { active in
                    if active { sources.startWiFiTransfer() }
                    else      { sources.stopWiFiTransfer()  }
                }
            ))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - WiFiTransferPasswordRow
struct WiFiTransferPasswordRow: View {
    @EnvironmentObject var sources: SourceViewModel

    private var wifiConfig: WiFiTransferConfig? {
        sources.sources.first(where: { $0.kind == .wifiTransfer }).flatMap {
            if case .wifiTransfer(let c) = $0.config { return c } else { return nil }
        }
    }

    @State private var requiresPassword: Bool = false
    @State private var password: String = ""

    var body: some View {
        Group {
            Toggle("Require Upload Password", isOn: $requiresPassword)
                .onChange(of: requiresPassword) { _, newVal in
                    sources.updateWiFiTransferConfig(requiresPassword: newVal, password: password)
                }
            if requiresPassword {
                SecureField("Upload Password", text: $password)
                    .onSubmit {
                        sources.updateWiFiTransferConfig(requiresPassword: requiresPassword, password: password)
                    }
            }
        }
        .onAppear {
            if let cfg = wifiConfig {
                requiresPassword = cfg.requiresPassword
                password = cfg.requiresPassword
                    ? ((try? KeychainHelper.shared.read(key: cfg.keychainKey)) ?? "")
                    : ""
            }
        }
    }
}

// MARK: - SourceDetailView  (edit existing source)
struct SourceDetailView: View {
    @State var source: MusicSource
    @EnvironmentObject var sources: SourceViewModel
    @EnvironmentObject var player: PlayerViewModel
    @State private var isScanningNow = false
    @State private var scanResult: String?
    @State private var showingFilePicker = false

    var body: some View {
        Form {
            Section {
                TextField("Display Name", text: $source.displayName)
                Toggle("Enabled", isOn: $source.isEnabled)
                Toggle("Pin for Offline", isOn: $source.isPinnedOffline)
            }
            configSection
            if source.kind != .wifiTransfer && source.kind != .appleMusic {
                Section {
                    Button {
                        isScanningNow = true
                        sources.scan(source: source) { result in
                            isScanningNow = false; scanResult = result
                        }
                    } label: {
                        if isScanningNow {
                            HStack { ProgressView(); Text("Scanning…").foregroundStyle(.secondary) }
                        } else {
                            Label("Scan Now", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isScanningNow)
                    if isScanningNow {
                        Button("Cancel Scan", role: .destructive) {
                            sources.cancelScan(for: source.id)
                            isScanningNow = false
                            scanResult = "Scan cancelled"
                        }
                        .font(.subheadline)
                    }
                    if let result = scanResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
        .navigationTitle(source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: source) { _, newSource in sources.update(source: newSource) }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            if let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                source.config = .local(LocalSourceConfig(bookmarkData: bookmark))
                sources.update(source: source)
            }
            url.stopAccessingSecurityScopedResource()
        }
    }

    @ViewBuilder
    private var configSection: some View {
        switch source.config {
        case .local(let cfg):
            Section("Folder") {
                if cfg.bookmarkData != nil {
                    Label("Folder selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("No folder selected").foregroundStyle(.secondary)
                }
                Button("Choose Folder") { showingFilePicker = true }
                Toggle("Watch for Changes", isOn: Binding(
                    get: { guard case .local(let c) = source.config else { return true }; return c.watchForChanges },
                    set: { v in guard case .local(var c) = source.config else { return }; c.watchForChanges = v; source.config = .local(c) }
                ))
            }
        case .subsonic:
            Section("Server") {
                TextField("https://music.example.com", text: subsonicURLBinding)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Username", text: subsonicUsernameBinding)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("Password", text: subsonicPasswordBinding)
            }
            Section("Security") {
                Toggle(isOn: Binding(
                    get: { guard case .subsonic(let c) = source.config else { return false }; return c.allowsSelfSignedCertificate },
                    set: { v in guard case .subsonic(var c) = source.config else { return }; c.allowsSelfSignedCertificate = v; source.config = .subsonic(c) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow self-signed certificate")
                        Text("Enable for home Navidrome/Subsonic servers with untrusted TLS certificates.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .nas:
            Section("Connection") {
                TextField("192.168.1.100 or hostname (leave blank to auto-discover)", text: nasHostBinding)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Text("Port"); Spacer()
                    TextField("8200", value: nasPortBinding, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Text("Protocol: DLNA / UPnP").foregroundStyle(.secondary)
            }
        case .webRadio(let cfg):
            Section("Stations (\(cfg.stations.count))") {
                ForEach(cfg.stations) { station in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name).font(.subheadline)
                        Text(station.streamURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .onDelete { offsets in
                    guard case .webRadio(var c) = source.config else { return }
                    c.stations.remove(atOffsets: offsets)
                    source.config = .webRadio(c)
                }
                NavigationLink("Add Station") { AddRadioStationView(source: $source) }
            }
        case .cloud(let cfg):
            Section(cfg.provider.displayName) {
                if cfg.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if !cfg.accountID.isEmpty {
                        Text(cfg.accountID).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Disconnect", role: .destructive) {
                        guard case .cloud(var c) = source.config else { return }
                        c.isConnected = false; c.accountID = ""
                        KeychainHelper.shared.delete(key: c.keychainKey)
                        c.keychainKey = ""
                        source.config = .cloud(c)
                    }
                } else if cfg.provider == .iCloud {
                    Label("Uses your iCloud account — no sign-in needed", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if cfg.provider == .backblaze {
                    LabeledContent("Key ID") {
                        Text(cfg.accountID.isEmpty ? "Not set" : cfg.accountID)
                            .foregroundStyle(cfg.accountID.isEmpty ? .red : .primary)
                    }
                    LabeledContent("App Key") {
                        Text(cfg.keychainKey.isEmpty ? "Not set" : "••••••••")
                            .foregroundStyle(cfg.keychainKey.isEmpty ? .red : .primary)
                    }
                }
            }
        case .wifiTransfer:
            Section("Security") {
                WiFiTransferPasswordRow()
            }
        case .appleMusic:
            AppleMusicDetailSection(source: source)
        }
    }

    private var subsonicURLBinding: Binding<String> {
        Binding(
            get: { guard case .subsonic(let c) = source.config else { return "" }; return c.serverURL },
            set: { v in guard case .subsonic(var c) = source.config else { return }; c.serverURL = v; source.config = .subsonic(c) }
        )
    }
    private var subsonicUsernameBinding: Binding<String> {
        Binding(
            get: { guard case .subsonic(let c) = source.config else { return "" }; return c.username },
            set: { v in guard case .subsonic(var c) = source.config else { return }; c.username = v; source.config = .subsonic(c) }
        )
    }
    private var subsonicPasswordBinding: Binding<String> {
        Binding(
            get: { guard case .subsonic(let c) = source.config else { return "" }; return (try? KeychainHelper.shared.read(key: c.keychainKey)) ?? "" },
            set: { val in
                guard case .subsonic(var c) = source.config else { return }
                let key = c.keychainKey.isEmpty ? "sub_\(source.id.rawValue)" : c.keychainKey
                try? KeychainHelper.shared.save(key: key, value: val)
                c.keychainKey = key; source.config = .subsonic(c)
            }
        )
    }
    private var nasHostBinding: Binding<String> {
        Binding(
            get: { guard case .nas(let c) = source.config else { return "" }; return c.host },
            set: { v in guard case .nas(var c) = source.config else { return }; c.host = v; source.config = .nas(c) }
        )
    }
    private var nasPortBinding: Binding<Int> {
        Binding(
            get: { guard case .nas(let c) = source.config else { return 8200 }; return c.port },
            set: { v in guard case .nas(var c) = source.config else { return }; c.port = v; source.config = .nas(c) }
        )
    }
}

// MARK: - AddRadioStationView
struct AddRadioStationView: View {
    @Binding var source: MusicSource
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""
    @State private var genre = ""

    var body: some View {
        Form {
            Section("Station Info") {
                TextField("e.g. BBC Radio 6 Music", text: $name)
                TextField("Stream URL (http/https)", text: $urlString)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Genre (optional)", text: $genre)
            }
            Section {
                Text("Paste the direct stream URL — MP3, AAC, HLS or Icecast are all supported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Add Station")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    guard !name.isEmpty, !urlString.isEmpty else { return }
                    if case .webRadio(var cfg) = source.config {
                        cfg.stations.append(WebRadioSourceConfig.RadioStation(
                            id: UUID(), name: name, streamURL: urlString, genre: genre
                        ))
                        source.config = .webRadio(cfg)
                    }
                    dismiss()
                }
                .disabled(name.isEmpty || urlString.isEmpty)
                .fontWeight(.semibold)
            }
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
        }
    }
}

// MARK: - AddSourceView  (step 1 wrapper)
struct AddSourceView: View {
    var body: some View {
        NavigationStack { SourceTypePickerView() }
    }
}

// MARK: - SourceTypePickerView  (step 1: choose kind)
struct SourceTypePickerView: View {
    @Environment(\.dismiss) private var dismiss

    private struct SourceOption: Identifiable {
        var id: MusicSourceKind { kind }
        let kind: MusicSourceKind
        let headline: String
        let detail: String
    }

    private let options: [SourceOption] = [
        .init(kind: .local,      headline: "Music on This Device",  detail: "Play files stored on your iPhone or iPad"),
        .init(kind: .appleMusic, headline: "Apple Music",           detail: "Play from your Apple Music library"),
        .init(kind: .nas,        headline: "NAS / DLNA Server",      detail: "Stream from a home server or network drive"),
        .init(kind: .subsonic,   headline: "Subsonic / Navidrome",   detail: "Self-hosted music server with API access"),
        .init(kind: .webRadio,   headline: "Web Radio",              detail: "Internet radio via stream URL"),
        .init(kind: .cloud,      headline: "Cloud Drive",            detail: "iCloud Drive and Backblaze B2"),
    ]

    var body: some View {
        List(options) { option in
            NavigationLink(destination: AddSourceConfigView(kind: option.kind)) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(option.kind.tintColor.gradient)
                            .frame(width: 50, height: 50)
                        Image(systemName: option.kind.systemImage)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.headline).font(.headline)
                        Text(option.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Add Music Source")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
        }
    }
}

// MARK: - AddSourceConfigView  (step 2: configure, then add)
struct AddSourceConfigView: View {
    let kind: MusicSourceKind
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var sources: SourceViewModel

    @State private var displayName = ""

    // Local
    @State private var showingFolderPicker = false
    @State private var localBookmark: Data?
    @State private var localFolderName = ""
    @State private var watchForChanges = true

    // Subsonic
    @State private var subURL = ""
    @State private var subUsername = ""
    @State private var subPassword = ""

    // NAS
    @State private var nasHost = ""
    @State private var nasPort = 8200
    @State private var nasProtocol: NASSourceConfig.NASProtocol = .dlna
    @State private var nasDiscoveredServers: [URL] = []
    @State private var isDiscovering = false

    // Cloud
    @State private var cloudProvider: CloudProvider = .iCloud
    @State private var b2AccountID = ""
    @State private var b2AppKey = ""

    // Connection test
    enum ConnectionStatus { case idle, testing, success(String), failure(String) }
    @State private var connectionStatus: ConnectionStatus = .idle

    var body: some View {
        Form {
            Section("Name") {
                TextField(kind.defaultDisplayName, text: $displayName)
            }
            configFields
            if kind == .subsonic || kind == .nas {
                testConnectionSection
            }
            Section {
                Button { addSource(); dismiss() } label: {
                    HStack {
                        Spacer()
                        Text("Add \(kind.displayName)").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!isValid)
            }
        }
        .navigationTitle("Configure")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            localFolderName = url.lastPathComponent
            localBookmark = try? url.bookmarkData(
                options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            url.stopAccessingSecurityScopedResource()
        }
    }

    @ViewBuilder
    private var configFields: some View {
        switch kind {
        case .local:
            Section("Folder") {
                if localBookmark != nil {
                    Label(localFolderName.isEmpty ? "Folder selected" : localFolderName,
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button(localBookmark == nil ? "Choose Folder" : "Change Folder") {
                    showingFolderPicker = true
                }
                Toggle("Watch for Changes", isOn: $watchForChanges)
            }

        case .subsonic:
            Section("Server") {
                TextField("https://music.example.com", text: $subURL)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: subURL) { _, _ in connectionStatus = .idle }
                TextField("Username", text: $subUsername)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: subUsername) { _, _ in connectionStatus = .idle }
                SecureField("Password", text: $subPassword)
                    .onChange(of: subPassword) { _, _ in connectionStatus = .idle }
            }

        case .nas:
            Section("Connection") {
                TextField("192.168.1.100 or hostname (optional)", text: $nasHost)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: nasHost) { _, _ in connectionStatus = .idle }
                HStack {
                    Text("Port"); Spacer()
                    TextField("8200", value: $nasPort, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Text("Protocol: DLNA / UPnP").foregroundStyle(.secondary)
            }
            Section {
                Button {
                    isDiscovering = true
                    nasDiscoveredServers = []
                    Task {
                        let browser = DLNABrowser()
                        nasDiscoveredServers = await browser.discoverServers(timeout: 5)
                        isDiscovering = false
                    }
                } label: {
                    if isDiscovering {
                        HStack { ProgressView(); Text("Scanning network\u{2026}").foregroundStyle(.secondary) }
                    } else {
                        Label("Scan Network", systemImage: "network")
                    }
                }
                .disabled(isDiscovering)
                ForEach(nasDiscoveredServers, id: \.absoluteString) { url in
                    Button {
                        nasHost = url.host ?? ""
                        nasPort = url.port ?? 8200
                        connectionStatus = .idle
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.host ?? url.absoluteString).font(.subheadline)
                            Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Auto-Discover")
            } footer: {
                Text("Tap a discovered server to fill in its address, or type it manually above.")
                    .font(.caption)
            }

        case .webRadio:
            Section {
                Label(
                    "Add the source first, then open it to add your favourite stations.",
                    systemImage: "info.circle"
                )
                .font(.subheadline).foregroundStyle(.secondary)
            }

        case .cloud:
            Section("Provider") {
                Picker("Service", selection: $cloudProvider) {
                    Text("iCloud Drive").tag(CloudProvider.iCloud)
                    Text("Backblaze B2").tag(CloudProvider.backblaze)
                }
            }
            if cloudProvider == .iCloud {
                Section {
                    Label("Uses your Apple ID. No sign-in required.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else if cloudProvider == .backblaze {
                Section("Backblaze B2 Credentials") {
                    TextField("Key ID (e.g. 00aabbcc…)", text: $b2AccountID)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Application Key", text: $b2AppKey)
                }
                Section {
                    Text("Find your Key ID and Application Key in the Backblaze B2 console under App Keys.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        case .wifiTransfer:
            EmptyView()

        case .appleMusic:
            Section {
                Label("Kenopsia will request access to your Apple Music library when you tap Add.", systemImage: "music.note")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var testConnectionSection: some View {
        Section {
            Button {
                Task {
                    if kind == .subsonic { await testSubsonicConnection() }
                    else if kind == .nas { await testNASConnection() }
                }
            } label: {
                if case .testing = connectionStatus {
                    HStack { ProgressView(); Text("Testing…").foregroundStyle(.secondary) }
                } else {
                    Label("Test Connection", systemImage: "network")
                }
            }
            .disabled({
                if case .testing = connectionStatus { return true }
                if kind == .subsonic { return subURL.isEmpty || subUsername.isEmpty || subPassword.isEmpty }
                if kind == .nas { return nasHost.isEmpty }
                return true
            }())

            switch connectionStatus {
            case .success(let msg):
                Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline)
            case .failure(let msg):
                Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.subheadline)
            default: EmptyView()
            }
        }
    }

    private var isValid: Bool {
        switch kind {
        case .local:        return localBookmark != nil
        case .subsonic:     return !subURL.isEmpty && !subUsername.isEmpty && !subPassword.isEmpty
        case .nas:          return true   // host is optional — SSDP discovers if left empty
        case .webRadio, .wifiTransfer, .appleMusic: return true
        case .cloud:
            switch cloudProvider {
            case .iCloud:    return true
            case .backblaze: return !b2AccountID.isEmpty && !b2AppKey.isEmpty
            }
        }
    }

    private func addSource() {
        let name = displayName.isEmpty ? kind.defaultDisplayName : displayName
        let config: MusicSourceConfig
        switch kind {
        case .local:
            config = .local(LocalSourceConfig(bookmarkData: localBookmark, watchForChanges: watchForChanges))
        case .subsonic:
            let key = "sub_\(UUID().uuidString)"
            try? KeychainHelper.shared.save(key: key, value: subPassword)
            config = .subsonic(SubsonicSourceConfig(
                serverURL: subURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: subUsername,
                keychainKey: key
            ))
        case .nas:
            config = .nas(NASSourceConfig(host: nasHost, port: nasPort, protocol_: nasProtocol))
        case .webRadio:
            config = .webRadio(WebRadioSourceConfig(stations: []))
        case .cloud:
            var cfg = CloudSourceConfig(provider: cloudProvider)
            switch cloudProvider {
            case .iCloud:
                cfg.isConnected = true
                cfg.accountID = "iCloud Drive"
            case .backblaze:
                let key = "b2_\(UUID().uuidString)"
                try? KeychainHelper.shared.save(key: key, value: b2AppKey)
                cfg.accountID = b2AccountID
                cfg.keychainKey = key
                cfg.isConnected = true
            }
            config = .cloud(cfg)
        case .wifiTransfer:
            config = .wifiTransfer(WiFiTransferConfig())
        case .appleMusic:
            config = .appleMusic(AppleMusicSourceConfig())
        }
        let newSource = MusicSource(kind: kind, displayName: name, config: config)
        sources.add(source: newSource)
        // Kick off authorisation + initial library scan for Apple Music.
        if kind == .appleMusic {
            Task { await sources.connectAppleMusic(source: newSource) }
        }
    }

    // MARK: - Network tests

    private func testSubsonicConnection() async {
        connectionStatus = .testing
        guard var comps = URLComponents(string: subURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            connectionStatus = .failure("Invalid URL"); return
        }
        // Preserve any existing base path for reverse-proxy servers (e.g. example.com/music).
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = (base == "/" ? "" : base) + "/rest/ping.view"
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let token = Insecure.MD5.hash(data: Data((subPassword + salt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        comps.queryItems = [
            URLQueryItem(name: "u", value: subUsername),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Kenopsia"),
            URLQueryItem(name: "f", value: "json"),
        ]
        guard let url = comps.url else { connectionStatus = .failure("Could not build request URL"); return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                connectionStatus = .failure("HTTP error from server"); return
            }
            struct Ping: Decodable {
                struct Body: Decodable { let status: String; let version: String }
                let subsonicResponse: Body
                enum CodingKeys: String, CodingKey { case subsonicResponse = "subsonic-response" }
            }
            if let p = try? JSONDecoder().decode(Ping.self, from: data), p.subsonicResponse.status == "ok" {
                connectionStatus = .success("Connected — Subsonic API v\(p.subsonicResponse.version)")
            } else {
                connectionStatus = .failure("Wrong username or password")
            }
        } catch {
            connectionStatus = .failure(error.localizedDescription)
        }
    }

    private func testNASConnection() async {
        connectionStatus = .testing
        // First attempt SSDP — it returns the canonical LOCATION URL (correct path).
        let browser = DLNABrowser()
        let discovered = await browser.discoverServers(timeout: 3)
        let hostMatch = nasHost.isEmpty ? discovered.first : discovered.first(where: { $0.host == nasHost })
        if let match = hostMatch {
            do {
                let (_, response) = try await URLSession.shared.data(from: match)
                if let http = response as? HTTPURLResponse, http.statusCode < 400 {
                    connectionStatus = .success("Server reachable (\(match.lastPathComponent))")
                    return
                }
            } catch { }
        }
        // SSDP not available or no match — try well-known description paths.
        guard !nasHost.isEmpty else {
            connectionStatus = .failure("No servers found via SSDP. Type a host address manually.")
            return
        }
        let paths = ["/rootDesc.xml", "/description.xml", "/DeviceDescription.xml"]
        for path in paths {
            guard let url = URL(string: "http://\(nasHost):\(nasPort)\(path)") else { continue }
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode < 400 {
                    connectionStatus = .success("Server reachable at \(path)")
                    return
                }
            } catch { }
        }
        connectionStatus = .failure("Cannot reach \(nasHost):\(nasPort) \u{2014} check host and port")
    }
}

// MARK: - MusicSourceKind UI helpers
extension MusicSourceKind {
    var tintColor: Color {
        switch self {
        case .local:        .blue
        case .nas:          .indigo
        case .subsonic:     .purple
        case .webRadio:     .orange
        case .cloud:        .cyan
        case .wifiTransfer: .teal
        case .appleMusic:   .pink
        }
    }

    var defaultDisplayName: String {
        switch self {
        case .local:        "On This iPhone"
        case .nas:          "My NAS"
        case .subsonic:     "Navidrome"
        case .webRadio:     "Web Radio"
        case .cloud:        "Cloud Drive"
        case .wifiTransfer: "Wi-Fi Transfer"
        case .appleMusic:   "Apple Music"
        }
    }
}

// MARK: - AppleMusicDetailSection
/// Shown in SourceDetailView for an Apple Music source. Displays authorisation
/// status and a button to re-sync the library.
struct AppleMusicDetailSection: View {
    let source: MusicSource
    @EnvironmentObject var sources: SourceViewModel
    @State private var isSyncing = false
    @State private var syncResult: String?

    private var config: AppleMusicSourceConfig? {
        guard case .appleMusic(let c) = source.config else { return nil }
        return c
    }

    var body: some View {
        Section("Apple Music") {
            LabeledContent("Status") {
                if config?.isAuthorised == true {
                    Label("Authorised", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not authorised", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            if let count = config?.lastFetchedCount, count > 0 {
                LabeledContent("Songs in library") {
                    Text("\(count)")
                }
            }
        }
        Section {
            Button {
                isSyncing = true
                Task {
                    await sources.connectAppleMusic(source: source)
                    isSyncing = false
                    syncResult = config?.isAuthorised == true ? "Library synced" : "Authorisation denied"
                }
            } label: {
                if isSyncing {
                    HStack { ProgressView(); Text("Syncing library…").foregroundStyle(.secondary) }
                } else {
                    Label("Sync Library Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isSyncing)
            if let result = syncResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
