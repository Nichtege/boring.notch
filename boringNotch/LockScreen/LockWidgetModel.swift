//
//  LockWidgetModel.swift
//  boringNotch
//
//  What a lock screen layout is made of: widgets on a grid, grouped into profiles.
//

import Defaults
import SwiftUI

enum LockWidgetKind: String, Codable, CaseIterable, Identifiable {
    case clock, date, battery, weather, countdown, system
    case music, lyrics
    case note, calendar, reminders, worldClock, moon, sun, uptime, quote, starlane

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .clock: "Clock"
        case .date: "Date"
        case .battery: "Battery"
        case .weather: "Weather"
        case .countdown: "Countdown"
        case .system: "System"
        case .music: "Music"
        case .lyrics: "Live lyrics"
        case .note: "Note"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .worldClock: "World clock"
        case .moon: "Moon phase"
        case .sun: "Sunrise and sunset"
        case .uptime: "Uptime"
        case .quote: "Quote of the day"
        case .starlane: "Starlane"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .date: "calendar"
        case .battery: "battery.75percent"
        case .weather: "cloud.sun"
        case .countdown: "hourglass"
        case .system: "cpu"
        case .music: "music.note"
        case .lyrics: "quote.bubble"
        case .note: "note.text"
        case .calendar: "calendar.day.timeline.left"
        case .reminders: "checklist"
        case .worldClock: "globe"
        case .moon: "moon.stars"
        case .sun: "sun.horizon"
        case .uptime: "power"
        case .quote: "quote.opening"
        case .starlane: "sparkles"
        }
    }

    var defaultSize: LockWidgetSize {
        switch self {
        case .clock, .weather, .countdown, .system, .music, .lyrics, .calendar, .reminders, .sun, .quote, .starlane: .medium
        case .date, .battery, .note, .worldClock, .moon, .uptime: .small
        }
    }

    /// Only these get clicks. The rest let them through to the lock screen.
    var takesClicks: Bool { self == .music }
}

enum LockWidgetSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large, wide

    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .small: 2
        case .medium, .large: 4
        case .wide: 6
        }
    }

    var rows: Int {
        self == .large ? 4 : 2
    }

    var title: LocalizedStringResource {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .wide: "Wide"
        }
    }
}

enum LockGlass: String, Codable, CaseIterable, Identifiable {
    /// See-through, bending what's behind them at the rim. `frosted` blurs it as well.
    case liquid, liquidDark, frosted
    /// Only drawn, with no view of what's behind
    case clear
    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .liquid: "Liquid Glass"
        case .liquidDark: "Liquid Glass, smoked"
        case .frosted: "Frosted"
        case .clear: "Simple"
        }
    }
}

enum LockAccent: String, Codable, CaseIterable, Identifiable {
    case white, blue, green, orange, pink, purple, yellow
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .white: .white
        case .blue: Color(red: 0.42, green: 0.72, blue: 1)
        case .green: Color(red: 0.45, green: 0.9, blue: 0.6)
        case .orange: Color(red: 1, green: 0.66, blue: 0.3)
        case .pink: Color(red: 1, green: 0.5, blue: 0.7)
        case .purple: Color(red: 0.74, green: 0.6, blue: 1)
        case .yellow: Color(red: 1, green: 0.86, blue: 0.35)
        }
    }
}

enum LockFont: String, Codable, CaseIterable, Identifiable {
    case rounded, standard, serif, mono
    var id: String { rawValue }

    var design: Font.Design {
        switch self {
        case .rounded: .rounded
        case .standard: .default
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}

struct LockWidgetStyle: Codable, Equatable {
    var glass: LockGlass = .liquid
    var accent: LockAccent = .white
    var font: LockFont = .rounded
    var opacity: Double = 1

    init() {}

    // Fields added later must not throw away a saved layout
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        glass = (try? values.decode(LockGlass.self, forKey: .glass)) ?? .liquid
        accent = (try? values.decode(LockAccent.self, forKey: .accent)) ?? .white
        font = (try? values.decode(LockFont.self, forKey: .font)) ?? .rounded
        opacity = (try? values.decode(Double.self, forKey: .opacity)) ?? 1
    }
}

struct LockWidget: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: LockWidgetKind
    var size: LockWidgetSize
    var column: Int
    var row: Int
    var style = LockWidgetStyle()
    /// The countdown's title, the note's text or the world clock's time zone
    var text = ""
    /// The countdown's day
    var date = Date()
    /// The clock's face or the note's colour
    var variant = ""

    init(_ kind: LockWidgetKind, size: LockWidgetSize? = nil, column: Int, row: Int, text: String = "", date: Date = Date()) {
        self.kind = kind
        self.size = size ?? kind.defaultSize
        self.column = column
        self.row = row
        self.text = text
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(LockWidgetKind.self, forKey: .kind)
        size = try values.decode(LockWidgetSize.self, forKey: .size)
        column = try values.decode(Int.self, forKey: .column)
        row = try values.decode(Int.self, forKey: .row)
        style = (try? values.decode(LockWidgetStyle.self, forKey: .style)) ?? LockWidgetStyle()
        text = (try? values.decode(String.self, forKey: .text)) ?? ""
        date = (try? values.decode(Date.self, forKey: .date)) ?? Date()
        variant = (try? values.decode(String.self, forKey: .variant)) ?? ""
    }
}

