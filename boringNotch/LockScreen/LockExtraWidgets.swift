//
//  LockExtraWidgets.swift
//  boringNotch
//
//  The widgets beyond the basics: notes, events, reminders, world clock, moon, sun, uptime, quote and Starlane.
//

import Defaults
import SwiftUI

// MARK: - Note

enum LockNoteColor: String, CaseIterable, Identifiable {
    case yellow, pink, blue, green, orange, purple
    var id: String { rawValue }

    var paper: Color {
        switch self {
        case .yellow: Color(red: 1, green: 0.9, blue: 0.45)
        case .pink: Color(red: 1, green: 0.72, blue: 0.82)
        case .blue: Color(red: 0.66, green: 0.84, blue: 1)
        case .green: Color(red: 0.7, green: 0.93, blue: 0.68)
        case .orange: Color(red: 1, green: 0.78, blue: 0.5)
        case .purple: Color(red: 0.84, green: 0.76, blue: 1)
        }
    }
}

struct LockNoteWidget: View {
    let widget: LockWidget
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        Text(verbatim: widget.text.isEmpty ? String(localized: "Write your note in Settings") : widget.text)
            .font(style.font(size == .small ? 16 : size == .large ? 24 : 19, .medium))
            .foregroundStyle(.black.opacity(widget.text.isEmpty ? 0.45 : 0.82))
            .multilineTextAlignment(.leading)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A sticky note's paper, in place of the glass.
struct LockNotePaper: View {
    let widget: LockWidget

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let color = (LockNoteColor(rawValue: widget.variant) ?? .yellow).paper
        shape
            .fill(color.opacity(0.55 + 0.4 * widget.style.opacity))
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(0.3), .clear, .black.opacity(0.08)], startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 7)
    }
}

// MARK: - Calendar and reminders

