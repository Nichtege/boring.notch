//
//  NotificationCard.swift
//  boringNotch
//
//  The cards under the notch that stand in for other apps' notification banners: a stack whose newest
//  card is in front, which spreads out under the pointer so all of them can be read.
//  They float like the Atlas line, but never take the keyboard or activate this app.
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

    /// Newest first, so the one in front comes first.
    @Published var notifications: [SystemNotification] = [] {
        didSet {
            if notifications.isEmpty {
                icons.removeAll()
            }
            for bundleID in notifications.compactMap(\.bundleID) where icons[bundleID] == nil {
                icons[bundleID] = AppIconAsNSImage(for: bundleID)
            }
        }
    }
    /// How the first card arrives and how the last one goes.
    @Published var stage = Stage.hidden
    @Published var isExpanded = false
    // A new image on every update would crossfade with the old one while the icon moves
    private var icons: [String: NSImage] = [:]

    var isPresented: Bool {
        stage != .hidden
    }

    func icon(of notification: SystemNotification) -> NSImage? {
        notification.bundleID.flatMap { icons[$0] }
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
    private var stackHeight: CGFloat = 72
    private var motionTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    private init() {}

    /// Shows these as the stack, whatever it held before. False if there's no screen to show it on.
    func show(_ notifications: [SystemNotification]) -> Bool {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard NotchPanelLayout.shared.screen(for: panel) != nil else { return false }

        motionTask?.cancel()
        panel.ignoresMouseEvents = false
        let isComingIn = model.stage == .hidden
        if isComingIn {
            model.notifications = notifications
        } else {
            withAnimation(Self.stackAnimation) {
                model.notifications = notifications
            }
        }
        // Once it's up it only moves with the notch and the Atlas line, and resizes with the stack
        if !panel.isVisible {
            place(panel, animated: false)
        }
        panel.orderFrontRegardless()
        observeScreens()

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
        withAnimation(Self.stackAnimation) {
            model.isExpanded = false
        }
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
            self.model.notifications = []
            self.stopObservingScreens()
        }
    }

    /// Waits for the card to be on screen for real: ordered in, on its way, and not covered or on a
    /// screen that's off. A banner only stays away when this says yes.
    func waitUntilOnScreen(_ notification: SystemNotification) async -> Bool {
        for _ in 0..<10 {
            if model.notifications.contains(where: { $0.id == notification.id }), model.isPresented,
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

    /// Cards moving within the stack.
    static var stackAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.42, dampingFraction: 0.84)
    }

    private func makePanel() -> NotificationCardPanel {
        let panel = NotificationCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: stackHeight),
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

    /// The panel cuts off whatever sticks out, and nothing of it shows but the cards. So it makes room
    /// at once, and only takes it back once the cards have moved in.
    private func resize(to height: CGFloat) {
        guard abs(stackHeight - height) > 0.5 || shrinkTask != nil else { return }
        shrinkTask?.cancel()
        shrinkTask = nil

        guard height < stackHeight else {
            stackHeight = height
            if let panel {
                place(panel, animated: false)
            }
            return
        }
        shrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            self.shrinkTask = nil
            self.stackHeight = height
            if let panel = self.panel {
                self.place(panel, animated: false)
            }
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
        let height = stackHeight + layout.gapBelowNotch + Self.bleed
        let frame = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        layout.move(panel, to: frame, animated: animated && !Self.reduceMotion)
    }
}

// MARK: - View
private struct NotificationCardView: View {
    @ObservedObject var model: NotificationCardModel
    let onHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: String?
    /// What each card needs for its text. Behind the one in front it only gets that once spread out.
    @State private var heights: [String: CGFloat] = [:]

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    private let ballDiameter: CGFloat = 44
    private let ballIconSize: CGFloat = 30
    private let cardPadding: CGFloat = 14
    private let cardIconSize: CGFloat = 40
    private let defaultHeight: CGFloat = 72
    /// How much of each card shows below the one in front of it, and how much narrower it is.
    private let peek: CGFloat = 8
    private let shrink: CGFloat = 0.05
    private let spreadSpacing: CGFloat = 8
    /// Far enough to come out from behind the notch, for the tallest a card can be.
    private let arrivalDistance: CGFloat = 130

    /// With reduced motion there's no ball: the finished card fades in and out.
    private var isFrontOpened: Bool {
        model.stage == .card || reduceMotion
    }

    private var frontHeight: CGFloat {
        height(of: model.notifications.first)
    }

    private func height(of notification: SystemNotification?) -> CGFloat {
        notification.flatMap { heights[$0.id] } ?? defaultHeight
    }

