//
//  MicLock.swift
//  boringNotch
//
//  Keeps the default input off Bluetooth microphones. On connecting, macOS makes AirPods the default
//  input too, and anything that then listens drops them to call quality. A microphone someone picked
//  (USB, iPhone) stays. The app only notices the change: the helper sets the device, as it isn't
//  sandboxed and holds no state a restart could lose.
//

import Combine
import CoreAudio
import Defaults

enum MicLock {
    private static var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var settingCancellable: AnyCancellable?
    private static let shortestPause: TimeInterval = 1
    private static var lastPutBack: Date = .distantPast
    private static var isPutBackWaiting = false

    static func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            putBackIfEnabled()
        }
        // Also looks once now, and whenever the setting is turned on
        settingCancellable = Defaults.publisher(.micStaysOnMacBook).sink { _ in
            putBackIfEnabled()
        }
    }

    private static var isDefaultInputBluetooth: Bool {
        let input = LocalAudioRoute.number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        let transport = LocalAudioRoute.number(input, kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func putBackIfEnabled() {
        // Another tool setting it too would be answered without end. A change during the pause is still
        // looked at after it, or AirPods reconnecting could slip through and stay.
        let wait = shortestPause - Date().timeIntervalSince(lastPutBack)
        guard wait <= 0 else {
            guard !isPutBackWaiting else { return }
            isPutBackWaiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                isPutBackWaiting = false
                putBackIfEnabled()
            }
            return
        }
        if Defaults[.micStaysOnMacBook] && isDefaultInputBluetooth {
            lastPutBack = Date()
            XPCHelperClient.shared.keepMicOnMacBook()
        }
    }
}
