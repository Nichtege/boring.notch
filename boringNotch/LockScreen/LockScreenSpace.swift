//
//  LockScreenSpace.swift
//  boringNotch
//
//  A window space above the lock screen, through private SkyLight calls.
//  Same calls as Lakr233/SkyLightWindow (MIT), which upstream Boring Notch uses for its lock screen notch.
//  These are not public API and may stop working with a macOS update.
//

import AppKit

@MainActor
final class LockScreenSpace {
    static let shared = LockScreenSpace()

    /// False when macOS no longer has the calls, and then nothing is shown on the lock screen.
    let isAvailable: Bool

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private var connection: Int32 = 0
    private var space: UInt64 = 0
    private var addWindows: AddWindowsAndRemoveFromSpaces?

    /// Where Notification Center sits while the screen is locked, one step above the lock screen itself (300)
    private static let levelAboveLockScreen: Int32 = 400

    private init() {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        func call<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(skyLight, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        guard
            let mainConnectionID = call("SLSMainConnectionID", as: MainConnectionID.self),
            let spaceCreate = call("SLSSpaceCreate", as: SpaceCreate.self),
            let setLevel = call("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
            let showSpaces = call("SLSShowSpaces", as: ShowSpaces.self),
            let addWindows = call("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsAndRemoveFromSpaces.self)
        else {
            isAvailable = false
            return
        }
        connection = mainConnectionID()
        space = spaceCreate(connection, 1, 0)
        _ = setLevel(connection, space, Self.levelAboveLockScreen)
        _ = showSpaces(connection, [space] as CFArray)
        self.addWindows = addWindows
        isAvailable = space != 0
    }

    /// Moves the window out of the user's spaces into this one. It stays there until it's closed.
    func add(_ window: NSWindow) {
        guard isAvailable, let addWindows else { return }
        // 7 takes it out of every kind of space it was in
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
