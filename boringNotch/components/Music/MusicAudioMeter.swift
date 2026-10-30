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
import CoreAudio

@MainActor
final class MusicAudioMeter {
    static let shared = MusicAudioMeter()

    /// One level per bar from 0 to 1, low notes first. nil: nothing to show right now.
    typealias Listener = ([CGFloat]?) -> Void

    private let silenceBeforeGivingUp: TimeInterval = 1.5

    private var listeners: [ObjectIdentifier: Listener] = [:]
    private var bundleID: String?
    private var tap: AnyObject?
    private var startTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private var lastLevels: Date = .distantPast
    private var isShowingLevels = false

    private init() {}

    func add(_ owner: AnyObject, bundleID: String?, listener: @escaping Listener) {
        listeners[ObjectIdentifier(owner)] = listener
        self.bundleID = bundleID
        if tap == nil && startTask == nil {
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
        guard #available(macOS 14.2, *), let bundleID else { return }

        startTask = Task { [weak self] in
            // Setting up the tap can take a moment, and the first start asks for the permission
            let tap = await Task.detached(priority: .userInitiated) { () -> MusicAudioTap? in
                let processes = LocalAudioRoute.processes(for: bundleID)
                guard !processes.isEmpty, let outputUID = LocalAudioRoute.systemOutputUID else { return nil }
                return MusicAudioTap(processes: processes, outputUID: outputUID) { levels in
                    DispatchQueue.main.async { self?.deliver(levels) }
                }
            }.value
            self?.started(tap)
        }
    }

    @available(macOS 14.2, *)
    private func started(_ newTap: MusicAudioTap?) {
        startTask = nil
        guard !listeners.isEmpty else {
            if let newTap {
                Task.detached { newTap.stop() }
            }
            return
        }
        tap = newTap
        if newTap != nil {
            startSilenceTimer()
        }
    }

    private func stop() {
        startTask?.cancel()
        startTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        isShowingLevels = false
        if #available(macOS 14.2, *), let running = tap as? MusicAudioTap {
            Task.detached { running.stop() }
        }
        tap = nil
    }

    // MARK: - Levels
    private func deliver(_ levels: [CGFloat]) {
        guard tap != nil else { return }
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

/// Taps the sound of one app. Not ScreenCaptureKit: macOS takes any of its streams for sharing the screen and
/// silences every notification for as long as it runs.
@available(macOS 14.2, *)
private final class MusicAudioTap {
    private let description: CATapDescription
    private let analyzer: MusicAudioAnalyzer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init?(processes: [AudioObjectID], outputUID: String, onLevels: @escaping ([CGFloat]) -> Void) {
        description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Boring Notch bars"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        analyzer = MusicAudioAnalyzer(sampleRate: format.mSampleRate, onLevels: onLevels)

        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Boring Notch bars",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate) == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        aggregateID = aggregate

        let analyzer = analyzer
        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, analyzer.queue) { _, input, _, _, _ in
            analyzer.process(input)
        }
        guard created == noErr, let proc else {
            stop()
            return nil
        }
        procID = proc
        guard AudioDeviceStart(aggregate, proc) == noErr else {
            stop()
            return nil
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

/// Turns the sound into one level per bar. Runs on its own queue.
private final class MusicAudioAnalyzer {
    let queue = DispatchQueue(label: "boringNotch.musicAudioMeter", qos: .userInitiated)

    private static let log2Size: vDSP_Length = 11
    private static let size = 1 << 11
    // Where each bar starts and ends, in Hz: bass, low mids, mids, highs
    private static let bandEdges: [Float] = [60, 250, 1000, 4000, 14000]
    private static let quietestPeak: Float = 0.0005
    private static let smallestRangeInDecibels: Float = 8
    private static let limitDriftPerUpdate: Float = 0.08

    private let sampleRate: Float
    private let framesPerUpdate: Int
    private let onLevels: ([CGFloat]) -> Void
    private let setup = vDSP_create_fftsetup(MusicAudioAnalyzer.log2Size, FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: MusicAudioAnalyzer.size)
    private var samples: [Float] = []
    private var framesSinceUpdate = 0
    private var loudest = [Float](repeating: -200, count: MusicAudioAnalyzer.bandEdges.count - 1)
    private var quietest = [Float](repeating: 200, count: MusicAudioAnalyzer.bandEdges.count - 1)
    private var smoothed = [Float](repeating: 0, count: MusicAudioAnalyzer.bandEdges.count - 1)

    init(sampleRate: Double, onLevels: @escaping ([CGFloat]) -> Void) {
        self.sampleRate = Float(sampleRate)
        self.framesPerUpdate = Int(sampleRate) / 30
        self.onLevels = onLevels
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let mono = Self.mono(from: input) else { return }

        samples.append(contentsOf: mono)
        framesSinceUpdate += mono.count
        if samples.count > Self.size {
            samples.removeFirst(samples.count - Self.size)
        }
        guard samples.count == Self.size, framesSinceUpdate >= framesPerUpdate else { return }
        framesSinceUpdate = 0

        // Silence counts as no sound at all, so the bars can fall back
        guard vDSP.maximumMagnitude(samples) > Self.quietestPeak, let levels = analyze() else { return }
        onLevels(levels)
    }

    /// The channels of a buffer list mixed down to one, interleaved or not.
    private static func mono(from input: UnsafePointer<AudioBufferList>) -> [Float]? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return nil }

        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
        guard frames > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        var channels = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(buffer.mNumberChannels)
            for channel in 0..<stride {
                vDSP_vadd(data + channel, stride, mono, 1, &mono, 1, vDSP_Length(frames))
            }
            channels += stride
        }
        guard channels > 0 else { return nil }
        var scale = 1 / Float(channels)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
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

        let hertzPerBin = sampleRate / Float(Self.size)
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
