//
//  AtlasPrompt.swift
//  boringNotch
//
//  A line under the notch to talk to Atlas from anywhere.
//  It talks to Starlane the way the dashboard page does: the phone key loads the page, the page holds the
//  token of this server start, and the token authorizes the message. Messages carry no X-AOS-Key, so Atlas
//  can answer from here but can't open terminals. The token stays in memory.
//

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class AtlasChat: ObservableObject {
    static let shared = AtlasChat()

    enum Phase: Equatable {
        case idle
        case sending
        case running
        case failed(String)
    }

    @Published var input = ""
    @Published private(set) var question = ""
    @Published private(set) var answer = ""
    @Published private(set) var step = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var focusRequest = 0

    var isBusy: Bool {
        phase == .sending || phase == .running
    }

    var hasConversation: Bool {
        !question.isEmpty
    }

    private let pollInterval: Duration = .milliseconds(1500)
    // About half a minute without an answer from the server
    private let failuresBeforeGivingUp = 20
    private var token: String?
    private var thread: String?
    private var task: Task<Void, Never>?
    private lazy var session = StarlaneManager.shared.makeSession(requestTimeout: 30, resourceTimeout: 60)

    private struct Page: Decodable {
        struct API: Decodable {
            let token: String
        }
        let api: API
    }

    private struct Job: Decodable {
        let id: String
        let status: String
        let thread: String?
        let result: String?
        let note: String?
    }

    private struct Reply: Decodable {
        let job: Job?
        let error: String?
    }

    private struct Live: Decodable {
        let text: String?
        let steps: [String]?
    }

    private enum ChatError: Error {
        case refused(String)
        case unreachable
        case expiredToken
    }

    private init() {}

    // MARK: - Actions
    func requestFocus() {
        focusRequest += 1
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }

        input = ""
        question = text
        answer = ""
        step = ""
        phase = .sending
        task = Task { await deliver(text) }
    }

    /// Forgets the conversation here. Atlas keeps it, so it stays readable in Starlane.
    func reset() {
        task?.cancel()
        task = nil
        input = ""
        question = ""
        answer = ""
        step = ""
        thread = nil
        phase = .idle
    }

    // MARK: - Talking to Starlane
    private func deliver(_ text: String) async {
        do {
            let job = try await post(text)
            thread = job.thread ?? job.id
            phase = .running
            await follow(job.id)
        } catch is CancellationError {
            return
        } catch ChatError.refused(let message) {
            fail(message, restoring: text)
        } catch {
            fail(String(localized: "Starlane isn't reachable (is Tailscale on?)"), restoring: text)
        }
    }

    private func fail(_ message: String, restoring text: String) {
        guard !Task.isCancelled else { return }
        if input.isEmpty {
            input = text
        }
        phase = .failed(message)
    }

    private func post(_ text: String) async throws -> Job {
        var body: [String: String] = ["instruction": text]
        if let thread {
            body["thread"] = thread
        }
        let data = try JSONSerialization.data(withJSONObject: body)

        let reply: Data
        do {
            reply = try await request("/api/atlas", method: "POST", body: data)
        } catch ChatError.expiredToken {
            // The token changes with every server start
            reply = try await request("/api/atlas", method: "POST", body: data)
        }
        guard let job = try JSONDecoder().decode(Reply.self, from: reply).job else {
            throw ChatError.unreachable
        }
        return job
    }

    private func follow(_ id: String) async {
        var failures = 0
        var tick = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return }
            tick += 1

            do {
                let live = try JSONDecoder().decode(Live.self, from: try await requestRetrying("/api/jobs/\(id)/live"))
                guard !Task.isCancelled else { return }
                if let text = live.text, !text.isEmpty {
                    answer = text
                }
                step = live.steps?.last ?? step

                // The full job is a read of the log, the live text only memory
                if tick % 2 == 0, let job = try JSONDecoder().decode(Reply.self, from: try await requestRetrying("/api/jobs/\(id)")).job,
                   job.status != "running", job.status != "queued" {
                    guard !Task.isCancelled else { return }
                    finish(job)
                    return
                }
                failures = 0
            } catch {
                failures += 1
                if failures >= failuresBeforeGivingUp {
                    phase = .failed(String(localized: "Lost the connection. The answer will still appear in Starlane."))
                    AtlasPromptController.shared.showAnswer()
                    return
                }
            }
        }
    }

    private func finish(_ job: Job) {
        step = ""
        if job.status == "ok" {
            answer = job.result ?? answer
            phase = .idle
        } else {
            let note = job.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            phase = .failed(note.isEmpty ? String(localized: "Atlas couldn't finish this.") : note)
        }
        AtlasPromptController.shared.showAnswer()
    }

    private func requestRetrying(_ path: String) async throws -> Data {
        do {
            return try await request(path)
        } catch ChatError.expiredToken {
            return try await request(path)
        }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let currentToken: String
        if let token {
            currentToken = token
        } else {
            currentToken = try await fetchToken()
            token = currentToken
        }
        guard let url = StarlaneManager.shared.url(path) else { throw ChatError.refused(notConfigured) }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue(currentToken, forHTTPHeaderField: "X-AOS-Token")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 202:
            return data
        case 401:
            token = nil
            throw ChatError.expiredToken
        default:
            let error = (try? JSONDecoder().decode(Reply.self, from: data))?.error
            throw ChatError.refused(error ?? String(localized: "Starlane refused this (\(status))."))
        }
    }

    private var notConfigured: String {
        String(localized: "Set up Starlane in the settings first.")
    }

    /// The token is in the page's data block; only the phone key opens the page.
    private func fetchToken() async throws -> String {
        guard let key = StarlaneKeychain.read("key"), let url = StarlaneManager.shared.url("/?k=\(key)") else {
            throw ChatError.refused(notConfigured)
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatError.refused(String(localized: "Refused: check the key and your Tailscale login"))
        }

        let page: Page? = await Task.detached(priority: .userInitiated) {
            guard let html = String(data: data, encoding: .utf8),
                  let open = html.range(of: #"<script[^>]*id="aos-data"[^>]*>"#, options: .regularExpression),
                  let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { return nil }
            return try? JSONDecoder().decode(Page.self, from: Data(html[open.upperBound..<close.lowerBound].utf8))
        }.value

        guard let page else {
            throw ChatError.refused(String(localized: "This Starlane version can't be talked to from here."))
        }
        return page.api.token
    }
}

