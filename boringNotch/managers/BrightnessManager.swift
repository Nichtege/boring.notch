//  BrightnessManager.swift
//  boringNotch
//
//  Created by JeanLouis on 08/22/24.

import AppKit

final class BrightnessManager: ObservableObject {
	static let shared = BrightnessManager()

	@Published private(set) var rawBrightness: Float = 0

	private let client = XPCHelperClient.shared

	private init() { refresh() }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentScreenBrightness() {
				publish(brightness: current)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		Task { @MainActor in
			let starting = await client.currentScreenBrightness() ?? rawBrightness
			let target = max(0, min(1, starting + delta))
			let ok = await client.setScreenBrightness(target)
			if ok {
				publish(brightness: target)
			} else {
				refresh()
			}
			BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(target))
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setScreenBrightness(clamped)
			if ok {
				publish(brightness: clamped)
			} else {
				refresh()
			}
		}
	}

	private func publish(brightness: Float) {
		DispatchQueue.main.async {
			self.rawBrightness = brightness
		}
	}
}

// MARK: - Keyboard Backlight Controller
final class KeyboardBacklightManager: ObservableObject {
	static let shared = KeyboardBacklightManager()

	@Published private(set) var rawBrightness: Float = 0

	private let client = XPCHelperClient.shared

	private init() { refresh() }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentKeyboardBrightness() {
				publish(brightness: current)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		Task { @MainActor in
			let starting = await client.currentKeyboardBrightness() ?? rawBrightness
			let target = max(0, min(1, starting + delta))
			let ok = await client.setKeyboardBrightness(target)
			if ok {
				publish(brightness: target)
			} else {
				refresh()
			}
			BoringViewCoordinator.shared.toggleSneakPeek(
				status: true,
				type: .backlight,
				value: CGFloat(target)
			)
		}
	}

	private func publish(brightness: Float) {
		DispatchQueue.main.async {
			self.rawBrightness = brightness
		}
	}
}