struct LockCalendarWidget: View {
    @ObservedObject private var source = LockEvents.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        if !source.canReadEvents {
            LockWidgetHint(symbol: "calendar.badge.exclamationmark", text: Text("Allow calendar access in Settings"))
        } else {
            VStack(alignment: .leading, spacing: 7) {
                LockCaption(text: Text("Next up"), symbol: "calendar")
                if source.events.isEmpty {
                    Spacer(minLength: 0)
                    Text("Nothing in the next two weeks")
                        .font(style.font(14, .medium))
                        .opacity(0.7)
                }
                ForEach(source.events.prefix(LockListRow.count(for: size))) { event in
                    LockListRow(color: event.color, title: event.title, detail: Self.when(event))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func when(_ event: LockEvent) -> String {
        let calendar = Calendar.current
        let dayText: String
        if calendar.isDateInToday(event.start) || calendar.isDateInTomorrow(event.start) {
            // "today" and "tomorrow" in the user's language
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.doesRelativeDateFormatting = true
            dayText = formatter.string(from: event.start)
        } else {
            dayText = event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return event.isAllDay ? dayText : "\(dayText), \(event.start.formatted(date: .omitted, time: .shortened))"
    }
}

struct LockRemindersWidget: View {
    @ObservedObject private var source = LockEvents.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        if !source.canReadReminders {
            LockWidgetHint(symbol: "checklist", text: Text("Allow reminders access in Settings"))
        } else {
            VStack(alignment: .leading, spacing: 7) {
                LockCaption(text: Text("Reminders"), symbol: "checklist")
                if source.reminders.isEmpty {
                    Spacer(minLength: 0)
                    Text("All done")
                        .font(style.font(14, .medium))
                        .opacity(0.7)
                }
                ForEach(source.reminders.prefix(LockListRow.count(for: size))) { reminder in
                    LockListRow(
                        color: reminder.color,
                        title: reminder.title,
                        detail: reminder.due.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) },
                        isRound: true
                    )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LockListRow: View {
    let color: Color
    let title: String
    let detail: String?
    var isRound = false
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    static func count(for size: LockWidgetSize) -> Int {
        switch size {
        case .small: 2
        case .medium, .wide: 3
        case .large: 7
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if isRound {
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 13, height: 13)
            } else {
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: size == .small || size == .large ? 30 : 22)
            }
            if size == .small || size == .large || isRound {
                VStack(alignment: .leading, spacing: 1) {
                    titleText
                    detailText
                }
            } else {
                titleText
                Spacer(minLength: 4)
                detailText
            }
        }
        .lineLimit(1)
    }

    private var titleText: some View {
        Text(verbatim: title)
            .font(style.font(14, .semibold))
    }

    @ViewBuilder
    private var detailText: some View {
        if let detail {
            Text(verbatim: detail)
                .font(style.font(12, .medium))
                .opacity(0.65)
        }
    }
}

// MARK: - World clock

struct LockWorldClockWidget: View {
    let widget: LockWidget
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    static let zones = [
        "Europe/Berlin", "Europe/London", "Europe/Istanbul", "Europe/Moscow", "Africa/Cairo", "Africa/Johannesburg",
        "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore", "Asia/Shanghai", "Asia/Seoul", "Asia/Tokyo",
        "Australia/Sydney", "Pacific/Auckland", "Pacific/Honolulu", "America/Los_Angeles", "America/Mexico_City",
        "America/Chicago", "America/New_York", "America/Toronto", "America/Sao_Paulo",
    ]

    static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    var body: some View {
        let zone = TimeZone(identifier: widget.text) ?? .current
        LockTick(every: 60) { date in
            let hours = (zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)) / 3600
            VStack(alignment: size == .small ? .center : .leading, spacing: 2) {
                LockCaption(text: Text(verbatim: Self.city(zone.identifier)), symbol: "globe")
                Text(date, format: Date.FormatStyle(timeZone: zone).hour().minute())
                    .font(style.font(size == .small ? 40 : size == .large ? 84 : 58, .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(verbatim: hours == 0 ? "±0 h" : "\(hours > 0 ? "+" : "−")\(abs(hours)) h")
                    .font(style.font(13, .medium))
                    .opacity(0.65)
            }
            .frame(maxWidth: .infinity, alignment: size == .small ? .center : .leading)
        }
    }
}

// MARK: - Moon

struct LockMoon {
    /// 0 at new moon, 0.5 at full moon
    let phase: Double

    init(at date: Date) {
        // A new moon on 6 January 2000, 18:14 UTC, and the mean length of a lunar month
        let knownNewMoon = Date(timeIntervalSince1970: 947_182_440)
        let month = 29.530588853 * 86400
        let cycles = date.timeIntervalSince(knownNewMoon) / month
        phase = cycles - cycles.rounded(.down)
    }

    var illumination: Double {
        (1 - cos(phase * 2 * .pi)) / 2
    }

    var daysToFull: Int {
        let ahead = phase <= 0.5 ? 0.5 - phase : 1.5 - phase
        return Int((ahead * 29.530588853).rounded())
    }

    private var step: Int {
        Int((phase * 8).rounded()) % 8
    }

    var symbol: String {
        [
            "moonphase.new.moon", "moonphase.waxing.crescent", "moonphase.first.quarter", "moonphase.waxing.gibbous",
            "moonphase.full.moon", "moonphase.waning.gibbous", "moonphase.last.quarter", "moonphase.waning.crescent",
        ][step]
    }

    var name: LocalizedStringResource {
        switch step {
        case 0: "New moon"
        case 1: "Waxing crescent"
        case 2: "First quarter"
        case 3: "Waxing gibbous"
        case 4: "Full moon"
        case 5: "Waning gibbous"
        case 6: "Last quarter"
        default: "Waning crescent"
        }
    }
}

struct LockMoonWidget: View {
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        LockTick(every: 60) { date in
            let moon = LockMoon(at: date)
            let symbol = Image(systemName: moon.symbol)
                .font(.system(size: size == .small ? 54 : size == .large ? 120 : 70))
                .foregroundStyle(style.accent == .white ? Color(red: 0.95, green: 0.93, blue: 0.82) : style.accent.color)
            let texts = VStack(alignment: size == .small || size == .large ? .center : .leading, spacing: 4) {
                Text(moon.name)
                    .font(style.font(size == .small ? 14 : 19, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if size != .small {
                    Text("\(Int((moon.illumination * 100).rounded())) % lit")
                        .font(style.font(14, .medium))
                        .opacity(0.75)
                    Text(moon.daysToFull == 0 ? "Full moon today" : moon.daysToFull == 1 ? "Full moon tomorrow" : "Full moon in \(moon.daysToFull) days")
                        .font(style.font(13, .medium))
                        .opacity(0.6)
                }
            }
            if size == .small || size == .large {
                VStack(spacing: 10) {
                    symbol
                    texts
                }
            } else {
                HStack(spacing: 18) {
                    symbol
                    texts
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Sun

struct LockSunWidget: View {
    @Default(.lockScreenWeather) private var weather
    @Default(.lockScreenWeatherPlace) private var place
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        if let sunrise = weather?.sunrise, let sunset = weather?.sunset {
            let rise = time("sunrise.fill", sunrise)
            let set = time("sunset.fill", sunset)
            if size == .small {
                VStack(alignment: .leading, spacing: 12) {
                    rise
                    set
                }
            } else {
                VStack(spacing: 10) {
                    LockTick(every: 60) { now in
                        LockSunArc(progress: now.timeIntervalSince(sunrise) / max(sunset.timeIntervalSince(sunrise), 1), color: tint)
                    }
                    HStack {
                        rise
                        Spacer()
                        set
                    }
                }
            }
        } else {
            LockWidgetHint(
                symbol: "sun.horizon",
                text: place == nil ? Text("Choose a place in Settings") : Text("Waiting for the weather")
            )
        }
    }

    private var tint: Color {
        style.accent == .white ? Color(red: 1, green: 0.8, blue: 0.3) : style.accent.color
    }

    private func time(_ symbol: String, _ date: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 20))
            Text(date, format: .dateTime.hour().minute())
                .font(style.font(22, .semibold))
                .monospacedDigit()
        }
    }
}

/// The sun's way over the day as a half circle, with a dot where it is now.
private struct LockSunArc: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width / 2, proxy.size.height) - 8
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height - 2)
            let clamped = min(max(progress, 0), 1)
            let angle = Double.pi * (1 - clamped)
            ZStack {
                Path { path in
                    path.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                }
                .stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [3, 5]))
                Path { path in
                    path.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * clamped), clockwise: false)
                }
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                if progress >= 0 && progress <= 1 {
                    Circle()
                        .fill(color)
                        .frame(width: 13, height: 13)
                        .shadow(color: color.opacity(0.8), radius: 6)
                        .position(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
                }
            }
        }
    }
}

