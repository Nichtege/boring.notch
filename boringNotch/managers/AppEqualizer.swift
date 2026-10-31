//
//  AppEqualizer.swift
//  boringNotch
//
//  What's kept of one app's equalizer, and the presets to start from. The sound goes through it in AppVolumeRender.
//

import Defaults

struct AppEqualizer: Codable, Equatable, Defaults.Serializable {
    static let maxGain: Float = 12

    var isOn = true
    /// In dB, one per frequency in equalizerFrequencies.
    var bands = [Float](repeating: 0, count: equalizerFrequencies.count)

    /// Only then it needs a tap. Without one the app's sound stays exactly as it is.
    var isActive: Bool {
        isOn && bands.contains { $0.magnitude >= 0.05 }
    }

    var preset: Preset? {
        (Self.headphonePresets + Self.presets).first { $0.bands == bands }
    }

    struct Preset: Identifiable {
        let name: String
        let bands: [Float]
        var id: String { name }
    }

    /// The Sony's is AutoEq's fixed-band result from oratory1990's measurement, see THIRD_PARTY_LICENSES. Nobody has
    /// published numbers for the AirPods yet, and they adapt to the ear and the volume by themselves. Theirs only
    /// leans gently against the V shape reviews describe: more sub-bass and air, less mids.
    static let headphonePresets: [Preset] = [
        Preset(name: "Sony WH-1000XM4", bands: [-4.3, -1.8, -5.8, -1.4, 0.5, -0.6, 6, -0.8, 1, -2.2]),
        Preset(name: "AirPods Pro 3 (approximate)", bands: [-2, -1.5, 0, 0.5, 1, 1, 0.5, 0, -1.5, -2]),
    ]

    static let presets: [Preset] = [
        Preset(name: "Flat", bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Acoustic", bands: [5, 4.9, 3.95, 1.05, 2.15, 1.75, 3.5, 4.1, 3.55, 2.15]),
        Preset(name: "Bass Booster", bands: [5.5, 4.25, 3.5, 2.5, 1.25, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Reducer", bands: [-5.5, -4.25, -3.5, -2.5, -1.25, 0, 0, 0, 0, 0]),
        Preset(name: "Classical", bands: [4.75, 3.75, 3, 2.5, -1.5, -1.5, 0, 2.25, 3.25, 3.75]),
        Preset(name: "Dance", bands: [3.57, 6.55, 4.99, 0, 1.92, 3.65, 5.15, 4.54, 3.59, 0]),
        Preset(name: "Deep", bands: [4.95, 3.55, 1.75, 1, 2.85, 2.5, 1.45, -2.15, -3.55, -4.6]),
        Preset(name: "Electronic", bands: [4.25, 3.8, 1.2, 0, -2.15, 2.25, 0.85, 1.25, 3.95, 4.8]),
        Preset(name: "Hip-Hop", bands: [5, 4.25, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        Preset(name: "Jazz", bands: [4, 3, 1.5, 2.25, -1.5, -1.5, 0, 1.5, 3, 3.75]),
        Preset(name: "Latin", bands: [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]),
        Preset(name: "Loudness", bands: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        Preset(name: "Lounge", bands: [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]),
        Preset(name: "Piano", bands: [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]),
        Preset(name: "Pop", bands: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        Preset(name: "R&B", bands: [2.62, 6.92, 5.65, 1.33, -2.19, -1.5, 2.32, 2.65, 3, 3.75]),
        Preset(name: "Rock", bands: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        Preset(name: "Small Speakers", bands: [5.5, 4.25, 3.5, 2.5, 1.25, 0, -1.25, -2.5, -3.5, -4.25]),
        Preset(name: "Spoken Word", bands: [-3.46, -0.47, 0, 0.69, 3.46, 4.61, 4.84, 4.28, 2.54, 0]),
        Preset(name: "Treble Booster", bands: [0, 0, 0, 0, 0, 1.25, 2.5, 3.5, 4.25, 5.5]),
        Preset(name: "Treble Reducer", bands: [0, 0, 0, 0, 0, -1.25, -2.5, -3.5, -4.25, -5.5]),
        Preset(name: "Vocal Booster", bands: [-1.5, -3, -3, 1.5, 3.75, 3.75, 3, 1.5, 0, -1.5]),
    ]
}
