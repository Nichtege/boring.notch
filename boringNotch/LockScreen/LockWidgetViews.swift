//
//  LockWidgetViews.swift
//  boringNotch
//
//  The widgets themselves. Each one is drawn the same on the lock screen and in the settings preview.
//

import Defaults
import SwiftUI

struct LockWidgetView: View {
    let widget: LockWidget
    /// In the settings every widget shows, so it can be picked up and moved
    var isPreview = false
    @ObservedObject private var lyrics = LyricsManager.shared
    @Default(.lockScreenMotion) private var motion
    @Default(.lockScreenLight) private var light

    /// Lyrics leave the lock screen entirely for a song without synced ones.
    private var isHidden: Bool {
        widget.kind == .lyrics && !isPreview && lyrics.lines.isEmpty
    }

    private var isBare: Bool {
        widget.style.glass == .bare && widget.kind != .note
    }

    var body: some View {
        content
            .padding(widget.kind.fillsItsFrame ? 0 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            // Clear glass over a bright picture leaves white type with nothing to stand on, and no glass even less
            .shadow(color: .black.opacity(widget.kind == .note ? 0 : isBare ? 0.5 : 0.28), radius: isBare ? 5 : 3, y: 1)
            .background {
                if widget.kind == .note {
                    LockNotePaper(widget: widget)
                } else {
                    LockGlassBackground(style: widget.style, isPreview: isPreview)
                }
            }
            .overlay {
                if light && widget.kind != .note && !isBare {
                    LockLightSweep(column: widget.column)
                }
            }
            .environment(\.lockStyle, widget.style)
            .environment(\.lockSize, widget.size)
            .environment(\.lockMotion, motion)
            .opacity(isHidden ? 0 : 1)
            .animation(.smooth(duration: 0.4), value: isHidden)
    }

    @ViewBuilder
    private var content: some View {
        switch widget.kind {
        case .clock: LockClockWidget(widget: widget)
        case .date: LockDateWidget()
        case .battery: LockBatteryWidget()
        case .weather: LockWeatherWidget()
        case .countdown: LockCountdownWidget(widget: widget)
        case .system: LockSystemWidget()
        case .music: LockMusicWidget()
        case .lyrics: LockLyricsWidget()
        case .note: LockNoteWidget(widget: widget)
        case .calendar: LockCalendarWidget()
        case .reminders: LockRemindersWidget()
        case .worldClock: LockWorldClockWidget(widget: widget)
        case .moon: LockMoonWidget()
        case .sun: LockSunWidget()
        case .uptime: LockUptimeWidget()
        case .quote: LockQuoteWidget()
        case .starlane: LockStarlaneWidget()
        case .atlas: LockAtlasWidget(widget: widget)
        case .limits: LockLimitsWidget()
        case .deadline: LockDeadlineWidget()
        }
    }
}

extension LockWidgetKind {
    /// Draws up to its own edge instead of sitting inside the usual padding.
    var fillsItsFrame: Bool { self == .music }
}

// MARK: - Clock

struct LockClockWidget: View {
    let widget: LockWidget
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        switch LockClockFace(rawValue: widget.variant) ?? .digital {
        case .digital: digital
        case .analog: LockAnalogClock()
        case .minimal: LockMinimalClock()
        case .words: LockWordClock()
        }
    }

