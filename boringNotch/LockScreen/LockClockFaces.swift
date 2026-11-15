//
//  LockClockFaces.swift
//  boringNotch
//
//  The clock's other faces: hands, bare digits, and the time in words.
//

import SwiftUI

enum LockClockFace: String, CaseIterable, Identifiable {
    case digital, analog, minimal, words
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .digital: "Digital"
        case .analog: "Analog"
        case .minimal: "Minimal"
        case .words: "In words"
        }
    }
}

struct LockAnalogClock: View {
    @Environment(\.lockStyle) private var style

    var body: some View {
        LockTick(every: 1) { date in
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let seconds = Double(parts.second ?? 0)
            let minutes = Double(parts.minute ?? 0) + seconds / 60
            let hours = Double((parts.hour ?? 0) % 12) + minutes / 60

            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                ZStack {
                    ForEach(0..<12, id: \.self) { tick in
                        Capsule()
                            .fill(.white.opacity(tick % 3 == 0 ? 0.9 : 0.4))
                            .frame(width: tick % 3 == 0 ? 3 : 2, height: side * (tick % 3 == 0 ? 0.09 : 0.055))
                            .offset(y: -side * 0.44)
                            .rotationEffect(.degrees(Double(tick) * 30))
                    }
                    hand(length: side * 0.26, width: 5, turn: hours / 12, color: .white)
                    hand(length: side * 0.39, width: 3.5, turn: minutes / 60, color: .white)
                    hand(length: side * 0.42, width: 1.5, turn: seconds / 60, color: secondHand)
                    Circle()
                        .fill(secondHand)
                        .frame(width: 8, height: 8)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private var secondHand: Color {
        style.accent == .white ? Color(red: 1, green: 0.6, blue: 0.25) : style.accent.color
    }

    private func hand(length: CGFloat, width: CGFloat, turn: Double, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(turn * 360))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

struct LockMinimalClock: View {
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        LockTick(every: 60) { date in
            let digits = size == .small || size == .large ? 64.0 : 84.0
            let layout = size == .small || size == .large ? AnyLayout(VStackLayout(spacing: -digits * 0.2)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Text(Self.hour(date))
                    .font(style.font(size == .large ? 130 : digits, .thin))
                Text(Self.minute(date))
                    .font(style.font(size == .large ? 130 : digits, .thin))
                    .foregroundStyle(style.accent.color.opacity(style.accent == .white ? 0.55 : 1))
            }
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
        }
    }

    /// Bare digits. The system's hour format adds "Uhr" in German.
    private static func hour(_ date: Date) -> String {
        String(format: "%02d", Calendar.current.component(.hour, from: date))
    }

    private static func minute(_ date: Date) -> String {
        String(format: "%02d", Calendar.current.component(.minute, from: date))
    }
}

struct LockWordClock: View {
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        LockTick(every: 60) { date in
            let words = Self.words(for: date, german: Locale.current.language.languageCode?.identifier == "de")
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: words.lead)
                    .foregroundStyle(style.accent.color.opacity(style.accent == .white ? 0.55 : 1))
                Text(verbatim: words.time)
            }
            .font(style.font(size == .small ? 22 : size == .large ? 44 : 30, .bold))
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// The time to the nearest five minutes, the way people say it.
    static func words(for date: Date, german: Bool) -> (lead: String, time: String) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        var hour = parts.hour ?? 0
        var step = ((parts.minute ?? 0) + 2) / 5
        if step == 12 {
            step = 0
            hour += 1
        }

        if german {
            let names = ["zwölf", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf"]
            let this = names[hour % 12]
            let next = names[(hour + 1) % 12]
            let time: String
            switch step {
            case 0: time = "\(hour % 12 == 1 ? "ein" : this) Uhr"
            case 1: time = "fünf nach \(this)"
            case 2: time = "zehn nach \(this)"
            case 3: time = "Viertel nach \(this)"
            case 4: time = "zwanzig nach \(this)"
            case 5: time = "fünf vor halb \(next)"
            case 6: time = "halb \(next)"
            case 7: time = "fünf nach halb \(next)"
            case 8: time = "zwanzig vor \(next)"
            case 9: time = "Viertel vor \(next)"
            case 10: time = "zehn vor \(next)"
            default: time = "fünf vor \(next)"
            }
            return ("Es ist", time)
        }

        let names = ["twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven"]
        let this = names[hour % 12]
        let next = names[(hour + 1) % 12]
        let time: String
        switch step {
        case 0: time = "\(this) o'clock"
        case 1: time = "five past \(this)"
        case 2: time = "ten past \(this)"
        case 3: time = "quarter past \(this)"
        case 4: time = "twenty past \(this)"
        case 5: time = "twenty-five past \(this)"
        case 6: time = "half past \(this)"
        case 7: time = "twenty-five to \(next)"
        case 8: time = "twenty to \(next)"
        case 9: time = "quarter to \(next)"
        case 10: time = "ten to \(next)"
        default: time = "five to \(next)"
        }
        return ("It's", time)
    }
}