// MARK: - Uptime

struct LockUptimeWidget: View {
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    private static let bootTime: Date? = {
        var boot = timeval()
        var length = MemoryLayout<timeval>.stride
        var name = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, 2, &boot, &length, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }()

    var body: some View {
        LockTick(every: 60) { now in
            let seconds = Self.bootTime.map { now.timeIntervalSince($0) } ?? ProcessInfo.processInfo.systemUptime
            VStack(alignment: size == .small ? .center : .leading, spacing: 4) {
                LockCaption(text: Text("Mac on for"), symbol: "power")
                Text(
                    Duration.seconds(seconds),
                    format: .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)
                )
                .font(style.font(size == .small ? 30 : size == .large ? 64 : 46, .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                if size != .small, let boot = Self.bootTime {
                    Text("Started \(boot.formatted(.dateTime.weekday(.wide).hour().minute()))")
                        .font(style.font(13, .medium))
                        .opacity(0.65)
                }
            }
            .frame(maxWidth: .infinity, alignment: size == .small ? .center : .leading)
        }
    }
}

// MARK: - Quote

struct LockQuoteWidget: View {
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    /// German, English, author
    private static let quotes: [(String, String, String)] = [
        ("Nicht weil es schwer ist, wagen wir es nicht, sondern weil wir es nicht wagen, ist es schwer.",
         "It is not because things are difficult that we do not dare; it is because we do not dare that they are difficult.", "Seneca"),
        ("Der Anfang ist die Hälfte des Ganzen.", "Well begun is half done.", "Aristoteles"),
        ("Man braucht nichts im Leben zu fürchten, man muss nur alles verstehen.",
         "Nothing in life is to be feared, it is only to be understood.", "Marie Curie"),
        ("Es ist nicht genug zu wissen, man muss auch anwenden; es ist nicht genug zu wollen, man muss auch tun.",
         "Knowing is not enough; we must apply. Willing is not enough; we must do.", "Johann Wolfgang von Goethe"),
        ("Auch eine Reise von tausend Meilen beginnt mit dem ersten Schritt.",
         "A journey of a thousand miles begins with a single step.", "Laotse"),
        ("Habe Mut, dich deines eigenen Verstandes zu bedienen.", "Have courage to use your own understanding.", "Immanuel Kant"),
        ("Das Glück deines Lebens hängt von der Beschaffenheit deiner Gedanken ab.",
         "The happiness of your life depends upon the quality of your thoughts.", "Mark Aurel"),
        ("Nicht die Dinge selbst beunruhigen die Menschen, sondern ihre Meinungen über die Dinge.",
         "It is not things that disturb us, but our opinions about them.", "Epiktet"),
        ("Es gibt nichts Gutes, außer: Man tut es.", "There is nothing good unless you do it.", "Erich Kästner"),
        ("Wer ein Warum zu leben hat, erträgt fast jedes Wie.", "He who has a why to live can bear almost any how.", "Friedrich Nietzsche"),
        ("Ich weiß, dass ich nichts weiß.", "I know that I know nothing.", "Sokrates"),
        ("Es ist nicht wenig Zeit, die wir haben, sondern es ist viel Zeit, die wir nicht nutzen.",
         "It is not that we have a short time to live, but that we waste a lot of it.", "Seneca"),
        ("Eine Investition in Wissen bringt immer noch die besten Zinsen.",
         "An investment in knowledge pays the best interest.", "Benjamin Franklin"),
        ("Jedem Anfang wohnt ein Zauber inne.", "In every beginning dwells a magic.", "Hermann Hesse"),
        ("Wer nichts waget, der darf nichts hoffen.", "He who dares nothing need hope for nothing.", "Friedrich Schiller"),
        ("Nutze den Tag.", "Seize the day.", "Horaz"),
    ]

