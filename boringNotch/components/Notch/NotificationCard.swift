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
    @Published var notification: SystemNotification?
    @Published var isPresented = false
}

@MainActor
final class NotificationCardController {
    static let shared = NotificationCardController()

    private let width: CGFloat = 400
    // Long enough for the spring to come to rest, or for the fade with reduced motion
    private let motionDuration: Duration = .milliseconds(800)
    private let model = NotificationCardModel()
    private var panel: NotificationCardPanel?
    private var cardHeight: CGFloat = 72
    private var motionTask: Task<Void, Never>?

    private init() {}

    /// False if there's no screen to show it on.
    func show(_ notification: SystemNotification) -> Bool {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard NotchPanelLayout.shared.screen(for: panel) != nil else { return false }

        motionTask?.cancel()
        model.notification = notification
        place(panel, animated: panel.isVisible)
        panel.orderFrontRegardless()

        let isComingIn = !model.isPresented
        if isComingIn {
            panel.hasShadow = false
        }
        motionTask = Task { @MainActor [weak self] in
            if isComingIn {
                // One frame for the card to measure itself, so it starts from fully behind the notch
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else { return }
                self?.model.isPresented = true
            }
            // The window's shadow doesn't follow what moves inside it, so it comes once the card rests
            try? await Task.sleep(for: self?.motionDuration ?? .seconds(1))
            guard !Task.isCancelled else { return }
            panel.hasShadow = true
            panel.invalidateShadow()
        }
        return true
    }

    func hide() {
        guard let panel else { return }
        motionTask?.cancel()
        panel.hasShadow = false
        model.isPresented = false
        motionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.motionDuration ?? .seconds(1))
            guard let self, !Task.isCancelled else { return }
            panel.orderOut(nil)
            self.model.notification = nil
        }
    }

    /// Waits for the card to be on screen for real: ordered in, on its way, and not covered or on a
    /// screen that's off. A banner only leaves when this says yes.
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

    private func makePanel() -> NotificationCardPanel {
        let panel = NotificationCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .mainMenu + 4
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]

        let host = FirstClickHostingView(rootView: NotificationCardView(model: model) { [weak self] height in
            self?.resize(to: height)
        })
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.addSubview(host)

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

        let top = line?.minY ?? layout.notchBottom(on: screen)
        let height = cardHeight + layout.gapBelowNotch
        let frame = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        layout.move(panel, to: frame, animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
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

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.8)
    }

    /// All the way up behind the notch, including the gap.
    private var hiddenOffset: CGFloat {
        reduceMotion ? 0 : -(cardHeight + NotchPanelLayout.shared.gapBelowNotch)
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
                    .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.92, anchor: .top)
                    .offset(y: model.isPresented ? 0 : hiddenOffset)
                    .opacity(model.isPresented ? 1 : 0)
                    .padding(.top, NotchPanelLayout.shared.gapBelowNotch)
            }
            Spacer(minLength: 0)
        }
        .animation(motion, value: model.isPresented)
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
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .smokedGlass(in: shape)
            .contentShape(shape)
            .onHover { hovering in
                isHovering = hovering
                SystemNotificationManager.shared.cardHoverChanged(hovering)
            }
            .onTapGesture {
                SystemNotificationManager.shared.openActive()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Close")) {
                SystemNotificationManager.shared.dismissActive()
            }
    }

    private func content(_ notification: SystemNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(for: notification)
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
    private func icon(for notification: SystemNotification) -> some View {
        if let image = notification.bundleID.flatMap(AppIconAsNSImage(for:)) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 40, height: 40)
        } else {
            Image(systemName: "bell.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
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
