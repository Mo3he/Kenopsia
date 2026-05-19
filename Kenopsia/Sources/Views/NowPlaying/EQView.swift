import SwiftUI

// MARK: - EQView
/// 10-band parametric equaliser. Per-band gain sliders + preset picker.
struct EQView: View {
    @EnvironmentObject var player: PlayerViewModel
    @State private var presets: [EQPreset] = [.flat]
    @State private var showingPresetSave = false
    @State private var newPresetName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Preset picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets) { preset in
                            Button(preset.name) { player.apply(eqPreset: preset) }
                                .buttonStyle(.bordered)
                                .tint(player.eqPreset.id == preset.id ? Color.accentColor : Color.secondary)
                        }
                    }
                    .padding(.horizontal)
                }

                // Band sliders
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(player.eqPreset.bands) { band in
                        EQBandView(band: band) { newGain in
                            var updated = player.eqPreset
                            if let idx = updated.bands.firstIndex(where: { $0.id == band.id }) {
                                updated.bands[idx].gainDB = newGain
                            }
                            player.apply(eqPreset: updated)
                        }
                    }
                }
                .padding(.horizontal)

                // Flat reset
                Button("Reset to Flat") { player.apply(eqPreset: .flat) }
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .navigationTitle("Equaliser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingPresetSave = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            presets = EQPresetStore.shared.presets
        }
        .alert("Save Preset", isPresented: $showingPresetSave) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func savePreset() {
        guard !newPresetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let new = EQPreset(id: UUID(), name: newPresetName, bands: player.eqPreset.bands, isBuiltIn: false)
        EQPresetStore.shared.save(preset: new)
        presets = EQPresetStore.shared.presets
        newPresetName = ""
    }
}

// MARK: - EQBandView
struct EQBandView: View {
    let band: EQBand
    let onGainChange: (Float) -> Void

    private let range: ClosedRange<Float> = -12...12

    var body: some View {
        VStack(spacing: 4) {
            Text(gainLabel)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: 16)

            Slider(
                value: Binding(get: { Double(band.gainDB) }, set: { onGainChange(Float($0)) }),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .rotationEffect(.degrees(-90))
            .frame(width: 120, height: 32)
            .frame(width: 32, height: 120)

            Text(freqLabel)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var freqLabel: String {
        band.frequencyHz >= 1000
            ? "\(Int(band.frequencyHz / 1000))k"
            : "\(Int(band.frequencyHz))"
    }

    private var gainLabel: String {
        let g = band.gainDB
        return g == 0 ? "0" : String(format: "%+.1f", g)
    }
}
