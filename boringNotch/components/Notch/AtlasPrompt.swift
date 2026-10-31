//
//  AtlasPrompt.swift
//  boringNotch
//
//  A line under the notch to talk to Atlas from anywhere.
//  It talks to Starlane the way the dashboard page does: the phone key loads the page, the page holds the
//  token of this server start, and the token authorizes the message. Messages carry no X-AOS-Key, so Atlas
//  can answer from here but can't open terminals. The token stays in memory.
//  A screenshot, the clipboard or a file only go along when asked for, one message at a time. Atlas sees them but
//  can't control this Mac.
//

import AppKit
import Combine
import Defaults
import ScreenCaptureKit
import SwiftUI

/// A picture of the screen under the mouse, without this app's own windows.
enum ScreenSnapshot {
    enum Failure: Error {
        case notAllowed
        case failed
    }

    // Claude shrinks anything bigger, and the dashboard sends no more than this either
    private static let longestSide: CGFloat = 2000

    @MainActor
    static func jpeg() async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw Failure.notAllowed
        }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            throw Failure.failed
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw Failure.failed
        }

        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let scale = min(CGFloat(filter.pointPixelScale), longestSide / CGFloat(max(display.width, display.height)))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)

        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw Failure.failed
        }
        return data
    }
}

struct AtlasAttachment: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
}

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
    @Published var includeScreen = false
    @Published private(set) var attachments: [AtlasAttachment] = []
    @Published var attachmentProblem = ""
    @Published private(set) var questionHasScreen = false
    @Published private(set) var questionFileCount = 0
    @Published private(set) var question = ""
    @Published private(set) var answer = "" {
        didSet {
            if answer != oldValue {
                renderedAnswer = Self.rendered(answer)
            }
        }
    }
    /// Parsed once per answer: the line redraws on every keystroke.
    private(set) var renderedAnswer = AttributedString()
    @Published private(set) var step = ""
    @Published private(set) var phase: Phase = .idle

    var isBusy: Bool {
        phase == .sending || phase == .running
    }

    var hasConversation: Bool {
        !question.isEmpty
    }

    // The server's own limits; it checks them again, along with the kinds of files it takes
    private let maxAttachments = 10
    private let pollInterval: Duration = .milliseconds(1500)
    // How long the server may stay silent during a job. Time the Mac sleeps doesn't count
    private let silenceBeforeGivingUp: Duration = .seconds(120)
    private var token: String?
    private var thread: String?
    // On their way, until the server has the message. Then they're gone: a job can run for many minutes
    private var sendingFiles: [AtlasAttachment] = []
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

    private struct Upload: Decodable {
        struct File: Decodable {
            let id: String
        }
        let file: File
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
    func attachClipboard() {
        attachmentProblem = ""
        let board = NSPasteboard.general
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            files.forEach(attach(file:))
        } else if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            attach(name: "clipboard.txt", data: Data(text.utf8))
        } else if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            attach(name: "clipboard.png", data: png)
        } else {
            attachmentProblem = String(localized: "The clipboard has nothing to send.")
        }
    }

    func attach(file url: URL) {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        // Read whole, not mapped: a file that gets shorter before it's sent would crash the app. So look at the size first
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxSize(of: url.lastPathComponent) else {
            attachmentProblem = String(localized: "\(url.lastPathComponent) is too large.")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            attachmentProblem = String(localized: "\(url.lastPathComponent) can't be read.")
            return
        }
        attach(name: url.lastPathComponent, data: data)
    }

    func remove(_ attachment: AtlasAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        attachmentProblem = ""
    }

    private func attach(name: String, data: Data) {
        guard attachments.count < maxAttachments else {
            attachmentProblem = String(localized: "At most \(maxAttachments) files per message.")
            return
        }
        guard data.count <= maxSize(of: name) else {
            attachmentProblem = String(localized: "\(name) is too large.")
            return
        }
        attachments.append(AtlasAttachment(name: name, data: data))
    }

    /// What the server takes per file. Besides images and PDFs it only takes text.
    private func maxSize(of name: String) -> Int {
        let kind = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(kind) {
            return 5 * 1024 * 1024
        }
        return kind == "pdf" ? 20 * 1024 * 1024 : 1024 * 1024
    }

    func send() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !text.isEmpty || !attachments.isEmpty || includeScreen else { return }
        if text.isEmpty {
            text = String(localized: "Look at what I attached.")
        }

        // Asked for one message at a time: nothing stays attached
        let withScreen = includeScreen
        sendingFiles = attachments
        includeScreen = false
        attachments = []
        attachmentProblem = ""
        questionHasScreen = withScreen
        questionFileCount = sendingFiles.count

        input = ""
        question = text
        answer = ""
        step = ""
        phase = .sending
        task = Task { await deliver(text, withScreen: withScreen) }
    }

    /// Forgets the conversation here. Atlas keeps it, so it stays readable in Starlane.
    func reset() {
        task?.cancel()
        task = nil
        input = ""
        includeScreen = false
        attachments = []
        sendingFiles = []
        attachmentProblem = ""
        questionHasScreen = false
        questionFileCount = 0
        question = ""
        answer = ""
        step = ""
        thread = nil
        phase = .idle
    }

    /// The address or key changed: the token and the conversation belong to the old server.
    func forgetServer() {
        reset()
        token = nil
    }

    // MARK: - Talking to Starlane
    private func deliver(_ text: String, withScreen: Bool) async {
        func failed(_ message: String, comesBack: Bool = true) {
            fail(message, comesBack: comesBack, restoring: text, withScreen: withScreen)
        }

        do {
            // The server answers a stale token without reading the upload, and through the proxy that 401 can get lost.
            // So an upload starts with a fresh token, for the price of one more look at the page
            if withScreen || !sendingFiles.isEmpty {
                token = nil
            }
            var ids = withScreen ? [try await uploadScreen()] : []
            for file in sendingFiles {
                ids.append(try await upload(file.data, name: file.name))
            }
            let job = try await post(text, files: ids)
            // Stopped while this was on its way: the conversation is already forgotten here
            try Task.checkCancellation()
            sendingFiles = []
            thread = job.thread ?? job.id
            phase = .running
            await follow(job.id)
        } catch is CancellationError {
            return
        } catch ChatError.refused(let message) {
            failed(message)
        } catch ScreenSnapshot.Failure.notAllowed {
            failed(String(localized: "Allow Screen Recording for Boring Notch in System Settings, then restart the app."))
        } catch is ScreenSnapshot.Failure {
            failed(String(localized: "The screenshot couldn't be taken."))
        } catch is DecodingError {
            failed(String(localized: "This Starlane version can't be talked to from here."))
        } catch {
            // Said in the line, for when it's open or next opened. No network never brings anything up by itself
            failed(String(localized: "Starlane isn't reachable (is Tailscale on?)"), comesBack: false)
        }
    }

    private func fail(_ message: String, comesBack: Bool, restoring text: String, withScreen: Bool) {
        guard !Task.isCancelled else { return }
        if input.isEmpty {
            input = text
        }
        includeScreen = includeScreen || withScreen
        attachments = sendingFiles + attachments
        sendingFiles = []
        phase = .failed(message)
        if comesBack {
            AtlasPromptController.shared.showAnswer()
        }
    }

    private func uploadScreen() async throws -> String {
        step = String(localized: "Taking a screenshot…")
        let jpeg = try await ScreenSnapshot.jpeg()
        step = ""
        return try await upload(jpeg, name: "screen.jpg")
    }

    private func upload(_ data: Data, name: String) async throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
        let reply = try await requestRetrying("/api/uploads?name=\(encoded)", method: "POST", body: data, contentType: "application/octet-stream")
        return try JSONDecoder().decode(Upload.self, from: reply).file.id
    }

    private func post(_ text: String, files: [String]) async throws -> Job {
        var body: [String: Any] = ["instruction": text]
        if let thread {
            body["thread"] = thread
        }
        if !files.isEmpty {
            body["files"] = files
        }
        let data = try JSONSerialization.data(withJSONObject: body)

        let reply = try await requestRetrying("/api/atlas", method: "POST", body: data)
        guard let job = try JSONDecoder().decode(Reply.self, from: reply).job else {
            throw ChatError.unreachable
        }
        return job
    }

    private func follow(_ id: String) async {
        let clock = SuspendingClock()
        var lastAnswer = clock.now
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
                lastAnswer = clock.now
            } catch {
                guard !Task.isCancelled else { return }
                // Said in the line, for when it's open or next opened. No network never brings anything up by itself
                if clock.now - lastAnswer > silenceBeforeGivingUp {
                    phase = .failed(String(localized: "Lost the connection. The answer will still appear in Starlane."))
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

    /// The token changes with every server start, so one refusal for it is worth one more try.
    private func requestRetrying(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        do {
            return try await request(path, method: method, body: body, contentType: contentType)
        } catch ChatError.expiredToken {
            return try await request(path, method: method, body: body, contentType: contentType)
        }
    }

    private func request(_ path: String, method: String, body: Data?, contentType: String) async throws -> Data {
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
        // The GETs are the polls of a job: a dead peer shouldn't hold one for the session's 30 s
        if method == "GET" {
            request.timeoutInterval = 10
        }
        request.setValue(currentToken, forHTTPHeaderField: "X-AOS-Token")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 201, 202:
            return data
        case 401:
            token = nil
            throw ChatError.expiredToken
        default:
            if let error = (try? JSONDecoder().decode(Reply.self, from: data))?.error {
                throw ChatError.refused(error)
            }
            // Without the server's own words, a 5xx is the proxy saying that the server is gone (a 502 when it's stopped)
            throw status >= 500 ? ChatError.unreachable : ChatError.refused(String(localized: "Starlane refused this (\(status))."))
        }
    }

    private var notConfigured: String {
        String(localized: "Set up Starlane in the settings first.")
    }

    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The token is in the page's data block; only the phone key opens the page.
    private func fetchToken() async throws -> String {
        guard let key = StarlaneKeychain.read("key"), let url = StarlaneManager.shared.url("/?k=\(key)") else {
            throw ChatError.refused(notConfigured)
        }
        let (data, response) = try await session.data(from: url)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            break
        case 401, 403:
            throw ChatError.refused(String(localized: "Refused: check the key and your Tailscale login"))
        default:
            // A stopped server (502) or one without its vault (500): nothing wrong with the key
            throw ChatError.unreachable
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
    private var panel: AtlasPromptPanel?
    private var placedFrame: NSRect = .zero
    private var pendingAnswer = false
    private var fullscreenCancellable: AnyCancellable?

    private init() {
        fullscreenCancellable = FullscreenMediaDetector.shared.$fullscreenStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                if self?.pendingAnswer == true {
                    self?.showAnswer()
                }
            }
    }

    /// Where the line is, while it's up. The notification card sits below it.
    var lineFrame: NSRect? {
        panel?.isVisible == true ? placedFrame : nil
    }

    func open() {
        show(focus: true)
    }

    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            hide()
        } else {
            show(focus: true)
        }
    }

    /// A running answer that finishes behind a closed line comes back. Over a video it waits until the video is gone.
    func showAnswer() {
        guard panel?.isVisible != true, AtlasChat.shared.hasConversation else { return }
        guard !FullscreenMediaDetector.shared.hidesClosedNotch else {
            pendingAnswer = true
            return
        }
        show(focus: false)
    }

    func notchMoved() {
        if let panel, panel.isVisible {
            place(panel, height: panel.frame.height, animated: true)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        NotificationCardController.shared.reposition()
        if !AtlasChat.shared.isBusy {
            AtlasChat.shared.reset()
        }
    }

    private func show(focus: Bool) {
        pendingAnswer = false
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel, height: panel.frame.height)

        if focus {
            panel.makeKeyAndOrderFront(nil)
            focusField(in: panel)
        } else {
            panel.orderFrontRegardless()
        }
        NotificationCardController.shared.reposition()
    }

    /// SwiftUI still takes the field for focused after the line was hidden, so this asks AppKit directly.
    /// A new line's field takes a moment to exist.
    private func focusField(in panel: NSPanel) {
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

    private func makePanel() -> AtlasPromptPanel {
        let panel = AtlasPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        NotchPanelLayout.shared.configure(panel)
        panel.hasShadow = true
        panel.onCancel = { [weak self] in self?.hide() }

        let host = NSHostingView(rootView: AtlasPromptView { [weak self] height in
            self?.resize(to: height)
        })
        NotchPanelLayout.shared.embed(host, in: panel)

        return panel
    }

    private func resize(to height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        place(panel, height: height)
    }

    private func place(_ panel: NSPanel, height: CGFloat, animated: Bool = false) {
        let layout = NotchPanelLayout.shared
        guard let screen = layout.screen(for: panel) else { return }

        let top = layout.notchBottom(on: screen) - layout.gapBelowNotch
        let frame = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        placedFrame = frame
        layout.move(panel, to: frame, animated: animated)
        NotificationCardController.shared.reposition()
    }
}

