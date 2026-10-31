//
//  RemoteNowPlayingController.swift
//  boringNotch
//
//  What other devices play: the iPhone on whichever speaker that is, or a HomePod by itself.
//

import Combine
import Foundation

struct RemoteNowPlaying: Equatable {
    let state: PlaybackState
    let deviceName: String

    static func iconName(for deviceName: String) -> String {
        if deviceName.localizedCaseInsensitiveContains("iPhone") { return "iphone" }
        if deviceName.localizedCaseInsensitiveContains("iPad") { return "ipad" }
        return "homepod.fill"
    }
}

/// macOS answers MediaRemote only for its own programs, so the adapter runs inside /usr/bin/perl. It tells of changes
/// by itself. With no other device in reach, or on a macOS that doesn't allow this, there's simply nothing to show.
final class RemoteNowPlayingController {
    enum Command {
        case toggle, next, previous
        case skip(seconds: Int)

        fileprivate var line: String {
            switch self {
            case .toggle: return "toggle"
            case .next: return "next"
            case .previous: return "previous"
            case .skip(let seconds): return seconds < 0 ? "backward \(-seconds)" : "forward \(seconds)"
            }
        }
    }

    private struct Update: Decodable {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var stamp: Double?
        var item: String?
        var device: String?
        var app: String?
        var artwork: String?
    }

    @Published private(set) var nowPlaying: RemoteNowPlaying?

    private let restartDelay: Duration = .seconds(30)
    private let triesBeforeGivingUp = 5

    private var process: Process?
    private var input: FileHandle?
    private var failures = 0
    private var buffer = Data()
    private var artwork: Data?
    private var artworkItem: String?

    init() {
        start()
    }

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }

    func send(_ command: Command) {
        guard process?.isRunning == true, let data = (command.line + "\n").data(using: .utf8) else { return }
        try? input?.write(contentsOf: data)
    }

    private func start() {
        guard let adapter = Bundle.main.url(forResource: "libRemoteNowPlayingAdapter", withExtension: "dylib") else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            """
            use DynaLoader;
            my $library = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1;
            my $symbol = DynaLoader::dl_find_symbol($library, "run") or exit 1;
            DynaLoader::dl_install_xsub("main::run", $symbol);
            main::run();
            """,
            adapter.path,
        ]

        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        // If it's gone a command is lost, and that mustn't take the notch with it
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                self?.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.stopped()
            }
        }

        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func stopped() {
        nowPlaying = nil
        buffer.removeAll()
        artwork = nil
        artworkItem = nil
        failures += 1
        guard failures < triesBeforeGivingUp else { return }
        Task { @MainActor [weak self, restartDelay] in
            try? await Task.sleep(for: restartDelay)
            self?.start()
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<end]
            if let update = try? JSONDecoder().decode(Update.self, from: line) {
                failures = 0
                apply(update)
            }
            buffer.removeSubrange(buffer.startIndex...end)
        }
    }

    private func apply(_ update: Update) {
        guard let title = update.title else {
            nowPlaying = nil
            return
        }

        // The cover comes once and can be a moment late, so it stays until the item changes
        if let encoded = update.artwork, let data = Data(base64Encoded: encoded) {
            artwork = data
        } else if update.item != artworkItem {
            artwork = nil
        }
        artworkItem = update.item

        let rate = update.rate ?? 0
        var state = PlaybackState(bundleIdentifier: update.app ?? "")
        state.isPlaying = rate > 0
        state.title = title
        state.artist = update.artist ?? ""
        state.album = update.album ?? ""
        state.currentTime = update.elapsed ?? 0
        state.duration = update.duration ?? 0
        state.playbackRate = rate > 0 ? rate : 1
        state.lastUpdated = update.stamp.map(Date.init(timeIntervalSince1970:)) ?? Date()
        state.artwork = artwork
        nowPlaying = RemoteNowPlaying(state: state, deviceName: update.device ?? "")
    }
}
