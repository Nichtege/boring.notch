//
//  AppVolumeMixer.swift
//  boringNotch
//
//  One volume per app, for the Mixer tab. An app at 100% gets nothing at all. Only an app that is turned down and
//  really plays gets a tap and an aggregate device, as a running one holds the output: AirPods held like that
//  no longer switch or pause by themselves. The sound only passes through, nothing of it is kept.
//
//  How the tap and the aggregate are put together is derived from FineTune, see THIRD_PARTY_LICENSES.
//

import AppKit
import CoreAudio
import Defaults

private let appVolumeQueue = DispatchQueue(label: "boringNotch.appVolumeMixer", qos: .userInitiated)

@MainActor
final class AppVolumeMixer: ObservableObject {
    static let shared = AppVolumeMixer()

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: NSImage
        let volume: Double
        let isFailing: Bool
    }

    private struct ActiveTap {
        let tap: AppVolumeTap
        var processes: Set<AudioObjectID>
        var removal: DispatchWorkItem?
        var rebuild: DispatchWorkItem?
    }

    // Kept up to date only while the tab is on screen
    @Published private(set) var rows: [Row] = []
    @Published private(set) var music: NSRunningApplication?
    @Published private(set) var macVolume: Double = 0
    @Published private(set) var macIcon = "hifispeaker.fill"

    // Never in the list: this app, Music with a volume of its own, and FineTune with taps of its own
    private static let notMixed: Set<String> = [Bundle.main.bundleIdentifier ?? "", "com.apple.Music", "com.finetuneapp.FineTune"]
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private let lingerAfterSound: TimeInterval = 3
    private let removalAfterRamp: TimeInterval = 0.1
    private let outputSettleTime: TimeInterval = 0.4
    private let rebuildSettleTime: TimeInterval = 0.1
    private let rowLinger: TimeInterval = 4
    private let retryDelay: TimeInterval = 2
    private let triesAfterFailure = 2

    private var volumes = Defaults[.appVolumes]
    private var viewers = 0
    private var active: [String: ActiveTap] = [:]
    private var failed: Set<String> = []
    private var retries: [String: Int] = [:]
    private var movedSliders: Set<String> = []
    private var lastHeard: [String: Date] = [:]

    private var isListeningToProcesses = false
    private var watchedProcesses: Set<AudioObjectID> = []
    private var owners: [AudioObjectID: NSRunningApplication] = [:]
    private var isRefreshScheduled = false
    private var appObservers: [NSObjectProtocol] = []

    private var isWatchingOutput = false
    private var watchedDevice = AudioObjectID(kAudioObjectUnknown)
    private var outputChange: DispatchWorkItem?

    private lazy var processListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.setNeedsRefresh()
    }
    private lazy var outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.outputChanged()
    }
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshMacRow()
    }

    private init() {
        updateListening()
        refresh()
    }

    // MARK: - The tab
    func tabAppeared() {
        viewers += 1
        updateListening()
        refresh()
        refreshMacRow()
    }

    func tabDisappeared() {
        viewers -= 1
        if !movedSliders.isEmpty {
            saveVolumes()
        }
        updateListening()
    }

    /// More rows than fit. The list then scrolls with the same two fingers as the swipe that closes the notch.
    var scrolls: Bool {
        rows.count + (music == nil ? 1 : 2) > 6
    }

    func setMacVolume(_ volume: Double) {
        VolumeManager.shared.setAbsolute(Float32(volume))
    }

    func setVolume(_ volume: Double, for bundleID: String) {
        // What shows as 100% is 100%, with nothing tapped
        let isFull = volume >= 0.995
        let wasFull = volumes[bundleID] == nil
        volumes[bundleID] = isFull ? nil : volume
        movedSliders.insert(bundleID)
        active[bundleID]?.tap.setGain(Self.gain(isFull ? 1 : volume))

        if isFull {
            failed.remove(bundleID)
            scheduleRemoval(of: bundleID, after: removalAfterRamp)
        }
        if isFull != wasFull {
            updateListening()
            refresh()
        }
    }

    /// At the end of a drag. Also the one new try for an app whose tap didn't work.
    func saveVolumes() {
        if volumes != Defaults[.appVolumes] {
            Defaults[.appVolumes] = volumes
        }
        movedSliders.removeAll()
        failed.removeAll()
        retries.removeAll()
        refresh()
    }

    /// In case a tap could outlast this app, which would leave its app muted. It's a moment at most.
    func stopTaps() {
        let taps = active.values.map(\.tap)
        active.removeAll()
        let done = DispatchSemaphore(value: 0)
        appVolumeQueue.async {
            taps.forEach { $0.stop() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    /// Loudness doesn't follow the gain. Squared, half the slider sounds about half as loud.
    private static func gain(_ volume: Double) -> Float {
        Float(volume * volume)
    }

    private func refreshMacRow() {
        guard viewers > 0 else { return }
        macVolume = VolumeManager.shared.isMuted ? 0 : Double(VolumeManager.shared.rawVolume)
        macIcon = LocalAudioRoute.systemOutput?.iconName ?? "hifispeaker.fill"
    }

    private func publishRows(apps: [String: NSRunningApplication], playing: Set<String>) {
        guard viewers > 0 else { return }

        let runningMusic = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
        if runningMusic != music {
            music = runningMusic
        }

        let listed = playing.union(volumes.keys).union(movedSliders).subtracting(Self.notMixed)
        let newRows = listed.compactMap { bundleID -> Row? in
            let app = apps[bundleID] ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            guard let app, let name = app.localizedName else { return nil }
            return Row(id: bundleID, name: name, icon: app.icon ?? NSImage(), volume: volumes[bundleID] ?? 1, isFailing: failed.contains(bundleID))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if newRows != rows {
            rows = newRows
        }
    }

    // MARK: - Who plays
    private func setNeedsRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isRefreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        guard isListeningToProcesses else { return }

        let objects = LocalAudioRoute.objects(Self.system, kAudioHardwarePropertyProcessObjectList)
        let current = Set(objects)
        // Asked for below, but only this one says when it changes
        let isRunning = LocalAudioRoute.propertyAddress(kAudioProcessPropertyIsRunning)
        for gone in watchedProcesses.subtracting(current) {
            setListener(false, on: gone, isRunning, processListener)
            owners[gone] = nil
        }
        let new = current.subtracting(watchedProcesses)
        for object in new {
            setListener(true, on: object, isRunning, processListener)
        }
        watchedProcesses = current

        var processes: [String: [AudioObjectID]] = [:]
        var apps: [String: NSRunningApplication] = [:]
        var playing: Set<String> = []
        var playingProcesses: [String: Set<AudioObjectID>] = [:]
        for object in objects {
            let isPlaying = LocalAudioRoute.number(object, kAudioProcessPropertyIsRunningOutput) != 0
            // Asked again once it plays, as an app still launching may not be registered yet
            if owners[object] == nil, isPlaying || new.contains(object) {
                owners[object] = owner(of: object)
            }
            guard let app = owners[object], let bundleID = app.bundleIdentifier else { continue }
            processes[bundleID, default: []].append(object)
            apps[bundleID] = app
            if isPlaying {
                playing.insert(bundleID)
                playingProcesses[bundleID, default: []].insert(object)
            }
        }

        syncTaps(processes: processes, playing: playingProcesses)
        publishRows(apps: apps, playing: playing)
        updateListening()
    }

    /// The app a process plays for. Helpers are children of their app. launchd starts XPC services, so all that
    /// links those to their app is what they're called: com.hnc.Discord.something, "Safari Graphics and Media".
    private func owner(of object: AudioObjectID) -> NSRunningApplication? {
        let ownPID = pid_t(bitPattern: LocalAudioRoute.number(object, kAudioProcessPropertyPID))
        // Started from a terminal this would be the terminal's, and tapping ourselves feeds back
        guard ownPID != getpid() else { return nil }
        var pid = ownPID
        while pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return app
            }
            pid = Self.parent(of: pid)
        }

        guard let bundleID = LocalAudioRoute.string(object, kAudioProcessPropertyBundleID), !bundleID.isEmpty else { return nil }
        let isWebKit = bundleID == "com.apple.WebKit.GPU"
        guard let name = isWebKit ? NSRunningApplication(processIdentifier: ownPID)?.localizedName : bundleID else { return nil }
        let label: (NSRunningApplication) -> String? = { app in
            isWebKit ? app.localizedName.map { $0 + " " } : app.bundleIdentifier.map { $0 + "." }
        }
        return NSWorkspace.shared.runningApplications
            .filter { app in app.activationPolicy == .regular && label(app).map(name.hasPrefix) == true }
            .max { (label($0)?.count ?? 0) < (label($1)?.count ?? 0) }
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Taps
    private func syncTaps(processes: [String: [AudioObjectID]], playing: [String: Set<AudioObjectID>]) {
        for (bundleID, volume) in volumes {
            let own = processes[bundleID] ?? []

            guard let playingNow = playing[bundleID] else {
                failed.remove(bundleID)
                retries[bundleID] = nil
                if active[bundleID]?.removal == nil {
                    scheduleRemoval(of: bundleID, after: lingerAfterSound)
                }
                continue
            }

            if let entry = active[bundleID] {
                entry.removal?.cancel()
                active[bundleID]?.removal = nil
                // One that went away does no harm in the tap, and one that stays quiet doesn't need it yet.
                // One that plays and isn't in there plays at full volume.
                if !entry.processes.isSuperset(of: playingNow) {
                    scheduleRebuild(of: bundleID, processes: own)
                } else {
                    let tap = entry.tap
                    appVolumeQueue.async { tap.update(processes: own) }
                }
            } else if !failed.contains(bundleID) {
                // A tap would pull an app playing somewhere else over to the default output
                guard playsOnDefaultOutput(playingNow) else {
                    failed.insert(bundleID)
                    updateListening()
                    continue
                }
                let tap = AppVolumeTap(gain: Self.gain(volume)) { [weak self] tap, status in
                    DispatchQueue.main.async { self?.tapFailed(tap, for: bundleID, status: status) }
                }
                active[bundleID] = ActiveTap(tap: tap, processes: Set(own))
                appVolumeQueue.async { tap.build(processes: own) }
            }
        }
    }

    private func playsOnDefaultOutput(_ processes: Set<AudioObjectID>) -> Bool {
        let output = LocalAudioRoute.defaultOutputDevice
        return processes.contains { process in
            let devices = LocalAudioRoute.objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
            return devices.isEmpty || devices.contains(output)
        }
    }

    /// New helpers tend to come in bursts, and each new tap is a short gap in the sound.
    private func scheduleRebuild(of bundleID: String, processes: [AudioObjectID]) {
        guard let tap = active[bundleID]?.tap else { return }
        active[bundleID]?.rebuild?.cancel()
        let rebuild = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.active[bundleID]?.processes = Set(processes)
                self?.active[bundleID]?.rebuild = nil
                appVolumeQueue.async { tap.build(processes: processes) }
            }
        }
        active[bundleID]?.rebuild = rebuild
        DispatchQueue.main.asyncAfter(deadline: .now() + rebuildSettleTime, execute: rebuild)
    }

    private func scheduleRemoval(of bundleID: String, after delay: TimeInterval) {
        guard active[bundleID] != nil else { return }
        active[bundleID]?.removal?.cancel()
        let removal = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.removeTap(of: bundleID) }
        }
        active[bundleID]?.removal = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: removal)
    }

    private func removeTap(of bundleID: String) {
        guard let entry = active.removeValue(forKey: bundleID) else { return }
        entry.removal?.cancel()
        entry.rebuild?.cancel()
        let tap = entry.tap
        appVolumeQueue.async { tap.stop() }
        updateListening()
    }

    /// The app keeps its normal volume then, and gets another try or two: AirPods just connecting can take
    /// a while. After those it says so once, and only something new brings another try.
    private func tapFailed(_ tap: AppVolumeTap, for bundleID: String, status: OSStatus) {
        guard let entry = active[bundleID], entry.tap === tap else { return }
        entry.removal?.cancel()
        entry.rebuild?.cancel()
        active[bundleID] = nil

        let tries = retries[bundleID, default: 0]
        if tries < triesAfterFailure {
            retries[bundleID] = tries + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in self?.refresh() }
        } else {
            failed.insert(bundleID)
            NSLog("Mixer: no tap for %@ (%d)", bundleID, status)
            refresh()
        }
        updateListening()
    }

    // MARK: - The output
    /// AirPods coming, going or changing their format come as a burst of these.
    private func outputChanged() {
        outputChange?.cancel()
        let change = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.followOutput() }
        }
        outputChange = change
        DispatchQueue.main.asyncAfter(deadline: .now() + outputSettleTime, execute: change)
    }

    private func followOutput() {
        failed.removeAll()
        for (bundleID, entry) in active {
            // On its way out anyway, and a new aggregate would wait for a sound that isn't coming
            if entry.removal != nil {
                removeTap(of: bundleID)
            } else {
                let tap = entry.tap
                appVolumeQueue.async { tap.followOutput() }
            }
        }
        updateListening()
        refreshMacRow()
        refresh()
    }

    // MARK: - Listening
    /// Nothing at all unless an app is turned down or the tab is on screen, and nothing about the output
    /// unless a tap runs or the tab shows it.
    private func updateListening() {
        let shouldListen = !volumes.isEmpty || !active.isEmpty || viewers > 0
        if shouldListen != isListeningToProcesses {
            isListeningToProcesses = shouldListen
            setListener(shouldListen, on: Self.system, LocalAudioRoute.propertyAddress(kAudioHardwarePropertyProcessObjectList), processListener)
            setAppObservers(shouldListen)
            if !shouldListen {
                let isRunning = LocalAudioRoute.propertyAddress(kAudioProcessPropertyIsRunning)
                watchedProcesses.forEach { setListener(false, on: $0, isRunning, processListener) }
                watchedProcesses = []
                owners = [:]
            }
        }

        let shouldWatchOutput = !active.isEmpty || !failed.isEmpty || viewers > 0
        if shouldWatchOutput != isWatchingOutput {
            isWatchingOutput = shouldWatchOutput
            setListener(shouldWatchOutput, on: Self.system, LocalAudioRoute.propertyAddress(kAudioHardwarePropertyDefaultOutputDevice), outputListener)
        }

        let device = shouldWatchOutput ? LocalAudioRoute.defaultOutputDevice : AudioObjectID(kAudioObjectUnknown)
        if device != watchedDevice {
            setDeviceListeners(false, on: watchedDevice)
            setDeviceListeners(true, on: device)
            watchedDevice = device
        }
    }

    /// An app that plays while it launches isn't anybody's yet. It's sorted out once it has finished.
    private func setAppObservers(_ isOn: Bool) {
        let center = NSWorkspace.shared.notificationCenter
        appObservers.forEach { center.removeObserver($0) }
        appObservers = []
        guard isOn else { return }
        appObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func setDeviceListeners(_ isOn: Bool, on device: AudioObjectID) {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        setListener(isOn, on: device, LocalAudioRoute.propertyAddress(kAudioDevicePropertyNominalSampleRate), outputListener)
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            let volume = LocalAudioRoute.propertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            setListener(isOn, on: device, volume, volumeListener)
        }
        setListener(isOn, on: device, LocalAudioRoute.propertyAddress(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), volumeListener)
    }

    private func setListener(_ isOn: Bool, on object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ listener: @escaping AudioObjectPropertyListenerBlock) {
        var address = address
        if isOn {
            AudioObjectAddPropertyListenerBlock(object, &address, .main, listener)
        } else {
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
    }
}