struct LockProfile: Codable, Equatable, Identifiable, Defaults.Serializable {
    var id = UUID()
    var name: String
    var widgets: [LockWidget]

    /// Left and right of the middle, which the lock screen's own clock and login keep.
    static var standard: LockProfile {
        let newYear = Calendar.current.date(
            from: DateComponents(year: Calendar.current.component(.year, from: Date()) + 1, month: 1, day: 1)
        ) ?? Date()
        return LockProfile(
            name: String(localized: "Standard"),
            widgets: [
                LockWidget(.date, column: 0, row: 2),
                LockWidget(.battery, column: 2, row: 2),
                LockWidget(.weather, column: 0, row: 4),
                LockWidget(.countdown, column: 12, row: 2, text: String(localized: "New Year"), date: newYear),
                LockWidget(.system, column: 12, row: 4),
            ]
        )
    }
}

extension Defaults.Keys {
    static let lockScreenWidgets = Key<Bool>("lockScreenWidgets", default: true)
    static let lockScreenProfiles = Key<[LockProfile]>("lockScreenProfiles", default: [LockProfile.standard])
    static let lockScreenActiveProfile = Key<String>("lockScreenActiveProfile", default: "")
    /// Empty means the main display
    static let lockScreenDisplay = Key<String>("lockScreenDisplay", default: "")
    static let lockScreenWeatherPlace = Key<LockWeatherPlace?>("lockScreenWeatherPlace", default: nil)
    static let lockScreenWeather = Key<LockWeatherData?>("lockScreenWeather", default: nil)
    static let lyricsInNotch = Key<Bool>("lyricsInNotch", default: false)
    /// The cover's colours drifting behind the music widget
    static let lockScreenMotion = Key<Bool>("lockScreenMotion", default: true)
    /// A band of light wandering over the glass
    static let lockScreenLight = Key<Bool>("lockScreenLight", default: false)
}

enum LockProfiles {
    /// The chosen profile, or the first when the chosen one is gone.
    static var active: LockProfile {
        let profiles = Defaults[.lockScreenProfiles]
        return profiles.first { $0.id.uuidString == Defaults[.lockScreenActiveProfile] }
            ?? profiles.first
            ?? LockProfile.standard
    }
}

/// The grid on one screen, in points from the screen's top left.
struct LockGrid {
    static let columns = 16
    static let margin: CGFloat = 24
    static let gap: CGFloat = 12

    let cell: CGFloat
    let rows: Int
    private let origin: CGPoint

    init(screenSize: CGSize) {
        cell = floor((screenSize.width - Self.margin * 2) / CGFloat(Self.columns))
        rows = max(2, Int((screenSize.height - Self.margin * 2) / cell))
        origin = CGPoint(
            x: (screenSize.width - cell * CGFloat(Self.columns)) / 2,
            y: (screenSize.height - cell * CGFloat(rows)) / 2
        )
    }

    /// Brought back inside the grid, as a layout may come from a larger screen.
    func cellPosition(of widget: LockWidget) -> (column: Int, row: Int) {
        clamped(column: widget.column, row: widget.row, size: widget.size)
    }

    func clamped(column: Int, row: Int, size: LockWidgetSize) -> (column: Int, row: Int) {
        (
            min(max(0, column), Self.columns - size.columns),
            min(max(0, row), max(0, rows - size.rows))
        )
    }

    func frame(of widget: LockWidget) -> CGRect {
        let position = cellPosition(of: widget)
        return CGRect(
            x: origin.x + CGFloat(position.column) * cell,
            y: origin.y + CGFloat(position.row) * cell,
            width: CGFloat(widget.size.columns) * cell,
            height: CGFloat(widget.size.rows) * cell
        ).insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
    }

    func overlaps(_ widget: LockWidget, in widgets: [LockWidget]) -> Bool {
        let own = cells(of: widget)
        return widgets.contains { $0.id != widget.id && cells(of: $0).intersects(own) }
    }

    /// The first spot from the top left where the widget covers no other.
    func freeSpot(for widget: LockWidget, in widgets: [LockWidget]) -> (column: Int, row: Int)? {
        var candidate = widget
        for row in 0...max(0, rows - widget.size.rows) {
            for column in 0...(Self.columns - widget.size.columns) {
                candidate.column = column
                candidate.row = row
                if !overlaps(candidate, in: widgets) {
                    return (column, row)
                }
            }
        }
        return nil
    }

    private func cells(of widget: LockWidget) -> CGRect {
        let position = cellPosition(of: widget)
        return CGRect(x: position.column, y: position.row, width: widget.size.columns, height: widget.size.rows)
    }
}
