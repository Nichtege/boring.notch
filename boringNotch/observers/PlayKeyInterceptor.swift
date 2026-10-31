//
//  PlayKeyInterceptor.swift
//  boringNotch
//
//  The keyboard's play, next and previous keys go to what plays on this Mac. While the notch shows another device
//  they go there instead. The rest of the time there's no tap at all and macOS handles them as always.
//

import AppKit
import ApplicationServices

private let systemDefinedEvent = CGEventType(rawValue: 14)!

final class PlayKeyInterceptor {
    static let shared = PlayKeyInterceptor()

    // Keyboards send either of next and fast, and previous and rewind
    private enum Key: Int {
        case play = 16
        case next = 17
        case previous = 18
        case fast = 19
        case rewind = 20
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isWanted = false

    private init() {}

    func setActive(_ active: Bool) {
        isWanted = active
        guard active else {
            stop()
            return
        }
        guard eventTap == nil else { return }
        Task { @MainActor in
            guard await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true),
                  self.isWanted, self.eventTap == nil else { return }
            self.start()
        }
    }

    private func start() {
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << systemDefinedEvent.rawValue),
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
                let interceptor = Unmanaged<PlayKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return interceptor.handle(type, cgEvent)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    /// Runs on the main thread, where the tap was added.
    private func handle(_ type: CGEventType, _ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns a tap off if it was too slow once
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(cgEvent)
        }
        guard type == systemDefinedEvent,
              let event = NSEvent(cgEvent: cgEvent),
              event.type == .systemDefined,
              event.subtype.rawValue == 8,
              let key = Key(rawValue: (event.data1 & 0xFFFF_0000) >> 16),
              MusicManager.shared.isRemoteSource else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let isDown = (event.data1 & 0xFF00) >> 8 == 0xA
        let isRepeat = event.data1 & 0x1 != 0
        if isDown && !isRepeat {
            switch key {
            case .play: MusicManager.shared.togglePlay()
            case .next, .fast: MusicManager.shared.nextTrack()
            case .previous, .rewind: MusicManager.shared.previousTrack()
            }
        }
        // Its release too, or macOS would see half a key press
        return nil
    }
}