// MARK: - Window
private final class AtlasPromptPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class AtlasPromptController {
    static let shared = AtlasPromptController()

    private let width: CGFloat = 560
    private let gapBelowNotch: CGFloat = 6
    private var panel: AtlasPromptPanel?
    private var resignObserver: Any?

    private init() {}

    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            hide()
        } else {
            show(focus: true)
        }
    }

    /// A running answer that finishes behind a closed line comes back, except over a video.
    func showAnswer() {
        guard panel?.isVisible != true, !FullscreenMediaDetector.shared.fullscreenStatus.values.contains(true) else { return }
        show(focus: false)
    }

    func hide() {
        panel?.orderOut(nil)
        if !AtlasChat.shared.isBusy {
            AtlasChat.shared.reset()
        }
    }

    private func show(focus: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel, height: panel.frame.height)

        if focus {
            panel.makeKeyAndOrderFront(nil)
            AtlasChat.shared.requestFocus()
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> AtlasPromptPanel {
        let panel = AtlasPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 4
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.hide() }

        let host = NSHostingView(rootView: AtlasPromptView { [weak self] height in
            self?.resize(to: height)
        })
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.addSubview(host)

        // Clicking elsewhere closes an empty line; an answer stays until it's dismissed
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if !AtlasChat.shared.hasConversation {
                    self?.hide()
                }
            }
        }
        return panel
    }

    private func resize(to height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        place(panel, height: height)
    }

    private func place(_ panel: NSPanel, height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = panel.isVisible ? (panel.screen ?? NSScreen.main) : (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
        guard let screen else { return }

        let notchHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let top = screen.frame.maxY - notchHeight - gapBelowNotch
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }
}

// MARK: - View
struct AtlasPromptView: View {
    @ObservedObject var chat = AtlasChat.shared
    @FocusState private var fieldFocused: Bool
    let onHeightChange: (CGFloat) -> Void

    private let maxAnswerHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.black)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.12))
                )
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
            Spacer(minLength: 0)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: chat.focusRequest) { fieldFocused = true }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.white)
                TextField("Ask Atlas…", text: $chat.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit { chat.send() }
                if chat.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                if chat.hasConversation {
                    Button {
                        StarlaneManager.shared.openDashboard()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(Text("Open Starlane"))
                    Button {
                        AtlasPromptController.shared.hide()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(Text("Close"))
                }
            }

            if chat.hasConversation {
                conversation
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chat.question)
                .font(.caption)
                .foregroundStyle(.gray)
                .lineLimit(2)

            if !chat.answer.isEmpty {
                ScrollView {
                    Text(rendered(chat.answer))
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxAnswerHeight)
            }

            if case .failed(let message) = chat.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if chat.isBusy {
                Text(chat.step.isEmpty ? String(localized: "Atlas is working…") : chat.step)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
        }
    }

    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
