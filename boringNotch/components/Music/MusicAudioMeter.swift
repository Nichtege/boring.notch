//
//  MusicAudioMeter.swift
//  boringNotch
//
//  Real levels of what the music app plays, for the bars in the notch.
//  Only the app that plays is listened to, and only while the bars are on screen. The sound is analyzed as it
//  passes and never kept. No sound (no permission, or none reaches this Mac) means nil, and the bars animate as before.
//

import Accelerate
import AppKit
import CoreMedia
import ScreenCaptureKit

@MainActor
final class MusicAudioMeter {
    static let shared = MusicAudioMeter()

    /// One level per bar from 0 to 1, low notes first. nil: nothing to show right now.
    typealias Listener = ([CGFloat]?) -> Void

    private let silenceBeforeGivingUp: TimeInterval = 1.5

    private var listeners: [ObjectIdentifier: Listener] = [:]
    private var bundleID: String?
    private var stream: SCStream?
    private var analyzer: MusicAudioAnalyzer?
    private var startTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private var lastLevels: Date = .distantPast
    private var isShowingLevels = false

    private init() {}

    func add(_ owner: AnyObject, bundleID: String?, listener: @escaping Listener) {
        listeners[ObjectIdentifier(owner)] = listener
        self.bundleID = bundleID
        if stream == nil && startTask == nil {
            start()
        }
    }

    func remove(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
        if listeners.isEmpty {
            stop()
        }
    }

    // MARK: - Capture
    private func start() {
        guard let bundleID else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // macOS only ever shows this question once
            CGRequestScreenCaptureAccess()
            return
        }

        startTask = Task { [weak self] in
            await self?.startStream(for: bundleID)
            self?.startTask = nil
        }
    }

    private func startStream(for bundleID: String) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !Task.isCancelled, !listeners.isEmpty,
                  let display = content.displays.first,
                  let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else { return }

            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = MusicAudioAnalyzer.sampleRate
            configuration.channelCount = 2
            // The stream has to have a picture too, so it's the smallest and slowest there is
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let analyzer = MusicAudioAnalyzer { [weak self] levels in
                DispatchQueue.main.async { self?.deliver(levels) }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: analyzer)
            try stream.addStreamOutput(analyzer, type: .audio, sampleHandlerQueue: analyzer.queue)
            try stream.addStreamOutput(analyzer, type: .screen, sampleHandlerQueue: analyzer.queue)
            try await stream.startCapture()

            guard !Task.isCancelled, !listeners.isEmpty else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            self.analyzer = analyzer
            startSilenceTimer()
        } catch {
            stop()
        }
    }

    private func stop() {
        startTask?.cancel()
        startTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        isShowingLevels = false
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        analyzer = nil
    }

    // MARK: - Levels
    private func deliver(_ levels: [CGFloat]) {
        guard stream != nil else { return }
        lastLevels = Date()
        isShowingLevels = true
        listeners.values.forEach { $0(levels) }
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowingLevels,
                      Date().timeIntervalSince(self.lastLevels) > self.silenceBeforeGivingUp else { return }
                self.isShowingLevels = false
                self.listeners.values.forEach { $0(nil) }
            }
        }
    }
}

/// Turns the sound into one level per bar. Runs on its own queue.
private final class MusicAudioAnalyzer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let sampleRate = 48000

    let queue = DispatchQueue(label: "boringNotch.musicAudioMeter")

    private static let log2Size: vDSP_Length = 11
    private static let size = 1 << 11
    private static let framesPerUpdate = sampleRate / 30
    // Where each bar starts and ends, in Hz: bass, low mids, mids, highs
    private static let bandEdges: [Float] = [60, 250, 1000, 4000, 14000]
    private static let quietestPeak: Float = 0.0005
    private static let smallestRangeInDecibels: Float = 8
    private static let limitDriftPerUpdate: Float = 0.08

    private let onLevels: ([CGFloat]) -> Void
    private let setup = vDSP_create_fftsetup(MusicAudioAnalyzer.log2Size, FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: MusicAudioAnalyzer.size)
    private var samples: [Float] = []
    private var framesSinceUpdate = 0
    private var loudest = [Float](repeating: -200, count: MusicAudioAnalyzer.bandEdges.count - 1)
    private var quietest = [Float](repeating: 200, count: MusicAudioAnalyzer.bandEdges.count - 1)
    private var smoothed = [Float](repeating: 0, count: MusicAudioAnalyzer.bandEdges.count - 1)

    init(onLevels: @escaping ([CGFloat]) -> Void) {
        self.onLevels = onLevels
        super.init()
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let mono = Self.mono(from: sampleBuffer) else { return }

        samples.append(contentsOf: mono)
        framesSinceUpdate += mono.count
        if samples.count > Self.size {
            samples.removeFirst(samples.count - Self.size)
        }
        guard samples.count == Self.size, framesSinceUpdate >= Self.framesPerUpdate else { return }
        framesSinceUpdate = 0

        // Silence counts as no sound at all, so the bars can fall back
        guard (vDSP.maximumMagnitude(samples)) > Self.quietestPeak, let levels = analyze() else { return }
        onLevels(levels)
    }

    /// The channels of a buffer mixed down to one, as floats.
    private static func mono(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return nil }

        let memory = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first else { return nil }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        var mono = [Float](repeating: 0, count: count)
        for buffer in buffers {
            guard let data = buffer.mData?.bindMemory(to: Float.self, capacity: count) else { continue }
            vDSP_vadd(mono, 1, data, 1, &mono, 1, vDSP_Length(count))
        }
        var scale = 1 / Float(buffers.count)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(count))
        return mono
    }

    private func analyze() -> [CGFloat]? {
        guard let setup else { return nil }
        let halfSize = Self.size / 2
        var windowed = [Float](repeating: 0, count: Self.size)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))

        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2Size, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        let hertzPerBin = Float(Self.sampleRate) / Float(Self.size)
        var levels: [CGFloat] = []
        for band in 0..<smoothed.count {
            let low = max(1, Int(Self.bandEdges[band] / hertzPerBin))
            let high = min(halfSize, max(low + 1, Int(Self.bandEdges[band + 1] / hertzPerBin)))
            let mean = vDSP.mean(magnitudes[low..<high])
            let decibels = 20 * log10(max(mean, 1e-7))

            // Each bar measures between its own recent quietest and loudest, so every song fills the whole height
            loudest[band] = max(decibels, loudest[band] - Self.limitDriftPerUpdate)
            quietest[band] = min(decibels, quietest[band] + Self.limitDriftPerUpdate)
            let range = max(loudest[band] - quietest[band], Self.smallestRangeInDecibels)
            let level = min(1, max(0, (decibels - quietest[band]) / range))
            let shaped = level * level

            // Up at once, down slowly, as a level meter does
            let speed: Float = shaped > smoothed[band] ? 0.7 : 0.25
            smoothed[band] += (shaped - smoothed[band]) * speed
            levels.append(CGFloat(smoothed[band]))
        }
        return levels
    }
}
