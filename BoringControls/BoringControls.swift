//
//  BoringControls.swift
//  BoringControls
//
//  The tile for Control Center: it says what plays right now, and a press opens the list of all devices in the notch.
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct BoringControls: WidgetBundle {
    var body: some Widget {
        MediaControl()
    }
}

struct MediaControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.nichtege.boringnotch.media", provider: Provider()) { now in
            ControlWidgetButton(action: ShowMediaIntent()) {
                Label {
                    Text(now.title)
                    Text(now.subtitle)
                } icon: {
                    Image(systemName: now.icon)
                }
            }
        }
        .displayName("Medien")
        .description("Zeigt, was gerade läuft, und öffnet die Liste aller Geräte in der Notch.")
    }

    struct NowPlaying {
        var title = "Medien"
        var subtitle = "Alle Geräte"
        var icon = "hifispeaker.2.fill"
    }

    /// The app writes this while something plays, and it's gone again when that stops.
    struct Provider: ControlValueProvider {
        var previewValue: NowPlaying { NowPlaying() }

        func currentValue() async throws -> NowPlaying {
            let shared = UserDefaults(suiteName: "MC8NLUCW46.com.nichtege.boringnotch")
            guard let title = shared?.string(forKey: "mediaTileTitle") else { return NowPlaying() }
            return NowPlaying(
                title: title,
                subtitle: shared?.string(forKey: "mediaTileDevice") ?? "",
                icon: shared?.string(forKey: "mediaTileIcon") ?? "play.fill"
            )
        }
    }
}

struct ShowMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Geräte in der Notch zeigen"

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.nichtege.boringnotch.showMedia"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}
