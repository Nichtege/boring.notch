//
//  KalypsoNotch.swift
//  boringNotch
//
//  Kalypso (Ege's voice assistant) in the notch. Kalypso writes ~/Atlas/status.json
//  (format: Nichtege/kalypso docs/status.md); the notch only reads it, no network.
//  Shows whether Kalypso is listening right now (privacy: always visible when the
//  microphone is open), the subject and minutes while taking notes, and her answer.
//

import Combine
import SwiftUI

struct KalypsoStatus: Equatable {
    var modus: String = "aus"          // aus, diktat, mitschreiben, zusammenfassen, assistent
    var aufnahme = false               // microphone open
    var phase: String = "ruhe"         // ruhe, hoert, erkennt, denkt, spricht
    var lauscht = false                // listening for "Kalypso" without a key
    var fach: String?
    var seit: Date?
    var letzteAntwort: String?
    var aktualisiert: Date?
}

@MainActor
final class KalypsoManager: ObservableObject {
    static let shared = KalypsoManager()

    @Published private(set) var status = KalypsoStatus()

    /// The real home folder (in the sandbox, homeDirectoryForCurrentUser is the container).
    /// Reading ~/Atlas is allowed by a read-only entitlement exception.
    private let datei: URL = {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Atlas/status.json")
    }()
    private var timer: Timer?

    private init() {
        lesen()
        // status.json is replaced atomically, so a file watcher would lose the inode; poll lightly.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.lesen() }
        }
    }

    /// Something worth the notch right now (not the always-on listening, that stays in the menu bar).
    var aktiv: Bool {
        guard frisch else { return false }
        if status.modus == "mitschreiben" && status.aufnahme { return true }
        if status.modus == "assistent" { return true }
        return status.phase == "hoert" || status.phase == "denkt" || status.phase == "spricht"
    }

    /// Kalypso quit without clearing the file: ignore states older than 2 minutes,
    /// except a running note-taking session (it refreshes every 15 s).
    private var frisch: Bool {
        guard let t = status.aktualisiert else { return false }
        return Date().timeIntervalSince(t) < 120
    }

    private static let datum: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private func lesen() {
        guard let d = try? Data(contentsOf: datei),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        var s = KalypsoStatus()
        s.modus = j["modus"] as? String ?? "aus"
        s.aufnahme = j["aufnahme"] as? Bool ?? false
        s.phase = j["phase"] as? String ?? "ruhe"
        s.lauscht = j["lauscht"] as? Bool ?? false
        s.fach = j["fach"] as? String
        s.letzteAntwort = j["letzte_antwort"] as? String
        if let t = j["seit"] as? String { s.seit = Self.datum.date(from: String(t.prefix(19))) }
        if let t = j["aktualisiert"] as? String { s.aktualisiert = Self.datum.date(from: String(t.prefix(19))) }
        if s != status { status = s }
    }
}

// MARK: - Closed-notch live activity

/// Left of the notch: what Kalypso is doing. Right: minutes while taking notes, otherwise a wave.
struct KalypsoLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var kalypso = KalypsoManager.shared

    static let meer = Color(red: 0.05, green: 0.62, blue: 0.68)
    static let koralle = Color(red: 0.96, green: 0.33, blue: 0.36)

    var body: some View {
        let seite = max(0, vm.effectiveClosedNotchHeight - 12) + 10
        HStack(spacing: 0) {
            links.frame(width: seite)
            Rectangle().fill(.black).frame(width: vm.closedNotchSize.width)
            rechts.frame(width: seite)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    @ViewBuilder private var links: some View {
        let s = kalypso.status
        if s.modus == "mitschreiben" && s.aufnahme {
            KalypsoPuls(farbe: Self.koralle).frame(width: 9, height: 9)
                .help("Kalypso schreibt mit\(s.fach.map { ": \($0)" } ?? "")")
        } else if s.phase == "hoert" {
            Image(systemName: "mic.fill").font(.caption).foregroundStyle(Self.koralle)
        } else {
            KalypsoKugel().frame(width: 14, height: 14)
        }
    }

    @ViewBuilder private var rechts: some View {
        let s = kalypso.status
        if s.modus == "mitschreiben", let seit = s.seit {
            TimelineView(.periodic(from: seit, by: 30)) { ctx in
                Text("\(Int(ctx.date.timeIntervalSince(seit) / 60))′")
                    .font(.caption).fontWeight(.semibold).notchNumber()
                    .foregroundStyle(Self.koralle)
            }
        } else {
            KalypsoWelle(aktiv: s.phase == "spricht" || s.phase == "hoert")
                .frame(width: 16, height: 12)
        }
    }
}

/// Pulsing dot (recording).
struct KalypsoPuls: View {
    let farbe: Color
    @State private var an = false
    var body: some View {
        Circle().fill(farbe)
            .opacity(an ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(), value: an)
            .onAppear { an = true }
    }
}

/// Small orb in Kalypso's colours, like the one in her app (thinking / answering).
struct KalypsoKugel: View {
    static let farben: [Color] = [
        KalypsoLiveActivity.meer, Color(red: 0.30, green: 0.80, blue: 0.85), Color(red: 0.13, green: 0.20, blue: 0.52),
        Color(red: 0.55, green: 0.35, blue: 0.95), KalypsoLiveActivity.koralle, KalypsoLiveActivity.meer,
    ]
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(AngularGradient(colors: Self.farben, center: .center, angle: .degrees(t * 120)))
                .blur(radius: 1.5)
                .scaleEffect(0.9 + 0.1 * sin(t * 5))
        }
    }
}

/// Three bars that move while Kalypso speaks or listens.
struct KalypsoWelle: View {
    let aktiv: Bool
    var body: some View {
        TimelineView(.animation(paused: !aktiv)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3) { i in
                    Capsule().fill(KalypsoLiveActivity.meer)
                        .frame(width: 3, height: aktiv ? 4 + 8 * abs(sin(t * 6 + Double(i) * 1.1)) : 4)
                }
            }
        }
    }
}