    private var digital: some View {
        LockTick(every: size == .wide ? 1 : 60) { date in
            VStack(spacing: 2) {
                Text(date, format: size == .wide ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                    .font(style.font(size == .small ? 46 : size == .large ? 96 : 68, .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if size != .small {
                    Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(style.font(size == .large ? 20 : 15, .medium))
                        .foregroundStyle(style.accent.color.opacity(0.85))
                }
            }
        }
    }
}

// MARK: - Date

struct LockDateWidget: View {
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        LockTick(every: 60) { date in
            if size == .small {
                day(date)
            } else {
                HStack(spacing: 18) {
                    day(date)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(date, format: .dateTime.weekday(.wide))
                            .font(style.font(22, .semibold))
                        Text(date, format: .dateTime.day().month(.wide).year())
                            .font(style.font(15, .medium))
                            .opacity(0.8)
                        Text("Week \(Calendar.current.component(.weekOfYear, from: date))")
                            .font(style.font(13, .medium))
                            .opacity(0.6)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func day(_ date: Date) -> some View {
        VStack(spacing: 0) {
            Text(date, format: .dateTime.weekday(.abbreviated))
                .font(style.font(15, .bold))
                .textCase(.uppercase)
                .foregroundStyle(style.accent == .white ? Color(red: 1, green: 0.45, blue: 0.4) : style.accent.color)
            Text(date, format: .dateTime.day())
                .font(style.font(62, .semibold))
            Text(date, format: .dateTime.month(.wide))
                .font(style.font(14, .medium))
                .opacity(0.75)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

// MARK: - Battery

struct LockBatteryWidget: View {
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    private var level: Double { Double(battery.levelBattery) / 100 }

    private var color: Color {
        if battery.isInLowPowerMode { return Color(red: 1, green: 0.8, blue: 0.2) }
        if level <= 0.2 && !battery.isCharging { return Color(red: 1, green: 0.4, blue: 0.35) }
        return style.accent == .white ? Color(red: 0.4, green: 0.9, blue: 0.5) : style.accent.color
    }

    private var status: LocalizedStringResource {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return "Plugged in" }
        if battery.isInLowPowerMode { return "Low Power Mode" }
        return "On battery"
    }

    var body: some View {
        if size == .small {
            ring
        } else {
            HStack(spacing: 18) {
                ring
                VStack(alignment: .leading, spacing: 6) {
                    LockCaption(text: Text("Battery"), symbol: "macbook")
                    Text(status)
                        .font(style.font(20, .semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var ring: some View {
        ZStack {
            LockRing(value: level, color: color, lineWidth: 9)
            VStack(spacing: 0) {
                if battery.isCharging || battery.isPluggedIn {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(color)
                }
                Text("\(Int(battery.levelBattery.rounded()))")
                    .font(style.font(40, .semibold))
                    .monospacedDigit()
                Text(verbatim: "%")
                    .font(style.font(12, .semibold))
                    .opacity(0.6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(4)
    }
}

// MARK: - Weather

struct LockWeatherWidget: View {
    @Default(.lockScreenWeather) private var weather
    @Default(.lockScreenWeatherPlace) private var place
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        if let weather, let place {
            if size == .small {
                VStack(alignment: .leading, spacing: 4) {
                    LockCaption(text: Text(verbatim: place.name), symbol: "location.fill")
                    Spacer(minLength: 0)
                    Image(systemName: weather.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 26))
                    Text(Self.degrees(weather.temperature))
                        .font(style.font(40, .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        LockCaption(text: Text(verbatim: place.name), symbol: "location.fill")
                        Text(Self.degrees(weather.temperature))
                            .font(style.font(size == .large ? 84 : 58, .semibold))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Image(systemName: weather.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: size == .large ? 54 : 34))
                        Text(weather.summary)
                            .font(style.font(15, .semibold))
                        Text(verbatim: "↑ \(Self.degrees(weather.high))  ↓ \(Self.degrees(weather.low))")
                            .font(style.font(13, .medium))
                            .opacity(0.7)
                    }
                    .lineLimit(1)
                }
            }
        } else {
            LockWidgetHint(
                symbol: "cloud.sun",
                text: place == nil ? Text("Choose a place in Settings") : Text("Waiting for the weather")
            )
        }
    }

    static func degrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }
}

/// What a widget shows while it has nothing to show.
struct LockWidgetHint: View {
    let symbol: String
    let text: Text
    @Environment(\.lockStyle) private var style

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
            text
                .font(style.font(13, .medium))
                .multilineTextAlignment(.center)
        }
        .opacity(0.7)
    }
}

// MARK: - Countdown

struct LockCountdownWidget: View {
    let widget: LockWidget
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    var body: some View {
        LockTick(every: 60) { now in
            let days = Self.days(from: now, to: widget.date)
            let number = Text("\(abs(days))")
                .font(style.font(size == .small ? 54 : size == .large ? 110 : 68, .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            let unit = (days == 0 ? Text("Today") : days == 1 ? Text("day to go") : days > 0 ? Text("days to go") : days == -1 ? Text("day ago") : Text("days ago"))
                .font(style.font(14, .medium))
                .foregroundStyle(.white.opacity(0.7))
            let title = LockCaption(
                text: Text(verbatim: widget.text.isEmpty ? String(localized: "Countdown") : widget.text),
                symbol: "hourglass"
            )

            if size == .small || size == .large {
                VStack(spacing: 2) {
                    title
                    Spacer(minLength: 0)
                    number
                    unit
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 16) {
                    number
                    VStack(alignment: .leading, spacing: 6) {
                        title
                        unit
                        Text(widget.date, format: .dateTime.day().month(.wide).year())
                            .font(style.font(13, .medium))
                            .opacity(0.55)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    static func days(from now: Date, to date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
}

// MARK: - System

struct LockSystemWidget: View {
    @ObservedObject private var stats = LockSystemStats.shared
    @Environment(\.lockStyle) private var style
    @Environment(\.lockSize) private var size

    private var gauges: [(name: String, value: Double, color: Color)] {
        [
            ("CPU", stats.cpu, Color(red: 0.42, green: 0.72, blue: 1)),
            ("RAM", stats.memory, Color(red: 0.45, green: 0.9, blue: 0.6)),
            ("SSD", stats.disk, Color(red: 1, green: 0.66, blue: 0.3)),
        ]
    }

    var body: some View {
        if size == .small {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(gauges, id: \.name) { gauge in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: gauge.name)
                            Spacer()
                            Text(verbatim: "\(Int((gauge.value * 100).rounded())) %")
                                .monospacedDigit()
                                .opacity(0.7)
                        }
                        .font(style.font(12, .semibold))
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .frame(height: 6)
                            .overlay(alignment: .leading) {
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(tint(gauge.color))
                                        .frame(width: proxy.size.width * min(max(gauge.value, 0), 1))
                                }
                            }
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: size == .large ? 18 : 22) {
                    ForEach(gauges, id: \.name) { gauge in
                        ZStack {
                            LockRing(value: gauge.value, color: tint(gauge.color), lineWidth: 8)
                            VStack(spacing: 0) {
                                Text(verbatim: "\(Int((gauge.value * 100).rounded()))")
                                    .font(style.font(24, .semibold))
                                    .monospacedDigit()
                                Text(verbatim: gauge.name)
                                    .font(style.font(11, .semibold))
                                    .opacity(0.65)
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                    }
                }
                if size == .large {
                    Text("\(stats.diskFree.formatted(.byteCount(style: .file))) free")
                        .font(style.font(15, .medium))
                        .opacity(0.7)
                }
            }
            .padding(4)
        }
    }

    private func tint(_ own: Color) -> Color {
        style.accent == .white ? own : style.accent.color
    }
}
