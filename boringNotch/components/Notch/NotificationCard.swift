//
//  NotificationCard.swift
//  boringNotch
//
//  The card under the notch that stands in for another app's notification banner.
//  It floats like the Atlas line, but never takes the keyboard or activates this app.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Window
private final class NotificationCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel is never key, so the first click is the only click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotificationCardModel: ObservableObject {
    /// Behind the notch, then a ball with the app's icon below it, then the ball opened up into the card.
    enum Stage {
        case hidden, ball, card
    }

    // A new image on every update would crossfade with the old one while the icon moves
    @Published var notification: SystemNotification? {
        didSet { icon = notification?.bundleID.flatMap(AppIconAsNSImage(for:)) }
    }
    @Published var stage = Stage.hidden
    private(set) var icon: NSImage?

    var isPresented: Bool {
        stage != .hidden
    }
}

@MainActor
final class NotificationCardController {
    static let shared = NotificationCardController()

    static let width: CGFloat = 400
    /// Room around the card for the springs to overshoot, or the panel's edges would cut it off.
    static let bleed: CGFloat = 12

    // Long enough for the spring to come to rest, or for the fade with reduced motion
    private let motionDuration: Duration = .milliseconds(900)
    // Shorter than the spring needs to settle, so the ball is still arriving as it opens up
    private let ballDuration: Duration = .milliseconds(230)
    private let model = NotificationCardModel()
    private var panel: NotificationCardPanel?
    private var cardHeight: CGFloat = 72
    private var motionTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    private init() {}

