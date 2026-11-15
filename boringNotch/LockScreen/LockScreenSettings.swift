//
//  LockScreenSettings.swift
//  boringNotch
//
//  The settings tab for the lock screen widgets, with a small screen to arrange them on.
//

import Defaults
import SwiftUI

struct LockScreenSettings: View {
    @Default(.lockScreenWidgets) private var isEnabled
    @Default(.lockScreenProfiles) private var profiles
    @Default(.lockScreenActiveProfile) private var activeProfile
    @Default(.lockScreenDisplay) private var display

    @State private var selection: UUID?
    @State private var noRoom = false
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
                    if noRoom {
                        Text("No room left for this size")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Drag a widget to move it. Click one to change it. The middle belongs to the lock screen's own clock and login.")
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
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Lock Screen")
        .onAppear { LockScreenController.shared.isPreviewing = true }
        .onDisappear { LockScreenController.shared.isPreviewing = false }
        .onChange(of: profiles) { LockScreenController.shared.isPreviewing = true }
    }

    private func add(_ kind: LockWidgetKind) {
        var widget = LockWidget(kind, column: 0, row: 0)
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
    var needsPlace: Bool { self == .weather }
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
                        .contentShape(Rectangle())
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
            default:
                EmptyView()
            }

            Button("Remove widget", role: .destructive, action: remove)
        } header: {
            Text(widget.kind.title)
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