    private var stackHeight: CGFloat {
        let behind = CGFloat(max(model.notifications.count - 1, 0))
        guard model.isExpanded else { return frontHeight + peek * behind }
        return model.notifications.reduce(0) { $0 + height(of: $1) } + spreadSpacing * behind
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ForEach(Array(model.notifications.enumerated()), id: \.element.id) { index, notification in
                    layer(notification, at: index)
                        // Stays with the card as it leaves, or the others would jump in front of it
                        .zIndex(-Double(index))
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(insertion: .offset(y: -arrivalDistance), removal: .opacity)
                        )
                }
            }
            .frame(height: stackHeight, alignment: .top)
            .contentShape(Rectangle())
            .onContinuousHover { phase in hoverChanged(phase) }
            // A ball isn't there to be hovered or clicked: it would open something unread
            .allowsHitTesting(model.stage == .card)
            .padding(.top, NotchPanelLayout.shared.gapBelowNotch)
            .padding(.horizontal, NotificationCardController.bleed)
            Spacer(minLength: 0)
        }
        .onChange(of: stackHeight, initial: true) {
            onHeightChange(stackHeight)
        }
        .onChange(of: model.isPresented) {
            if !model.isPresented {
                hoveredID = nil
            }
        }
        // Hovered on its way out, and then gone: there's no exit to come
        .onChange(of: model.notifications.isEmpty) {
            if model.notifications.isEmpty {
                hoveredID = nil
                heights.removeAll()
            }
        }
    }

    /// One place for all of it, as the cards overlap and spread out under a pointer that stays put.
    private func hoverChanged(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            if !model.isExpanded {
                withAnimation(NotificationCardController.stackAnimation) {
                    model.isExpanded = true
                }
                SystemNotificationManager.shared.cardHoverChanged(true)
            }
            hoveredID = notificationID(at: location.y)
        case .ended:
            hoveredID = nil
            withAnimation(NotificationCardController.stackAnimation) {
                model.isExpanded = false
            }
            SystemNotificationManager.shared.cardHoverChanged(false)
        }
    }

    private func notificationID(at y: CGFloat) -> String? {
        var bottom: CGFloat = 0
        for notification in model.notifications {
            bottom += height(of: notification) + spreadSpacing
            if y < bottom - spreadSpacing / 2 {
                return notification.id
            }
        }
        return model.notifications.last?.id
    }

    /// Where a card's top is when spread out.
    private func spreadOffset(at index: Int) -> CGFloat {
        model.notifications.prefix(index).reduce(0) { $0 + height(of: $1) + spreadSpacing }
    }

    private func layer(_ notification: SystemNotification, at index: Int) -> some View {
        let isFront = index == 0
        let isOpened = !isFront || isFrontOpened
        let isHidingBehind = !isFront && !model.isExpanded
        // Behind the front card it takes on its size, and its own text would be cut off by that
        let shownHeight = isHidingBehind ? frontHeight : height(of: notification)

        return card(notification, showsText: isOpened && !isHidingBehind)
            .frame(height: shownHeight, alignment: .top)
            .mask { outline(isOpened: isOpened) }
            .background { shell(isOpened: isOpened, isHidingBehind: isHidingBehind, depth: index) }
            .overlay { movingIcon(notification, isOpened: isOpened).opacity(isHidingBehind ? 0 : 1) }
            .contentShape(shape)
            .onTapGesture {
                SystemNotificationManager.shared.open(notification)
            }
            .allowsHitTesting(!isHidingBehind)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Close")) {
                SystemNotificationManager.shared.dismiss(notification)
            }
            .modifier(NotificationBallDrop(
                progress: !isFront || model.isPresented || reduceMotion ? 1 : 0,
                restingCenter: NotchPanelLayout.shared.gapBelowNotch + shownHeight / 2,
                gap: NotchPanelLayout.shared.gapBelowNotch,
                diameter: ballDiameter
            ))
            .scaleEffect(isHidingBehind ? 1 - shrink * CGFloat(index) : 1, anchor: .bottom)
            .offset(y: model.isExpanded ? spreadOffset(at: index) : peek * CGFloat(index))
            // Into the front card before it turns into a ball
            .opacity(isFront ? (model.isPresented || !reduceMotion ? 1 : 0) : (isFrontOpened && model.isPresented ? 1 : 0))
    }

    private func card(_ notification: SystemNotification, showsText: Bool) -> some View {
        content(notification)
            .padding(cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                heights[notification.id] = height
            }
            // The text waits until the ball has room for it, and always stays inside
            .opacity(showsText ? 1 : 0)
            .blur(radius: showsText ? 0 : 6)
            .animation(.easeOut(duration: 0.2).delay(showsText ? 0.1 : 0), value: showsText)
    }

    private func outline(isOpened: Bool) -> some View {
        RoundedRectangle(cornerRadius: isOpened ? 26 : ballDiameter / 2, style: .continuous)
            .frame(width: isOpened ? nil : ballDiameter, height: isOpened ? nil : ballDiameter)
    }

    /// Black like the notch it comes out of, and smoked glass once it has opened up. The glass keeps its
    /// size and only gets uncovered, so it isn't rendered anew for every frame of the motion. A window's
    /// shadow can't follow any of this, and only appears at once when the card rests, so this one's drawn.
    /// Behind the front card it's plain and darker with every step, as glass on glass only gets muddy.
    private func shell(isOpened: Bool, isHidingBehind: Bool, depth: Int) -> some View {
        ZStack {
            outline(isOpened: isOpened)
                .foregroundStyle(.black)
                .shadow(color: .black.opacity(isOpened ? 0.4 : 0), radius: 8, y: 2)
                .overlay(outline(isOpened: isOpened).blendMode(.destinationOut))
                .compositingGroup()
            Color.clear
                .smokedGlass(in: shape)
                .mask { outline(isOpened: isOpened) }
            outline(isOpened: isOpened)
                .foregroundStyle(.black)
                .opacity(isOpened ? 0 : 1)
            shape
                .fill(Color(white: 0.24 - 0.04 * CGFloat(depth)))
                .opacity(isHidingBehind ? 1 : 0)
        }
    }

    /// In the middle of the ball, then off to its place in the card.
    private func movingIcon(_ notification: SystemNotification, isOpened: Bool) -> some View {
        GeometryReader { geometry in
            icon(of: notification, size: isOpened ? cardIconSize : ballIconSize)
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
    private func icon(of notification: SystemNotification, size: CGFloat) -> some View {
        if let image = model.icon(of: notification) {
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
            .opacity(hoveredID == notification.id ? 0 : 1)

            if hoveredID == notification.id {
                Button {
                    SystemNotificationManager.shared.dismiss(notification)
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
