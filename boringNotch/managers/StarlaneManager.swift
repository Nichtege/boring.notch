//
//  StarlaneManager.swift
//  boringNotch
//
//  Reads the status of the Starlane dashboard (GET /api/notch) over Tailscale.
//  This status is read-only; the one thing the notch sends is what you type into the Atlas line (AtlasPrompt.swift).
//

import AppKit
import Combine
import Defaults
import Security
import SwiftUI

struct StarlaneSummary: Decodable, Equatable {
    struct Terminal: Decodable, Equatable {
        let id: String?
        let name: String
        let state: String
    }

    struct LimitWindow: Decodable, Equatable {
        let window: String
        let usedPercent: Double
        let resetsAt: Double

        enum CodingKeys: String, CodingKey {
            case window
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
        }

        var shortName: String {
            if window.contains("five") { return "5 h" }
            if window.contains("seven") { return "7 d" }
            return window
        }
    }

    struct Deadline: Decodable, Equatable {
        let title: String
        let date: String
    }

    let live: Int
    let busy: Int
    let needs: Int
    let done: Int
    let paused: Int
    let limited: Int
    let terminals: [Terminal]
    let nextDeadline: Deadline?
    let limit: [LimitWindow]?

    enum CodingKeys: String, CodingKey {
        case live, busy, needs, done, paused, limited, terminals, limit
        case nextDeadline = "next_deadline"
    }

    var needsNames: [String] {
        terminals.filter { $0.state == "needs" }.map(\.name)
    }
}

enum StarlaneStatus: Equatable {
    case notConfigured
    case paused
    case connecting
    case connected
    case unreachable
    case rejected
    case serverOutdated
}

/// The server address and phone key, kept only in the macOS keychain.
enum StarlaneKeychain {
    private static let service = "com.nichtege.boringnotch.starlane"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }

        var newItem = query
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        newItem[kSecValueData as String] = data
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class StarlaneManager: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = StarlaneManager()

    @Published private(set) var summary: StarlaneSummary?
    @Published private(set) var status: StarlaneStatus = .notConfigured
    @Published private(set) var newlyNeedingName: String = ""

    private let pollInterval: Duration = .seconds(30)
    // One failed request (a moment without network) shouldn't make the tab flicker
    private let failuresBeforeHiding = 3
    private var failures = 0
    private var pollTask: Task<Void, Never>?
    private var enabledCancellable: AnyCancellable?
    private var knownNeeds: Set<String>?

    private lazy var session = makeSession(requestTimeout: 10, resourceTimeout: 15)

    /// No disk cache, no cookies, and (see below) no redirects: this session carries the key and the token.
    func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    var hasCredentials: Bool {
        StarlaneKeychain.read("address") != nil && StarlaneKeychain.read("key") != nil
    }

    var savedAddress: String {
        StarlaneKeychain.read("address") ?? ""
    }

    private override init() {
        super.init()
        enabledCancellable = Defaults.publisher(.starlaneEnabled, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restart() }
        restart()
    }

    // MARK: - Settings
    /// Accepts the bare name, an https address or the whole phone link (then the key comes with it).
    static func parse(address: String, key: String) -> (host: String, key: String)? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var key = key.trimmingCharacters(in: .whitespacesAndNewlines)

        let original = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: original), components.scheme != nil {
            guard components.scheme?.lowercased() == "https", components.port == nil,
                  let host = components.host else { return nil }
            text = host.lowercased()
            if key.isEmpty, let fromLink = components.queryItems?.first(where: { $0.name == "k" })?.value {
                key = fromLink
            }
        }

        let hostPattern = #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\.ts\.net\z"#
        let keyPattern = #"^[A-Za-z0-9_-]{32,64}\z"#
        guard text.range(of: hostPattern, options: .regularExpression) != nil,
              key.range(of: keyPattern, options: .regularExpression) != nil else { return nil }
        return (text, key)
    }

    func save(host: String, key: String) -> Bool {
        guard StarlaneKeychain.write(host, account: "address"),
              StarlaneKeychain.write(key, account: "key") else { return false }
        restart()
        return true
    }

    func removeCredentials() {
        StarlaneKeychain.delete("address")
        StarlaneKeychain.delete("key")
        restart()
    }

    /// With a terminal's id, the dashboard opens right at that terminal.
    func openDashboard(terminal: String? = nil) {
        guard let host = StarlaneKeychain.read("address"), let key = StarlaneKeychain.read("key"),
              var components = URLComponents(string: "https://\(host)/") else { return }
        components.queryItems = [URLQueryItem(name: "k", value: key)]
        if let terminal, terminal.range(of: #"^[a-f0-9]{8}\z"#, options: .regularExpression) != nil {
            components.fragment = "terminals:\(terminal)"
        }
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Polling
    private func restart() {
        pollTask?.cancel()
        pollTask = nil
        clear()

        guard hasCredentials else {
            status = .notConfigured
            return
        }
        guard Defaults[.starlaneEnabled] else {
            status = .paused
            return
        }

        status = .connecting
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func clear() {
        failures = 0
        knownNeeds = nil
        summary = nil
        if BoringViewCoordinator.shared.currentView == .starlane {
            BoringViewCoordinator.shared.currentView = .home
        }
    }

    func url(_ path: String) -> URL? {
        StarlaneKeychain.read("address").flatMap { URL(string: "https://\($0)\(path)") }
    }

    private func fetch() async {
        guard let key = StarlaneKeychain.read("key"), let url = url("/api/notch") else {
            clear()
            status = .notConfigured
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(key, forHTTPHeaderField: "X-AOS-Key")

        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return }
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                apply(try JSONDecoder().decode(StarlaneSummary.self, from: data))
            case 401, 403:
                clear()
                status = .rejected
            case 404:
                clear()
                status = .serverOutdated
            default:
                failed()
            }
        } catch {
            guard !Task.isCancelled else { return }
            failed()
        }
    }

    private func apply(_ newSummary: StarlaneSummary) {
        failures = 0
        status = .connected

        let needs = Set(newSummary.needsNames)
        if let known = knownNeeds, let name = newSummary.needsNames.first(where: { !known.contains($0) }) {
            newlyNeedingName = name
            if Defaults[.starlaneBanner] && !FocusTimer.shared.holdsBanners {
                BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .starlane)
            }
        }
        knownNeeds = needs

        if summary != newSummary {
            withAnimation(.smooth) {
                summary = newSummary
            }
        }
    }

    private func failed() {
        failures += 1
        status = .unreachable
        if failures >= failuresBeforeHiding {
            clear()
        }
    }

    // The key travels in a header, so never follow a redirect to another address
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