    /// False if there's no screen to show it on.
    func show(_ notification: SystemNotification) -> Bool {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard NotchPanelLayout.shared.screen(for: panel) != nil else { return false }

        motionTask?.cancel()
        panel.ignoresMouseEvents = false
        model.notification = notification
        place(panel, animated: panel.isVisible)
        panel.orderFrontRegardless()
        observeScreens()

        let isComingIn = model.stage == .hidden
        motionTask = Task { @MainActor [weak self] in
            if isComingIn && !Self.reduceMotion {
                // One frame for the card to measure itself, so it starts from fully behind the notch
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.46, dampingFraction: 0.72)) {
                    self?.model.stage = .ball
                }
                try? await Task.sleep(for: self?.ballDuration ?? .seconds(1))
                guard !Task.isCancelled else { return }
            }
            withAnimation(Self.reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.56, dampingFraction: 0.82)) {
                self?.model.stage = .card
            }
        }
        return true
    }

    func hide() {
        guard let panel else { return }
        // A card on its way out isn't there to be clicked, and what's below it is
        panel.ignoresMouseEvents = true
        motionTask?.cancel()
        motionTask = Task { @MainActor [weak self] in
            if !Self.reduceMotion {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) {
                    self?.model.stage = .ball
                }
                try? await Task.sleep(for: .milliseconds(190))
                guard !Task.isCancelled else { return }
            }
            withAnimation(Self.reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.38, dampingFraction: 0.95)) {
                self?.model.stage = .hidden
            }
            try? await Task.sleep(for: self?.motionDuration ?? .seconds(1))
            guard let self, !Task.isCancelled else { return }
            panel.orderOut(nil)
            self.model.notification = nil
            self.stopObservingScreens()
        }
    }

    /// Waits for the card to be on screen for real: ordered in, on its way, and not covered or on a
    /// screen that's off. A banner only stays away when this says yes.
    func waitUntilOnScreen(_ notification: SystemNotification) async -> Bool {
        for _ in 0..<10 {
            if model.notification?.id == notification.id, model.isPresented,
               panel?.isVisible == true, panel?.occlusionState.contains(.visible) == true {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// For the notch and the Atlas line, whenever they move.
    func reposition() {
        guard let panel, panel.isVisible else { return }
        place(panel, animated: true)
    }

    /// Only while the card is up, which is the only time it has to follow.
    private func observeScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    private func stopObservingScreens() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func makePanel() -> NotificationCardPanel {
        let panel = NotificationCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        NotchPanelLayout.shared.configure(panel)
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = false
        panel.animationBehavior = .none

        let host = FirstClickHostingView(rootView: NotificationCardView(model: model) { [weak self] height in
            self?.resize(to: height)
        })
        NotchPanelLayout.shared.embed(host, in: panel)

        return panel
    }

    private func resize(to height: CGFloat) {
        guard abs(cardHeight - height) > 0.5 else { return }
        cardHeight = height
        if let panel {
            place(panel, animated: panel.isVisible)
        }
    }

    /// The panel's top edge is where the notch or the Atlas line ends, with the gap inside the panel.
    /// That edge also cuts off the card on its way in, which makes it come out from behind them.
    private func place(_ panel: NSPanel, animated: Bool) {
        let layout = NotchPanelLayout.shared
        let line = AtlasPromptController.shared.lineFrame
        let lineScreen = line.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
        guard let screen = lineScreen ?? layout.screen(for: panel) else { return }

        // A line whose screen just went away is no place to line up with
        let top = (lineScreen == nil ? nil : line?.minY) ?? layout.notchBottom(on: screen)
        let width = Self.width + 2 * Self.bleed
        let height = cardHeight + layout.gapBelowNotch + Self.bleed
        let frame = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        layout.move(panel, to: frame, animated: animated && !Self.reduceMotion)
    }
}

// MARK: - View
private struct NotificationCardView: View {
    @ObservedObject var model: NotificationCardModel
    let onHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var cardHeight: CGFloat = 72

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    private let ballDiameter: CGFloat = 44
    private let ballIconSize: CGFloat = 30
    private let cardPadding: CGFloat = 14
    private let cardIconSize: CGFloat = 40

    /// With reduced motion there's no ball: the finished card fades in and out.
    private var isOpened: Bool {
        model.stage == .card || reduceMotion
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notification = model.notification {
                card(notification)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        cardHeight = height
                        onHeightChange(height)
                    }
                    .modifier(NotificationBallDrop(
                        progress: model.isPresented || reduceMotion ? 1 : 0,
                        restingCenter: NotchPanelLayout.shared.gapBelowNotch + cardHeight / 2,
                        gap: NotchPanelLayout.shared.gapBelowNotch,
                        diameter: ballDiameter
                    ))
                    .opacity(model.isPresented || !reduceMotion ? 1 : 0)
                    .padding(.top, NotchPanelLayout.shared.gapBelowNotch)
                    .padding(.horizontal, NotificationCardController.bleed)
            }
            Spacer(minLength: 0)
        }
        .onChange(of: model.isPresented) {
            if !model.isPresented {
                isHovering = false
            }
        }
        // Hovered on its way out, and then gone: there's no exit to come
        .onChange(of: model.notification == nil) {
            if model.notification == nil {
                isHovering = false
            }
        }
    }

    private func card(_ notification: SystemNotification) -> some View {
        content(notification)
            .id(notification.id)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: notification.id)
            .padding(cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The text waits until the ball has room for it, and always stays inside
            .opacity(isOpened ? 1 : 0)
            .blur(radius: isOpened ? 0 : 6)
            .animation(.easeOut(duration: 0.2).delay(isOpened ? 0.1 : 0), value: isOpened)
            .mask { outline }
            .background { shell }
            .overlay { movingIcon(notification) }
            .contentShape(shape)
            .onHover { hovering in
                isHovering = hovering
                SystemNotificationManager.shared.cardHoverChanged(hovering)
            }
            .onTapGesture {
                SystemNotificationManager.shared.openActive()
            }
            // The shape covers the whole card from the start. A click on the ball would open something unread.
            .allowsHitTesting(model.stage == .card)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Close")) {
                SystemNotificationManager.shared.dismissActive()
            }
    }

    private var outline: some View {
        RoundedRectangle(cornerRadius: isOpened ? 26 : ballDiameter / 2, style: .continuous)
            .frame(width: isOpened ? nil : ballDiameter, height: isOpened ? nil : ballDiameter)
    }

    /// Black like the notch it comes out of, and smoked glass once it has opened up. The glass keeps its
    /// size and only gets uncovered, so it isn't rendered anew for every frame of the motion. A window's
    /// shadow can't follow any of this, and only appears at once when the card rests, so this one's drawn.
    private var shell: some View {
        ZStack {
            outline
                .foregroundStyle(.black)
                .shadow(color: .black.opacity(isOpened ? 0.4 : 0), radius: 8, y: 2)
                .overlay(outline.blendMode(.destinationOut))
                .compositingGroup()
            Color.clear
                .smokedGlass(in: shape)
                .mask { outline }
            outline
                .foregroundStyle(.black)
                .opacity(isOpened ? 0 : 1)
        }
    }

    /// In the middle of the ball, then off to its place in the card.
    private func movingIcon(_ notification: SystemNotification) -> some View {
        GeometryReader { geometry in
            icon(size: isOpened ? cardIconSize : ballIconSize)
                .id(notification.id)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: notification.id)
                .position(
                    x: isOpened ? cardPadding + cardIconSize / 2 : geometry.size.width / 2,
                    y: isOpened ? cardPadding + cardIconSize / 2 : geometry.size.height / 2
                )
        }
        .allowsHitTesting(false)
    }

    private func content(_ notification: SystemNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: cardIconSize, height: cardIconSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notification.title ?? notification.appName ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    timeOrClose(notification)
                }
                if let subtitle = notification.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if let body = notification.body {
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        if let image = model.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bell.fill")
                .resizable()
                .scaledToFit()
                .padding(size / 4)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
    }

    private func timeOrClose(_ notification: SystemNotification) -> some View {
        ZStack(alignment: .trailing) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                time(notification.receivedAt, now: context.date)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .opacity(isHovering ? 0 : 1)

            if isHovering {
                Button {
                    SystemNotificationManager.shared.dismissActive()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(PlainButtonStyle())
                .help(Text("Close"))
            }
        }
    }

    /// A card that had to wait can be a little older than now.
    private func time(_ date: Date, now: Date) -> Text {
        guard now.timeIntervalSince(date) >= 60 else { return Text("now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return Text(formatter.localizedString(for: date, relativeTo: now))
    }
}

/// How far the ball has come out of the notch: 0 above the panel's top edge, 1 in its place, and past 1
/// when the spring overshoots. It stretches on the way, joined to the notch by a neck that thins until it snaps.
private struct NotificationBallDrop: ViewModifier, Animatable {
    var progress: CGFloat
    let restingCenter: CGFloat
    let gap: CGFloat
    let diameter: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let stretch = sin(min(max(progress, 0), 1) * .pi)
        let travel = restingCenter + diameter / 2
        let center = restingCenter - travel * (1 - progress)

        content
            .scaleEffect(x: 1 - 0.08 * stretch, y: 1 + 0.14 * stretch)
            .offset(y: -travel * (1 - progress))
            .overlay(alignment: .top) {
                BallNeck(center: center, restingCenter: restingCenter, radius: diameter / 2)
                    .fill(.black)
                    .frame(width: 3 * diameter, height: max(0, center + diameter / 2))
                    .offset(y: -gap)
            }
    }
}

/// The liquid between notch and ball: spreads along the notch, thin in the middle, and melts into the ball.
private struct BallNeck: Shape {
    let center: CGFloat
    let restingCenter: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let distance = center - radius
        // Gone just before the ball is in its place
        let left = 1 - max(distance, 0) / ((restingCenter - radius) * 0.9)
        guard left > 0 else { return path }

        let middle = rect.midX
        let base = radius * 1.7 * pow(left, 0.7)
        let waist = radius * 0.55 * pow(left, 1.2)
        let side = radius * 0.77 * min(1, left * 3)
        let joint = max(center - radius * 0.64, 0)

        path.move(to: CGPoint(x: middle - base, y: 0))
        path.addCurve(
            to: CGPoint(x: middle - side, y: joint),
            control1: CGPoint(x: middle - waist, y: distance * 0.35),
            control2: CGPoint(x: middle - waist, y: joint * 0.75)
        )
        path.addLine(to: CGPoint(x: middle + side, y: joint))
        path.addCurve(
            to: CGPoint(x: middle + base, y: 0),
            control1: CGPoint(x: middle + waist, y: joint * 0.75),
            control2: CGPoint(x: middle + waist, y: distance * 0.35)
        )
        path.closeSubpath()
        return path
    }
}
