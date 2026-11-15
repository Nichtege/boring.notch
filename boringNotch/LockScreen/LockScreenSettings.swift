//
//  LockScreenSettings.swift
//  boringNotch
//
//  The settings tab for the lock screen widgets, with a small screen to arrange them on.
//

import Defaults
import EventKit
import SwiftUI

struct LockScreenSettings: View {
    @Default(.lockScreenWidgets) private var isEnabled
    @Default(.lockScreenProfiles) private var profiles
    @Default(.lockScreenActiveProfile) private var activeProfile
    @Default(.lockScreenDisplay) private var display
    @Default(.lockScreenFullCover) private var coverTakesOver
    @Default(.lockScreenCoverLayout) private var coverLayout
    @Default(.lockScreenGlassBlur) private var glassBlur

    @State private var selection: UUID?
    @State private var noRoom = false
    @State private var canSeeWallpaper = LockWallpaperTone.shared.isAllowed
    @ObservedObject private var tone = LockWallpaperTone.shared
    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }

    private var profileIndex: Int {
        profiles.firstIndex { $0.id.uuidString == activeProfile } ?? 0
    }

    private var widgets: Binding<[LockWidget]> {
        Binding {
            profiles.indices.contains(profileIndex) ? profiles[profileIndex].widgets : []
        } set: { newValue in
            if profiles.isEmpty {
                profiles = [LockProfile.standard]
            }
            profiles[profileIndex].widgets = newValue
        }
    }

    private var screenSize: CGSize {
        let screen = NSScreen.screens.first { !display.isEmpty && $0.displayUUID == display } ?? NSScreen.screens.first
        return screen?.frame.size ?? CGSize(width: 1470, height: 956)
    }

    private var grid: LockGrid {
        LockGrid(screenSize: screenSize)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .lockScreenWidgets) {
                    Text("Show widgets on the lock screen")
                }
                Picker("Display", selection: $display) {
                    Text("Main display").tag("")
                    ForEach(screens, id: \.uuid) { screen in
                        Text(screen.name).tag(screen.uuid)
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("Drawing above the lock screen uses private parts of macOS and may stop working after a system update.")
            }

            Section {
                Defaults.Toggle(key: .lockScreenFullCover) {
                    Text("The cover takes over while music plays")
                }
                Picker("Arrangement", selection: $coverLayout) {
                    Text("Cover in the middle").tag(LockCoverLayout.center)
                    Text("Cover on the left, live lyrics on the right").tag(LockCoverLayout.side)
                }
                .disabled(!coverTakesOver)
            } header: {
                Text("Music")
            } footer: {
                Text("The cover fills the screen as a soft backdrop, with the sharp cover, the song and the buttons on top. It hides the lock screen's own clock and shows one instead, and it hides the music and lyrics widgets while it's there. With lyrics on the right, the cover stays in the middle for songs without synced lyrics.")
            }

            Section {
                Picker("Profile", selection: Binding {
                    profiles.indices.contains(profileIndex) ? profiles[profileIndex].id.uuidString : ""
                } set: { newValue in
                    activeProfile = newValue
                    selection = nil
                }) {
                    ForEach(profiles) { profile in
                        Text(verbatim: profile.name).tag(profile.id.uuidString)
                    }
                }
                if profiles.indices.contains(profileIndex) {
                    TextField("Name", text: $profiles[profileIndex].name)
                }
                HStack {
                    Button("New profile", action: addProfile)
                    Button("Delete profile", role: .destructive, action: deleteProfile)
                        .disabled(profiles.count < 2)
                    Spacer()
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Each profile has its own layout. A new one starts as a copy of the current one. Switch with a right-click on the notch.")
            }

            Section {
                LockLayoutEditor(widgets: widgets, selection: $selection, screenSize: screenSize)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                HStack {
                    Menu {
                        ForEach(LockWidgetKind.allCases) { kind in
                            Button {
                                add(kind)
                            } label: {
                                Label { Text(kind.title) } icon: { Image(systemName: kind.symbol) }
                            }
                        }
                    } label: {
                        Label("Add widget", systemImage: "plus")
                    }
                    .fixedSize()
                    if let selection, widgets.wrappedValue.contains(where: { $0.id == selection }) {
                        Button("Remove widget", role: .destructive) {
                            widgets.wrappedValue.removeAll { $0.id == selection }
                            self.selection = nil
                        }
                    }
                    if noRoom {
                        Text("No room left for this size")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Drag a widget to move it. Click one to change or remove it, or right-click it. The middle belongs to the lock screen's own clock and login.")
            }

            Section {
                Picker("Glass", selection: shared(\.glass)) {
                    if shared(\.glass).wrappedValue == nil {
                        Text("Mixed").tag(LockGlass?.none)
                    }
                    ForEach(LockGlass.allCases) { glass in
                        Text(glass.title).tag(LockGlass?.some(glass))
                    }
                }
                Picker("Accent", selection: shared(\.accent)) {
                    if shared(\.accent).wrappedValue == nil {
                        Text("Mixed").tag(LockAccent?.none)
                    }
                    ForEach(LockAccent.allCases) { accent in
                        Label {
                            Text(accent.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(accent.color)
                        }
                        .tag(LockAccent?.some(accent))
                    }
                }
                Picker("Font", selection: shared(\.font)) {
                    if shared(\.font).wrappedValue == nil {
                        Text("Mixed").tag(LockFont?.none)
                    }
                    ForEach(LockFont.allCases) { font in
                        Text(font.title).tag(LockFont?.some(font))
                    }
                }
                if tone.isWanted && !canSeeWallpaper {
                    LabeledContent("Wallpaper colour") {
                        Button("Allow Screen Recording") {
                            CGRequestScreenCaptureAccess()
                            canSeeWallpaper = tone.isAllowed
                        }
                    }
                }
            } header: {
                Text("All widgets")
            } footer: {
                Text("Changes every widget of this profile at once. Each one can still be set by itself below. To match the wallpaper, the app looks at the wallpaper's own window when the Mac locks or unlocks and keeps only its colour, which needs the Screen Recording permission.")
            }

            if let index = widgets.wrappedValue.firstIndex(where: { $0.id == selection }) {
                LockWidgetEditor(
                    widget: Binding {
                        widgets.wrappedValue.indices.contains(index) ? widgets.wrappedValue[index] : LockWidget(.clock, column: 0, row: 0)
                    } set: { newValue in
                        change(newValue, at: index)
                    },
                    remove: {
                        widgets.wrappedValue.remove(at: index)
                        selection = nil
                    }
                )
            }

            if widgets.wrappedValue.contains(where: { $0.kind.needsPlace }) {
                LockWeatherPlaceSection()
            }

            Section {
                LabeledContent("Blur behind the glass") {
                    Slider(value: $glassBlur, in: 0.5...14)
                }
            } header: {
                Text("Glass")
            } footer: {
                Text("For all widgets with Liquid Glass. It shows on the lock screen, not in the preview above.")
            }

            Section {
                Defaults.Toggle(key: .lockScreenMotion) {
                    Text("The cover moves behind the music")
                }
                Defaults.Toggle(key: .lockScreenGlassAlive) {
                    Text("Light on the glass follows the pointer")
                }
                Defaults.Toggle(key: .lockScreenLight) {
                    Text("Light wanders over the glass")
                }
            } header: {
                Text("Motion")
            } footer: {
                Text("All of it stops with Reduce Motion in System Settings, and while the screen is off. The widgets then also appear without fading.")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Lock Screen")
        .onAppear {
            LockScreenController.shared.isPreviewing = true
            canSeeWallpaper = tone.isAllowed
            tone.refresh()
        }
        .onDisappear { LockScreenController.shared.isPreviewing = false }
        .onChange(of: profiles) {
            LockScreenController.shared.layoutChanged()
            tone.refresh()
        }
        .onChange(of: activeProfile) { LockScreenController.shared.layoutChanged() }
    }

    private func addProfile() {
        var profile = profiles.indices.contains(profileIndex) ? profiles[profileIndex] : LockProfile.standard
        profile.id = UUID()
        profile.name = String(localized: "Profile \(profiles.count + 1)")
        profiles.append(profile)
        activeProfile = profile.id.uuidString
        selection = nil
    }

    private func deleteProfile() {
        guard profiles.count > 1, profiles.indices.contains(profileIndex) else { return }
        profiles.remove(at: profileIndex)
        activeProfile = profiles[0].id.uuidString
        selection = nil
    }

    /// One part of the look for all widgets, and empty where they differ.
    private func shared<Value: Hashable>(_ part: WritableKeyPath<LockWidgetStyle, Value>) -> Binding<Value?> {
        Binding {
            let values = Set(widgets.wrappedValue.map { $0.style[keyPath: part] })
            return values.count == 1 ? values.first : nil
        } set: { newValue in
            guard let newValue else { return }
            var all = widgets.wrappedValue
            for index in all.indices {
                all[index].style[keyPath: part] = newValue
            }
            widgets.wrappedValue = all
        }
    }

    private func add(_ kind: LockWidgetKind) {
        var widget = LockWidget(kind, column: 0, row: 0)
        // A look that all widgets share is the look the next one starts with
        if let glass = shared(\.glass).wrappedValue { widget.style.glass = glass }
        if let accent = shared(\.accent).wrappedValue { widget.style.accent = accent }
        if let font = shared(\.font).wrappedValue { widget.style.font = font }
        if kind == .worldClock {
            widget.text = "America/New_York"
        }
        guard let spot = grid.freeSpot(for: widget, in: widgets.wrappedValue) else {
            noRoom = true
            return
        }
        noRoom = false
        widget.column = spot.column
        widget.row = spot.row
        widgets.wrappedValue.append(widget)
        selection = widget.id
    }

    /// A widget that grew may no longer fit where it was, and then moves to the next free spot.
    private func change(_ widget: LockWidget, at index: Int) {
        var widget = widget
        let position = grid.cellPosition(of: widget)
        widget.column = position.column
        widget.row = position.row
        if grid.overlaps(widget, in: widgets.wrappedValue) {
            guard let spot = grid.freeSpot(for: widget, in: widgets.wrappedValue) else {
                noRoom = true
                return
            }
            widget.column = spot.column
            widget.row = spot.row
        }
        noRoom = false
        widgets.wrappedValue[index] = widget
    }
}

extension LockWidgetKind {
    /// Shows something that depends on where the Mac is.
    var needsPlace: Bool { self == .weather || self == .sun }
}

// MARK: - Arranging

/// The chosen screen in small, with the widgets as they will look.
private struct LockLayoutEditor: View {
    @Binding var widgets: [LockWidget]
    @Binding var selection: UUID?
    let screenSize: CGSize

    @State private var draggedID: UUID?
    @State private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / screenSize.width
            let grid = LockGrid(screenSize: screenSize)

            ZStack(alignment: .topLeading) {
                backdrop
                    .onTapGesture { selection = nil }

                ForEach(widgets) { widget in
                    let frame = grid.frame(of: widget)
                    let isDragged = draggedID == widget.id

                    LockWidgetView(widget: widget, isPreview: true)
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: frame.width * scale, height: frame.height * scale, alignment: .topLeading)
                        .allowsHitTesting(false)
                        .overlay {
                            RoundedRectangle(cornerRadius: 28 * scale, style: .continuous)
                                .strokeBorder(Color.effectiveAccent, lineWidth: selection == widget.id ? 2 : 0)
                        }
                        .overlay(alignment: .topLeading) {
                            if selection == widget.id {
                                Button {
                                    remove(widget)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 16))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .red)
                                }
                                .buttonStyle(.plain)
                                .offset(x: -5, y: -5)
                                .help("Remove widget")
                            }
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Remove widget", role: .destructive) {
                                remove(widget)
                            }
                        }
                        .offset(
                            x: frame.minX * scale + (isDragged ? dragTranslation.width : 0),
                            y: frame.minY * scale + (isDragged ? dragTranslation.height : 0)
                        )
                        .zIndex(isDragged ? 1 : 0)
                        .onTapGesture { selection = widget.id }
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    draggedID = widget.id
                                    selection = widget.id
                                    dragTranslation = value.translation
                                }
                                .onEnded { value in
                                    drop(widget, translation: value.translation, scale: scale, grid: grid)
                                }
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .aspectRatio(screenSize.width / screenSize.height, contentMode: .fit)
    }

    private func remove(_ widget: LockWidget) {
        widgets.removeAll { $0.id == widget.id }
        if selection == widget.id {
            selection = nil
        }
    }

    /// Snaps to the nearest cell, and goes back where it was when that spot is taken.
    private func drop(_ widget: LockWidget, translation: CGSize, scale: CGFloat, grid: LockGrid) {
        defer {
            withAnimation(.snappy(duration: 0.2)) {
                draggedID = nil
                dragTranslation = .zero
            }
        }
        guard let index = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        let start = grid.cellPosition(of: widget)
        let target = grid.clamped(
            column: start.column + Int((translation.width / scale / grid.cell).rounded()),
            row: start.row + Int((translation.height / scale / grid.cell).rounded()),
            size: widget.size
        )
        var moved = widget
        moved.column = target.column
        moved.row = target.row
        guard !grid.overlaps(moved, in: widgets) else { return }
        widgets[index] = moved
    }

    /// Stands in for the wallpaper, with the two things the lock screen itself puts there.
    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.2, blue: 0.42),
                    Color(red: 0.42, green: 0.24, blue: 0.5),
                    Color(red: 0.86, green: 0.48, blue: 0.4),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack {
                Text(Date(), format: .dateTime.hour().minute())
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .padding(.top, 14)
                Spacer()
                Circle()
                    .frame(width: 18, height: 18)
                    .padding(.bottom, 22)
            }
            .foregroundStyle(.white.opacity(0.25))
        }
    }
}

