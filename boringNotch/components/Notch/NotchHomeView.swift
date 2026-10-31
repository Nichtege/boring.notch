//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        HStack {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace).padding(.all, 5)
            MusicControlsView().drawingGroup().compositingGroup()
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if vm.notchState == .open, let remoteName = musicManager.remoteName {
            // Its app is on that device, so this Mac may have no icon for it
            Image(systemName: RemoteNowPlaying.iconName(for: remoteName))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                .offset(x: 8, y: 8)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        } else if vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig

    var body: some View {
        VStack(alignment: .leading) {
            songInfoAndSlider
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                songInfo(width: geo.size.width)
                musicSlider
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                $musicManager.songTitle, font: .headline, nsFont: .headline, textColor: .white,
                frameWidth: width)
            MarqueeText(
                $musicManager.artistName,
                font: .headline,
                nsFont: .headline,
                textColor: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !musicManager.isPlaying)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 5)
            .frame(height: 36)
        }
        // Other devices only take play, pause and skips from here
        .allowsHitTesting(!musicManager.isRemoteSource)
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .trailing) {
            // The name only fits when the last slot is empty
            Group {
                if let remoteName = musicManager.remoteName {
                    remoteLabel(remoteName, showsName: slots.last == MusicControlButton.none)
                } else {
                    MusicOutputButton(showsName: slots.last == MusicControlButton.none)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    private func remoteLabel(_ name: String, showsName: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: RemoteNowPlaying.iconName(for: name))
            if showsName {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundColor(.gray)
        .frame(maxWidth: 84, alignment: .trailing)
        .frame(height: 30)
    }

    private var activeSlots: [MusicControlButton] {
        let padded = slotConfig.padded(to: MusicControlButton.slotCount, filler: .none)
        return Array(padded.prefix(MusicControlButton.slotCount))
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle where musicManager.isRemoteSource, .repeatMode where musicManager.isRemoteSource, .favorite where musicManager.isRemoteSource:
            // Only Music has these
            Color.clear.frame(height: 1)
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .red : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            // Takes the room of an empty slot, so the middle stays in the middle
            VolumeControlView()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .red
        }
    }
}

struct MusicOutputButton: View {
    let showsName: Bool

    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var outputController = MusicOutputController.shared
    @State private var showPopover = false
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false
    @State private var hideTask: Task<Void, Never>?

    private let refreshInterval: Duration = .seconds(3)

    private var isVisible: Bool {
        musicManager.bundleIdentifier == "com.apple.Music" && !outputController.selectedDevices.isEmpty
    }

    private var currentIcon: String {
        let selected = outputController.selectedDevices
        return selected.count == 1 ? selected[0].iconName : "airplayaudio"
    }

    private var currentName: String {
        outputController.selectedDevices.map(\.displayName).joined(separator: " + ")
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentIcon)
                if showsName {
                    Text(currentName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption)
            .foregroundColor(.gray)
            .frame(maxWidth: 84, alignment: .trailing)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(isVisible ? 1 : 0)
        .disabled(!isVisible)
        .onHover { hovering in
            isHoveringButton = hovering
            updateHideTask()
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            devicePicker
                .onHover { hovering in
                    isHoveringPopover = hovering
                    updateHideTask()
                }
                // What's really on screen, also if this view goes away first: the notch can't close before
                .onAppear { vm.isBatteryPopoverActive = true }
                .onDisappear {
                    vm.isBatteryPopoverActive = false
                    showPopover = false
                }
        }
        .onChange(of: showPopover) {
            if showPopover {
                Task { await outputController.refreshPairedAirPods() }
            }
        }
        .task(id: musicManager.bundleIdentifier) {
            while !Task.isCancelled {
                await outputController.refresh()
                try? await Task.sleep(for: refreshInterval)
            }
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(outputController.pickerDevices) { device in
                Button {
                    showPopover = false
                    Task { await outputController.select(device) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: device.iconName)
                            .frame(width: 18)
                        // Several AirPods start with the same words, so the whole name has to fit
                        Text(device.displayName)
                            .fixedSize()
                        Spacer(minLength: 16)
                        Image(systemName: "checkmark")
                            .opacity(device.isSelected ? 1 : 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(6)
    }

    private func updateHideTask() {
        hideTask?.cancel()
        hideTask = nil
        guard showPopover, !isHoveringButton, !isHoveringPopover else { return }
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { showPopover = false }
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false

    private var isVisible: Bool {
        !musicManager.isRemoteSource
            && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: volumeIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 24)

            CustomSlider(
                value: $volumeSliderValue,
                range: 0.0...1.0,
                color: .white,
                dragging: $dragging,
                lastDragged: .constant(Date.distantPast),
                onValueChange: MusicManager.shared.setVolume(to:),
                onDragChange: MusicManager.shared.setVolume(to:),
                detentCount: SliderDetents.volumeCount
            )
            .frame(width: 80, height: 8)
        }
        .opacity(isVisible ? 1 : 0)
        .disabled(!isVisible)
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .task {
            await MusicManager.shared.syncVolumeFromActiveApp()
        }
    }

    private var volumeIcon: String {
        if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)

        }
        .transition(.opacity)
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    var onValueChange: (Double) -> Void


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange
            )
            .frame(height: 10, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .fontWeight(.medium)
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.caption)
        }
        .onAppear(perform: syncWithPlayback)
        .onChange(of: currentDate, syncWithPlayback)
        // The timeline stands still while paused, and a seek there has to show too
        .onChange(of: timestampDate, syncWithPlayback)
    }

    private func syncWithPlayback() {
        // After a drag it waits for news of the seek, but not for good: that news may never come
        guard !dragging,
              timestampDate.timeIntervalSince(lastDragged) > -1 || currentDate.timeIntervalSince(lastDragged) > 3
        else { return }
        sliderValue = MusicManager.shared.estimatedPlaybackPosition()
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

/// Clicks under the finger while a slider passes its steps, like the notches of a volume knob. Only a finger on
/// a Force Touch trackpad feels them.
struct SliderDetents {
    /// Every 5%
    static let volumeCount = 20

    private let minimumGap: TimeInterval = 0.03
    private var current: Int?
    private var lastClick = Date.distantPast

    /// The ends are stops, and a slider with a middle clicks harder there too.
    mutating func update(progress: Double, count: Int, hasMiddle: Bool = false) {
        let detent = Int((progress * Double(count)).rounded())
        defer { current = detent }
        guard let current, current != detent, Defaults[.enableHaptics] else { return }

        // Swiped across, one click per step would only buzz
        let now = Date()
        guard now.timeIntervalSince(lastClick) >= minimumGap else { return }
        lastClick = now

        let isStop = detent == 0 || detent == count || (hasMiddle && detent == count / 2)
        NSHapticFeedbackManager.defaultPerformer.perform(isStop ? .levelChange : .alignment, performanceTime: .now)
    }

    mutating func end() {
        current = nil
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?
    var detentCount = 0

    @State private var detents = SliderDetents()

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        if detentCount > 0, rangeSpan > 0 {
                            detents.update(progress: (value - range.lowerBound) / rangeSpan, count: detentCount)
                        }
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        detents.end()
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}
