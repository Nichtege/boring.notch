//
//  LyricsManager.swift
//  boringNotch
//
//  Time-synced lyrics for the current song from LRCLIB, which is free and needs no key.
//  Asked once per song, and only while something shows lyrics.
//

import Combine
import CryptoKit
import Defaults
import Foundation

struct LyricLine: Equatable, Identifiable {
    let id: Int
    let time: TimeInterval
    let text: String
}

@MainActor
final class LyricsManager: ObservableObject {
    static let shared = LyricsManager()

    /// Empty when the song has no synced lyrics, or nothing asks for them
    @Published private(set) var lines: [LyricLine] = []

    private var cancellables = Set<AnyCancellable>()
    private var loadedSong: String?
    private var fetchTask: Task<Void, Never>?
    /// Songs already asked about since launch, with nil for those without synced lyrics
    private var known: [String: [LyricLine]?] = [:]

    private init() {
        let music = MusicManager.shared
        music.$songTitle
            .combineLatest(music.$artistName)
            .map { "\($0)\n\($1)" }
            .removeDuplicates()
            // Title and artist arrive one after the other, and the length a moment later
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.lyricsInNotch, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
    }

    /// Lyrics cost a request, so they're only fetched for someone.
    private var isWanted: Bool {
        if Defaults[.lyricsInNotch] { return true }
        let lock = LockScreenController.shared
        guard lock.isLive, Defaults[.lockScreenWidgets] else { return false }
        if Defaults[.lockScreenFullCover], Defaults[.lockScreenCoverLayout] == .side { return true }
        return LockProfiles.active.widgets.contains { $0.kind == .lyrics }
    }

    /// Loads the current song's lyrics unless they're already there. Also called when the screen locks.
    func refresh() {
        let music = MusicManager.shared
        let title = music.songTitle.trimmingCharacters(in: .whitespaces)
        let artist = music.artistName.trimmingCharacters(in: .whitespaces)
        guard isWanted, !title.isEmpty, music.isPlaying || !music.isPlayerIdle else {
            fetchTask?.cancel()
            loadedSong = nil
            lines = []
            return
        }

        let song = "\(title)\n\(artist)"
        guard song != loadedSong else { return }
        loadedSong = song
        fetchTask?.cancel()

        if let cached = known[song] {
            lines = cached ?? []
            return
        }
        lines = []
        let album = music.album
        let duration = music.songDuration
        fetchTask = Task {
            let result = await Self.load(title: title, artist: artist, album: album, duration: duration)
            guard !Task.isCancelled, loadedSong == song else { return }
            if case .found(let found) = result {
                known[song] = found
                lines = found ?? []
            } else {
                // No answer at all: ask again the next time this song comes up
                loadedSong = nil
            }
        }
    }

    /// The line being sung at that moment, or nil before the first one.
    func index(at position: TimeInterval) -> Int? {
        // A touch early, so the line is there when its first word is
        let position = position + 0.25
        guard let first = lines.first, position >= first.time else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].time <= position {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    // MARK: - Loading

    private enum LoadResult {
        /// nil when the song is known to have no synced lyrics
        case found([LyricLine]?)
        case failed
    }

    private struct Entry: Decodable {
        let duration: Double?
        let syncedLyrics: String?
    }

    private static func load(title: String, artist: String, album: String, duration: TimeInterval) async -> LoadResult {
        let file = cacheFile(for: "\(title)\n\(artist)")
        if let file, let saved = try? String(contentsOf: file, encoding: .utf8) {
            let lines = parse(saved)
            return .found(lines.isEmpty ? nil : lines)
        }

        var exact = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.isEmpty {
            exact.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 0 {
            exact.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }

        var synced: String?
        switch await request("get", exact, as: Entry.self) {
        case .value(let entry):
            synced = entry.syncedLyrics
        case .failed:
            return .failed
        case .missing:
            break
        }

        if synced == nil {
            // The exact lookup wants album and length to match. The search is more forgiving.
            let loose = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
            switch await request("search", loose, as: [Entry].self) {
            case .value(let entries):
                let candidates = entries.filter { $0.syncedLyrics != nil }
                let best = candidates.min {
                    abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration)
                }
                // Another version of the song would run out of step
                if let best, duration <= 0 || abs((best.duration ?? duration) - duration) <= 4 {
                    synced = best.syncedLyrics
                }
            case .failed:
                return .failed
            case .missing:
                break
            }
        }

        let lines = synced.map(parse) ?? []
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Also when there are none, so the same song isn't asked about every day
            try? (lines.isEmpty ? "" : synced ?? "").write(to: file, atomically: true, encoding: .utf8)
        }
        return .found(lines.isEmpty ? nil : lines)
    }

    private enum Response<Value> {
        case value(Value)
        case missing
        case failed
    }

    private static func request<Value: Decodable>(_ path: String, _ query: [URLQueryItem], as type: Value.Type) async -> Response<Value> {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query
        guard let url = components.url else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 12)
        // LRCLIB asks clients to say who they are
        request.setValue("BoringNotch (https://github.com/Nichtege/boring.notch)", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failed }
        if status == 404 { return .missing }
        guard status == 200, let value = try? JSONDecoder().decode(type, from: data) else { return .failed }
        return .value(value)
    }

    private static func cacheFile(for song: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let name = SHA256.hash(data: Data(song.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("Lyrics", isDirectory: true).appendingPathComponent("\(name).lrc")
    }

    /// Reads `[mm:ss.xx] text` lines. A line can carry several times, and tags like `[ar:…]` are skipped.
    static func parse(_ lrc: String) -> [LyricLine] {
        var timed: [(TimeInterval, String)] = []
        for rawLine in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine)
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { break }
                times.append(minutes * 60 + seconds)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            timed.append(contentsOf: times.map { ($0, text) })
        }
        return timed
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
