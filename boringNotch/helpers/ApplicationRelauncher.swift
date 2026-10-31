//
//  ApplicationRelauncher.swift
//  boringNotch
//
//  Created by Corentin132 on 03/10/2025.
//

import AppKit

enum ApplicationRelauncher {
    static func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        // This very copy: asking for the bundle ID could pick another build with the same ID
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration, completionHandler: nil)

        NSApplication.shared.terminate(nil)
    }
}