// MARK: - View
struct AtlasPromptView: View {
    @ObservedObject var chat = AtlasChat.shared
    @FocusState private var fieldFocused: Bool
    @State private var isDropTarget = false
    let onHeightChange: (CGFloat) -> Void

    private let maxAnswerHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .smokedGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.orange, lineWidth: 2)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
                    chat.attachmentProblem = ""
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            Task { @MainActor in chat.attach(file: url) }
                        }
                    }
                    return true
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
            Spacer(minLength: 0)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: chat.includeScreen) { fieldFocused = true }
        .onChange(of: chat.attachments.count) { fieldFocused = true }
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
                Button {
                    chat.includeScreen.toggle()
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .foregroundStyle(chat.includeScreen ? .orange : .gray)
                }
                .buttonStyle(PlainButtonStyle())
                .help(Text("Send this screen with the next message"))
                Button {
                    chat.attachClipboard()
                    fieldFocused = true
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.gray)
                }
                .buttonStyle(PlainButtonStyle())
                .help(Text("Send the clipboard with the next message"))
                if chat.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Button {
                        chat.reset()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(Text("Stop waiting here. What Atlas already has still gets its answer in Starlane."))
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
                }
                Button {
                    AtlasPromptController.shared.hide()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.gray)
                }
                .buttonStyle(PlainButtonStyle())
                .help(Text("Close"))
            }

            if chat.includeScreen {
                Text("A screenshot of this screen goes with your next message.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.attachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                }
            }

            if !chat.attachmentProblem.isEmpty {
                Text(chat.attachmentProblem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if chat.hasConversation {
                conversation
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func attachmentChip(_ attachment: AtlasAttachment) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "paperclip")
            Text(attachment.name)
                .lineLimit(1)
            Button {
                chat.remove(attachment)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(PlainButtonStyle())
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.15)))
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if chat.questionHasScreen {
                    Image(systemName: "camera.viewfinder")
                }
                if chat.questionFileCount > 0 {
                    Image(systemName: "paperclip")
                }
                Text(chat.question)
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.gray)

            if !chat.answer.isEmpty {
                ScrollView {
                    Text(chat.renderedAnswer)
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
}