    var body: some View {
        LockTick(every: 60) { date in
            let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
            let quote = Self.quotes[day % Self.quotes.count]
            let isGerman = Locale.current.language.languageCode?.identifier == "de"
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(style.accent.color.opacity(0.8))
                Text(verbatim: isGerman ? quote.0 : quote.1)
                    .font(style.font(size == .small ? 14 : size == .large ? 24 : 18, .semibold))
                    .minimumScaleFactor(0.55)
                Spacer(minLength: 0)
                Text(verbatim: quote.2)
                    .font(style.font(12, .medium))
                    .opacity(0.65)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Starlane

struct LockStarlaneWidget: View {
    @ObservedObject private var starlane = StarlaneManager.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        if let summary = starlane.summary, starlane.status == .connected {
            VStack(alignment: .leading, spacing: 6) {
                LockCaption(text: Text(verbatim: "Starlane"), symbol: "sparkles")
                Spacer(minLength: 0)
                if size == .small {
                    count(summary.needs, Text("need you"), isLoud: summary.needs > 0)
                } else {
                    HStack(alignment: .bottom, spacing: 22) {
                        count(summary.needs, Text("need you"), isLoud: summary.needs > 0)
                        count(summary.busy, Text("working"), isLoud: false)
                        if size != .medium {
                            count(summary.paused, Text("paused"), isLoud: false)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LockWidgetHint(symbol: "sparkles", text: Text("Starlane isn't reachable"))
        }
    }

    private func count(_ value: Int, _ label: Text, isLoud: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(value)")
                .font(style.font(size == .large ? 64 : 46, .semibold))
                .monospacedDigit()
                .foregroundStyle(isLoud ? Color(red: 1, green: 0.66, blue: 0.3) : .white)
            label
                .font(style.font(13, .medium))
                .opacity(0.7)
        }
        .lineLimit(1)
    }
}
