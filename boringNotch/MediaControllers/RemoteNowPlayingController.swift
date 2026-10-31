//
//  RemoteNowPlayingController.swift
//  boringNotch
//
//  What other devices play: the iPhone on whichever speaker that is, or a HomePod by itself.
//

import AppKit
import Combine

struct RemoteNowPlaying {
    let state: PlaybackState
    let deviceName: String
    let cover: NSImage?

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

        fileprivate func line(for device: String) -> String {
            switch self {
            case .toggle: return "toggle\t\(device)"
            case .next: return "next\t\(device)"
            case .previous: return "previous\t\(device)"
            case .skip(let seconds):
                return seconds < 0 ? "backward\t\(device)\t\(-seconds)" : "forward\t\(device)\t\(seconds)"
            }
        }
    }

    private struct Update: Decodable {
        var devices: [Device]
    }

    private struct Device: Decodable {
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

    @Published private(set) var devices: [RemoteNowPlaying] = []

    private let restartDelay: Duration = .seconds(30)
    private let triesBeforeGivingUp = 5

    private var process: Process?
    private var input: FileHandle?
    private var failures = 0
    private var buffer = Data()
    private var covers: [String: (item: String?, data: Data?, image: NSImage?)] = [:]

    init() {
        start()
    }

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }

    func send(_ command: Command, to device: String) {
        write(command.line(for: device))
    }

    /// For when a device may just have come. macOS doesn't tell of those.
    func refresh() {
        write("refresh")
    }

    private func write(_ line: String) {
        guard process?.isRunning == true, let data = (line + "\n").data(using: .utf8) else { return }
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
        devices = []
        buffer.removeAll()
        covers = [:]
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
                devices = update.devices.compactMap(nowPlaying)
            }
            buffer.removeSubrange(buffer.startIndex...end)
        }
    }

    private func nowPlaying(_ update: Device) -> RemoteNowPlaying? {
        guard let title = update.title else { return nil }
        let deviceName = update.device ?? ""

        // The cover comes once and can be a moment late, so it stays until the item changes
        let known = covers[deviceName]?.item == update.item ? covers[deviceName] : nil
        var artwork = known?.data
        var cover = known?.image
        if let encoded = update.artwork, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
            artwork = data
            cover = image
        }
        covers[deviceName] = (update.item, artwork, cover)

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
        return RemoteNowPlaying(state: state, deviceName: deviceName, cover: cover)
    }
}