/// One app's sound, muted where it was and played again at its own volume. All of this runs on one queue, as
/// setting it up can take a moment with Bluetooth. Only setGain comes from elsewhere.
private final class AppVolumeTap: @unchecked Sendable {
    private let checkInterval: TimeInterval = 2
    private let checksBeforeStall = 2
    private let state = UnsafeMutablePointer<AppVolumeRenderState>.allocate(capacity: 1)
    private let onFailure: @Sendable (AppVolumeTap, OSStatus) -> Void

    private var processes: [AudioObjectID] = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var outputUID: String?
    private var outputSampleRate: Float64 = 0
    private var connection = 0
    private var isStopped = false
    private var lastPasses: UInt32 = 0
    private var checksWithoutPass = 0
    private var didRebuildForStall = false

    init(gain: Float, onFailure: @escaping @Sendable (AppVolumeTap, OSStatus) -> Void) {
        state.initialize(to: AppVolumeRenderState(target: gain))
        self.onFailure = onFailure
    }

    /// Whoever holds the last reference has seen stop() finish on the queue, so the audio thread is done with this.
    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func setGain(_ gain: Float) {
        state.pointee.target = gain
    }

    /// The old tap stays until the new one is in place, so the app can't get loud in between.
    func build(processes: [AudioObjectID]) {
        guard !isStopped else { return }
        self.processes = processes
        disconnect()
        let oldTap = tapID
        tapID = AudioObjectID(kAudioObjectUnknown)
        let status = connect()
        destroyTap(oldTap)
        if status != noErr {
            fail(status)
        }
    }

