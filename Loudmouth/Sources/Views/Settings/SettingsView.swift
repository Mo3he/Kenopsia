import SwiftUI
import AVKit

// MARK: - SettingsView
struct SettingsView: View {
    @AppStorage("crossfadeDuration") var crossfadeDuration: Double = 3
    @AppStorage("crossfadeCurve")    var crossfadeCurve: String = CrossfadeCurve.equalPower.rawValue
    @AppStorage("replayGainMode")    var replayGainMode: String = "track"
    @AppStorage("vinylAnimation")    var vinylAnimation: Bool = true
    @AppStorage("karaokeMode")       var karaokeMode: Bool = false
    @AppStorage("lastFmEnabled")     var lastFmEnabled: Bool = false
    @AppStorage("listenBrainzEnabled") var listenBrainzEnabled: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Crossfade")
                            Spacer()
                            Text(crossfadeDuration == 0
                                 ? "Off (Gapless)"
                                 : "\(Int(crossfadeDuration))s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $crossfadeDuration, in: 0...12, step: 1)
                    }

                    if crossfadeDuration > 0 {
                        Picker("Curve", selection: $crossfadeCurve) {
                            ForEach(CrossfadeCurve.allCases, id: \.self) { curve in
                                Text(curve.displayName).tag(curve.rawValue)
                            }
                        }
                    }

                    Picker("ReplayGain", selection: $replayGainMode) {
                        Text("Off").tag("off")
                        Text("Track").tag("track")
                        Text("Album").tag("album")
                    }
                }

                Section("Now Playing") {
                    Toggle("Vinyl / CD Spin Animation", isOn: $vinylAnimation)
                    Toggle("Karaoke Mode", isOn: $karaokeMode)
                }

                Section("Scrobbling") {
                    Toggle("Last.fm", isOn: $lastFmEnabled)
                    if lastFmEnabled {
                        NavigationLink("Last.fm Account") { LastFmSettingsView() }
                    }
                    Toggle("ListenBrainz", isOn: $listenBrainzEnabled)
                    if listenBrainzEnabled {
                        NavigationLink("ListenBrainz Account") { ListenBrainzSettingsView() }
                    }
                }

                Section("Output") {
                    NavigationLink("AirPlay / Bluetooth") { OutputRoutingView() }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    NavigationLink("Privacy Policy") { PrivacyPolicyView() }
                    Link(destination: URL(string: "https://buymeacoffee.com/Mo3he")!) {
                        Label("Buy Me a Coffee", systemImage: "cup.and.heat.waves.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - Last.fm Settings
struct LastFmSettingsView: View {
    @AppStorage("lastFmUsername") private var storedUsername = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnected = false
    @State private var connectedUser = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let stats = ListeningStatsStore()

    var body: some View {
        Form {
            if isConnected {
                Section {
                    LabeledContent("Connected as", value: connectedUser)
                    Button("Disconnect", role: .destructive) {
                        KeychainHelper.shared.delete(key: "lastfm_session_key")
                        isConnected = false
                        connectedUser = ""
                        storedUsername = ""
                    }
                }
            } else {
                Section("Sign in to Last.fm") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Connect").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isLoading)
                }
                if let err = errorMessage {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            Section("About") {
                Text("Scrobbling sends your listening history to Last.fm. An API key must be configured in the app for this to work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Last.fm")
        .onAppear {
            isConnected = (try? KeychainHelper.shared.read(key: "lastfm_session_key")) != nil
            connectedUser = storedUsername
        }
    }

    private func connect() async {
        isLoading = true
        errorMessage = nil
        do {
            let key = try await stats.connectLastFm(username: username, password: password)
            try KeychainHelper.shared.save(key: "lastfm_session_key", value: key)
            storedUsername = username
            isConnected = true
            connectedUser = username
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - ListenBrainz Settings
struct ListenBrainzSettingsView: View {
    @State private var token = ""
    @State private var isConnected = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let stats = ListeningStatsStore()

    var body: some View {
        Form {
            if isConnected {
                Section {
                    Text("Token saved").foregroundStyle(.green)
                    Button("Disconnect", role: .destructive) {
                        KeychainHelper.shared.delete(key: "listenbrainz_token")
                        isConnected = false
                    }
                }
            } else {
                Section {
                    Text("Get your token from listenbrainz.org/profile")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("User token", text: $token)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Button {
                        Task { await saveToken() }
                    } label: {
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Save & Verify").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(token.isEmpty || isLoading)
                }
                if let err = errorMessage {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("ListenBrainz")
        .onAppear {
            isConnected = (try? KeychainHelper.shared.read(key: "listenbrainz_token")) != nil
        }
    }

    private func saveToken() async {
        isLoading = true
        errorMessage = nil
        do {
            try await stats.verifyListenBrainzToken(token)
            try KeychainHelper.shared.save(key: "listenbrainz_token", value: token)
            isConnected = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - AirPlay / Bluetooth routing
struct OutputRoutingView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Select Audio Output")
                .font(.headline)
            AirPlayPickerView()
                .frame(width: 44, height: 44)
            Text("Tap the icon above to choose AirPlay, Bluetooth, or other audio outputs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .navigationTitle("Output")
    }
}

struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.systemBlue
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PrivacyPolicyView: View {
    var body: some View { Text("No tracking. No ads. No accounts required.").navigationTitle("Privacy") }
}

// MARK: - SidebarView (iPad / Mac)
struct SidebarView: View {
    @EnvironmentObject var search: SearchViewModel
    var body: some View {
        List {
            NavigationLink(destination: LibraryView()) {
                Label("Library", systemImage: "music.note.list")
            }
            NavigationLink(destination: SearchView().environmentObject(search)) {
                Label("Search", systemImage: "magnifyingglass")
            }
            NavigationLink(destination: SourcesView()) {
                Label("Sources", systemImage: "externaldrive")
            }
            NavigationLink(destination: SettingsView()) {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .navigationTitle("Loudmouth")
    }
}
