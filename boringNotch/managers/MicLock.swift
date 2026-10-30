//
//  MicLock.swift
//  boringNotch
//
//  Keeps the default input on the MacBook's microphone. On connecting, macOS makes AirPods the default
//  input too, and anything that then listens drops them to call quality. The app only notices the change:
//  the helper sets the device, as it isn't sandboxed and holds no state a restart could lose.
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

    static func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            putBackIfEnabled()
        }
        // Also looks once now, and whenever the setting is turned on
        settingCancellable = Defaults.publisher(.micStaysOnMacBook).sink { _ in
            putBackIfEnabled()
        }
    }

    private static func putBackIfEnabled() {
        if Defaults[.micStaysOnMacBook] {
            XPCHelperClient.shared.keepMicOnMacBook()
        }
    }
}