    /// For the next build. A process that's gone may not be accepted anymore.
    func update(processes: [AudioObjectID]) {
        self.processes = processes
    }

    func followOutput() {
        guard !isStopped else { return }
        let device = LocalAudioRoute.defaultOutputDevice
        guard device != outputDevice
                || LocalAudioRoute.string(device, kAudioDevicePropertyDeviceUID) != outputUID
                || LocalAudioRoute.sampleRate(of: device) != outputSampleRate else { return }
        build(processes: processes)
    }

    /// In this order: the audio thread is done once AudioDeviceDestroyIOProcID returns.
    func stop() {
        isStopped = true
        disconnect()
        destroyTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// One left behind keeps its app muted, so a second try is worth it.
    private func destroyTap(_ tap: AudioObjectID) {
        guard tap != AudioObjectID(kAudioObjectUnknown), AudioHardwareDestroyProcessTap(tap) != noErr else { return }
        let status = AudioHardwareDestroyProcessTap(tap)
        if status != noErr {
            NSLog("Mixer: tap still there (%d)", status)
        }
    }

    private func fail(_ status: OSStatus) {
        stop()
        onFailure(self, status)
    }

    private func disconnect() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func connect() -> OSStatus {
        let device = LocalAudioRoute.defaultOutputDevice
        let transport = LocalAudioRoute.number(device, kAudioDevicePropertyTransportType)
        guard let uid = LocalAudioRoute.string(device, kAudioDevicePropertyDeviceUID) else { return kAudioHardwareBadDeviceError }
        // An aggregate can't sit inside an aggregate, it would come out without any channels
        guard transport != kAudioDeviceTransportTypeAggregate else { return kAudioHardwareUnsupportedOperationError }
        let sampleRate = LocalAudioRoute.sampleRate(of: device)
        guard sampleRate > 0 else { return kAudioHardwareBadDeviceError }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Boring Notch mixer"
        description.muteBehavior = .muted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { return status }

        // Tap and Bluetooth output follow the same clock. Compensating anyway makes it crackle.
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Boring Notch mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceClockDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: false]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: !isBluetooth]],
        ]
        status = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregateID)
        guard status == noErr else { return status }

        // A new aggregate takes a moment before it can run
        for _ in 0..<50 where LocalAudioRoute.number(aggregateID, kAudioDevicePropertyDeviceIsAlive) == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }

        // From silence to full in 5 ms
        state.pointee.maxStepPerFrame = Float(1 / (sampleRate * 0.005))
        state.pointee.current = 0
        state.pointee.deviceInputs = LocalAudioRoute.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
        // A plain function and plain memory, so the audio thread touches nothing Swift would count or lock
        status = AudioDeviceCreateIOProcID(aggregateID, { _, _, input, _, output, _, state in
            if let state {
                renderAppVolume(input: input, output: output, state: state.assumingMemoryBound(to: AppVolumeRenderState.self))
            }
            return noErr
        }, state, &procID)
        guard status == noErr, let procID else { return status == noErr ? kAudioHardwareUnspecifiedError : status }
        turnOffInputs(of: device, procID: procID)

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { return status }

        outputDevice = device
        outputUID = uid
        outputSampleRate = sampleRate
        watch()
        return noErr
    }

    /// A device can come with inputs of its own. Left off, nothing here counts as using the microphone,
    /// and AirPods can't drop to call quality because of it. The tap's own streams come after them.
    private func turnOffInputs(of device: AudioObjectID, procID: AudioDeviceIOProcID) {
        let deviceInputs = state.pointee.deviceInputs
        guard deviceInputs > 0 else { return }
        // The tap's streams can come a moment after the aggregate
        var allInputs = 0
        for _ in 0..<25 {
            allInputs = LocalAudioRoute.objects(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
            if allInputs > deviceInputs { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard allInputs > deviceInputs else {
            NSLog("Mixer: the tap's streams never came")
            return
        }

        // AudioHardwareIOProcStreamUsage: the proc, how many streams, then one flag per stream
        let flagsOffset = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let size = flagsOffset + allInputs * MemoryLayout<UInt32>.size
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { usage.deallocate() }
        usage.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(allInputs), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for stream in 0..<allInputs {
            usage.storeBytes(of: stream < deviceInputs ? UInt32(0) : UInt32(1), toByteOffset: flagsOffset + stream * MemoryLayout<UInt32>.size, as: UInt32.self)
        }

        var address = LocalAudioRoute.propertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), usage)
        if status != noErr {
            NSLog("Mixer: inputs stay on (%d)", status)
        }
    }

    /// The tap mutes the app, so an aggregate that stops running would leave it silent, and without the permission
    /// everything would. A new build gets one chance, after that it's better back to its normal volume.
    private func watch() {
        connection += 1
        lastPasses = state.pointee.passes
        checksWithoutPass = 0
        scheduleCheck(of: connection)
    }

    private func scheduleCheck(of watched: Int) {
        appVolumeQueue.asyncAfter(deadline: .now() + checkInterval) { [self] in
            guard watched == connection, !isStopped else { return }
            guard !AudioCapturePermission.isDenied else {
                fail(kAudioHardwareIllegalOperationError)
                return
            }

            if state.pointee.passes != lastPasses {
                lastPasses = state.pointee.passes
                checksWithoutPass = 0
                didRebuildForStall = false
            } else {
                checksWithoutPass += 1
            }

            if checksWithoutPass < checksBeforeStall {
                scheduleCheck(of: watched)
            } else if didRebuildForStall {
                fail(kAudioHardwareNotRunningError)
            } else {
                didRebuildForStall = true
                build(processes: processes)
            }
        }
    }
}

/// What the system says about capturing other apps' sound. There's no public way to ask without a prompt.
private enum AudioCapturePermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int

    private static let preflight: Preflight? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let function = dlsym(framework, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(function, to: Preflight.self)
    }()

    static var isDenied: Bool {
        preflight?("kTCCServiceAudioCapture" as CFString, nil) == 1
    }
}
