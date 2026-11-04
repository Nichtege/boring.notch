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
/// Never takes the keyboard, except while a reply is being typed on a card.
private final class NotificationCardPanel: NSPanel {
    var takesKeyboard = false

    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        SystemNotificationManager.shared.cancelReply()
    }
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
            if let openedID, !notifications.contains(where: { $0.id == openedID }) {
                self.openedID = nil
            }
            for bundleID in notifications.compactMap(\.bundleID) where icons[bundleID] == nil {
                icons[bundleID] = AppIconAsNSImage(for: bundleID)
            }
        }
    }
    /// How the first card arrives and how the last one goes.
    @Published var stage = Stage.hidden
    @Published var isExpanded = false

    enum ReplyState: Equatable {
        case editing, sending, sent
        case failed(String)
    }
    /// The card a reply is being typed on, and what it says so far. Never kept anywhere else.
    @Published var replyingID: String?
    @Published var replyText = ""
    @Published var replyState = ReplyState.editing
    /// The banner is unfolded and its field there: from then on the keyboard is this card's.
    @Published var replyIsReady = false
    /// Held open to show all of what it says, like on the iPhone. A card being replied from is too.
    @Published var openedID: String?

    func isOpened(_ notification: SystemNotification) -> Bool {
        openedID == notification.id || replyingID == notification.id
    }
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
    private var keyObserver: NSObjectProtocol?
    /// Notification Center takes the keyboard for its own field as it unfolds, maybe more than once.
    /// For a moment after that, losing the keyboard means taking it back, not that a click went elsewhere.
    private var replyReadyAt = Date.distantPast
    private var keyboardRetakes = 0
    private let retakeTime: TimeInterval = 1.5
    private let maxKeyboardRetakes = 3

    private init() {}

    // MARK: Holding open
    /// Shows all of what this card says, until the pointer leaves the cards.
    func openFully(_ id: String) {
        withAnimation(Self.stackAnimation) {
            model.openedID = id
        }
    }

    func closeOpened() {
        guard model.openedID != nil else { return }
        withAnimation(Self.stackAnimation) {
            model.openedID = nil
        }
    }

    // MARK: Replying
    var replyingID: String? { model.replyingID }
    var replyText: String { model.replyText }
    var replyState: NotificationCardModel.ReplyState { model.replyState }

    /// The field opens on the card in front. The keyboard comes once the banner behind it is ready.
    func startReplying(_ id: String, in notifications: [SystemNotification]) {
        guard let panel, show(notifications) else { return }
        withAnimation(Self.stackAnimation) {
            model.replyText = ""
            model.replyState = .editing
            model.replyIsReady = false
            model.replyingID = id
            model.isExpanded = false
        }

        if keyObserver == nil {
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { _ in
                Task { @MainActor in NotificationCardController.shared.keyboardLeft() }
            }
        }
    }

    /// The keyboard goes to the card's field, without this app coming forward.
    func replyBecameReady() {
        guard let panel, model.replyingID != nil else { return }
        model.replyIsReady = true
        replyReadyAt = Date()
        keyboardRetakes = 0
        takeKeyboard(panel)
    }

    private func takeKeyboard(_ panel: NotificationCardPanel) {
        panel.takesKeyboard = true
        panel.makeKeyAndOrderFront(nil)
        focusReplyField(in: panel)
    }

    /// A click elsewhere with nothing typed means no reply. Anything typed stays for a click back.
    private func keyboardLeft() {
        guard let panel, model.replyingID != nil, model.replyState == .editing, model.replyIsReady else { return }
        if Date().timeIntervalSince(replyReadyAt) < retakeTime, keyboardRetakes < maxKeyboardRetakes {
            keyboardRetakes += 1
            takeKeyboard(panel)
            return
        }
        if model.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SystemNotificationManager.shared.cancelReply()
        }
    }

    func setReplyState(_ state: NotificationCardModel.ReplyState) {
        withAnimation(Self.stackAnimation) {
            model.replyState = state
        }
    }

    /// The keyboard goes back to where it was: a panel that lets go of it gives it to the app in front.
    func stopReplying() {
        withAnimation(Self.stackAnimation) {
            model.replyingID = nil
            model.replyText = ""
            model.replyState = .editing
            model.replyIsReady = false
        }
        guard let panel else { return }
        panel.takesKeyboard = false
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// SwiftUI's focus doesn't reach a field in a panel that only just took the keyboard, so AppKit is asked.
    private func focusReplyField(in panel: NSPanel) {
        Task { @MainActor in
            for _ in 0..<10 {
                if let field = Self.textField(in: panel.contentView), panel.makeFirstResponder(field) {
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }

    /// Shows these as the stack, whatever it held before. False if there's no screen to show it on.
    func show(_ notifications: [SystemNotification]) -> Bool {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard NotchPanelLayout.shared.mainScreen != nil else { return false }

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
        // Stays put like the notch on a swipe to another space, instead of sliding away with the old one.
        // That space is above the lock screen too, which is what hideAtOnce is for.
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
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
            self.takeDown(panel)
        }
    }

    /// For the lock screen: what a card says is private, and the way out would take a second.
    func hideAtOnce() {
        guard let panel else { return }
        motionTask?.cancel()
        model.isExpanded = false
        model.stage = .hidden
        takeDown(panel)
    }

    private func takeDown(_ panel: NSPanel) {
        // Stays in the notch's space: taking it out would leave it on the user's spaces for good
        panel.orderOut(nil)
        model.notifications = []
        stopObservingScreens()
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

    /// Always on the Mac's own screen, under its notch. The panel's top edge is where the notch or the Atlas
    /// line ends, with the gap inside the panel. That edge also cuts off the card on its way in, which
    /// makes it come out from behind them.
    private func place(_ panel: NSPanel, animated: Bool) {
        let layout = NotchPanelLayout.shared
        guard let screen = layout.mainScreen else { return }

        // A line on another screen, or whose screen just went away, is no place to line up with
        let line = AtlasPromptController.shared.lineFrame.flatMap { $0.intersects(screen.frame) ? $0 : nil }
        let top = line?.minY ?? layout.notchBottom(on: screen)
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
    /// The card being held, which gives a little under the finger like on the iPhone.
    @GestureState private var heldID: String?
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
            // While a reply is typed on it, the field and its button get every click
            .gesture(pressGesture(for: notification), including: model.replyingID == notification.id ? .subviews : .all)
            .scaleEffect(heldID == notification.id ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: heldID)
            .allowsHitTesting(!isHidingBehind)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Close")) {
                SystemNotificationManager.shared.dismiss(notification)
            }
            .accessibilityActions {
                if notification.canReply {
                    Button("Reply") {
                        SystemNotificationManager.shared.startReply(notification)
                    }
                }
                ForEach(notification.actions, id: \.self) { action in
                    Button(action) {
                        SystemNotificationManager.shared.answer(notification, with: action)
                    }
                }
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

    /// A click opens it. Held, it opens up to all it says, with the reply field if it can be answered.
    private func pressGesture(for notification: SystemNotification) -> AnyGesture<Void> {
        let open = TapGesture().onEnded {
            // Its field is for typing in, not a way into the app
            guard model.replyingID != notification.id else { return }
            SystemNotificationManager.shared.open(notification)
        }
        let hold = LongPressGesture(minimumDuration: 0.45)
            .updating($heldID) { isHeld, state, _ in
                state = isHeld && model.replyingID == nil && model.openedID != notification.id ? notification.id : nil
            }
            .onEnded { _ in
                SystemNotificationManager.shared.hold(notification)
            }
        return AnyGesture(hold.exclusively(before: open).map { _ in })
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
                        .lineLimit(model.isOpened(notification) ? 3 : 1)
                }
                if let body = notification.body {
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                        // Held open it shows all of it, up to what still fits under the notch
                        .lineLimit(model.isOpened(notification) ? 24 : 2)
                        .truncationMode(.tail)
                }
                if model.replyingID == notification.id {
                    ReplyField(model: model)
                        .padding(.top, 8)
                }
                if !notification.actions.isEmpty {
                    ButtonRows {
                        ForEach(notification.actions, id: \.self) { action in
                            AlertButton(label: action) {
                                SystemNotificationManager.shared.answer(notification, with: action)
                            }
                        }
                    }
                    .padding(.top, 8)
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
            .opacity(hoveredID == notification.id && !notification.isAlert ? 0 : 1)

            // An alert is answered with its own buttons
            if hoveredID == notification.id, !notification.isAlert {
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

/// Where a reply is typed: Return sends it, Esc puts the card back as it was.
private struct ReplyField: View {
    @ObservedObject var model: NotificationCardModel
    @FocusState private var isFocused: Bool

    private var isBlank: Bool {
        model.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        switch model.replyState {
        case .editing, .sending:
            HStack(spacing: 8) {
                TextField("Reply…", text: $model.replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($isFocused)
                    .onSubmit { SystemNotificationManager.shared.sendReply() }
                    .disabled(model.replyState == .sending || !model.replyIsReady)
                if model.replyState == .sending || !model.replyIsReady {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        SystemNotificationManager.shared.sendReply()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(isBlank ? 0.3 : 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isBlank)
                    .help(Text("Send"))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.14), in: Capsule())
            .onChange(of: model.replyIsReady) {
                if model.replyIsReady {
                    isFocused = true
                }
            }
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                AlertButton(label: String(localized: "Open app")) {
                    SystemNotificationManager.shared.openAfterFailedReply()
                }
            }
        }
    }
}

/// One of an alert's own buttons, as Notification Center would have shown it.
private struct AlertButton: View {
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.white.opacity(isHovered ? 0.26 : 0.16), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered = $0 }
    }
}

/// Side by side, in as many rows as they need. One too long for a row is cut short.
private struct ButtonRows: Layout {
    var spacing: CGFloat = 6

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = self.size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = size(of: subviews[index], width: width)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty {
            rows.append(row)
        }
        return rows
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