// MARK: - One widget

private struct LockWidgetEditor: View {
    @Binding var widget: LockWidget
    let remove: () -> Void

    var body: some View {
        Section {
            Picker("Size", selection: $widget.size) {
                ForEach(LockWidgetSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)

            switch widget.kind {
            case .countdown:
                TextField("Title", text: $widget.text, prompt: Text(verbatim: "Abi 2027"))
                DatePicker("Day", selection: $widget.date, displayedComponents: .date)
            case .clock:
                Picker("Face", selection: $widget.variant) {
                    ForEach(LockClockFace.allCases) { face in
                        Text(face.title).tag(face == .digital ? "" : face.rawValue)
                    }
                }
            case .note:
                TextField("Text", text: $widget.text, prompt: Text("What do you want to remember?"), axis: .vertical)
                    .lineLimit(2...6)
                Picker("Paper", selection: $widget.variant) {
                    ForEach(LockNoteColor.allCases) { color in
                        Text(color.title).tag(color == .yellow ? "" : color.rawValue)
                    }
                }
            case .worldClock:
                Picker("City", selection: $widget.text) {
                    ForEach(LockWorldClockWidget.zones, id: \.self) { zone in
                        Text(verbatim: LockWorldClockWidget.city(zone)).tag(zone)
                    }
                }
            case .atlas:
                TextField("Question", text: $widget.text, prompt: Text("What's on today?"), axis: .vertical)
                    .lineLimit(1...4)
                Text("With a question, the widget gets a button that sends it to Atlas, also while the Mac is locked. The widget shows Atlas's latest answer, so anyone who sees the lock screen can read it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .calendar:
                LockAccessRow(type: .event)
            case .reminders:
                LockAccessRow(type: .reminder)
            default:
                EmptyView()
            }

            if widget.kind != .note {
                Picker("Glass", selection: $widget.style.glass) {
                    ForEach(LockGlass.allCases) { glass in
                        Text(glass.title).tag(glass)
                    }
                }
                Picker("Accent", selection: $widget.style.accent) {
                    ForEach(LockAccent.allCases) { accent in
                        Label {
                            Text(accent.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(accent.color)
                        }
                        .tag(accent)
                    }
                }
            }
            Picker("Font", selection: $widget.style.font) {
                ForEach(LockFont.allCases) { font in
                    Text(font.title).tag(font)
                }
            }
            LabeledContent("Opacity") {
                Slider(value: $widget.style.opacity, in: 0.3...1.6)
            }

            Button("Remove widget", role: .destructive, action: remove)
        } header: {
            Text(widget.kind.title)
        }
    }
}

/// Whether macOS lets the app read events or reminders, and the button to ask.
private struct LockAccessRow: View {
    let type: EKEntityType
    @ObservedObject private var source = LockEvents.shared

    var body: some View {
        let allowed = type == .event ? source.canReadEvents : source.canReadReminders
        LabeledContent("Access") {
            if allowed {
                Text("Allowed")
            } else {
                Button("Allow access") {
                    source.requestAccess(to: type)
                }
            }
        }
    }
}

extension LockNoteColor {
    var title: LocalizedStringResource {
        switch self {
        case .yellow: "Yellow"
        case .pink: "Pink"
        case .blue: "Blue"
        case .green: "Green"
        case .orange: "Orange"
        case .purple: "Purple"
        }
    }
}

extension LockAccent {
    var title: LocalizedStringResource {
        switch self {
        case .white: "White"
        case .blue: "Blue"
        case .green: "Green"
        case .orange: "Orange"
        case .pink: "Pink"
        case .purple: "Purple"
        case .yellow: "Yellow"
        case .wallpaper: "Matches the wallpaper"
        }
    }
}

extension LockFont {
    var title: LocalizedStringResource {
        switch self {
        case .rounded: "Rounded"
        case .standard: "Standard"
        case .serif: "Serif"
        case .mono: "Monospaced"
        }
    }
}

// MARK: - Place

private struct LockWeatherPlaceSection: View {
    @Default(.lockScreenWeatherPlace) private var place
    @State private var query = ""
    @State private var results: [LockWeatherPlace] = []
    @State private var isSearching = false
    @State private var foundNothing = false

    var body: some View {
        Section {
            if let place {
                LabeledContent("Place") {
                    Text(verbatim: place.region.isEmpty ? place.name : "\(place.name), \(place.region)")
                }
            }
            HStack {
                TextField("City", text: $query, prompt: Text("Search for a city"))
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).count < 2 || isSearching)
            }
            ForEach(results, id: \.self) { result in
                Button {
                    LockWeather.shared.choose(result)
                    results = []
                    query = ""
                } label: {
                    HStack {
                        Text(verbatim: result.name)
                        Text(verbatim: result.region)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if foundNothing {
                Text("No place found")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Weather")
        } footer: {
            Text("Weather comes from Open-Meteo, at most every 30 minutes and only while the Mac is locked with the screen on.")
        }
    }

    private func search() {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2, !isSearching else { return }
        isSearching = true
        foundNothing = false
        Task {
            results = await LockWeather.search(name)
            foundNothing = results.isEmpty
            isSearching = false
        }
    }
}

// MARK: - Switching

/// The profiles in the notch's right-click menu. Only there once there's more than one.
struct LockProfileMenu: View {
    @Default(.lockScreenProfiles) private var profiles
    @Default(.lockScreenActiveProfile) private var activeProfile

    var body: some View {
        if profiles.count > 1 {
            let activeID = LockProfiles.active.id
            Menu("Lock screen profile") {
                ForEach(profiles) { profile in
                    Toggle(isOn: Binding {
                        profile.id == activeID
                    } set: { _ in
                        activeProfile = profile.id.uuidString
                    }) {
                        Text(verbatim: profile.name)
                    }
                }
            }
        }
    }
}
