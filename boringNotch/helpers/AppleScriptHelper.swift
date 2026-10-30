//
//  AppleScriptHelper.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation

class AppleScriptHelper {
    // One at a time and away from the pool that every Task runs on. Scripts running at the same time
    // block each other for good, and once they've taken all its threads the whole app stands still.
    private static let queue = DispatchQueue(label: "com.nichtege.boringnotch.applescript", qos: .userInitiated)
    // Music sometimes never answers a script, and AppleScript's own limit for that is two minutes
    private static let replyTimeout = 2

    @discardableResult
    class func execute(_ scriptText: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let script = NSAppleScript(source: "with timeout of \(replyTimeout) seconds\n\(scriptText)\nend timeout")
                var error: NSDictionary?
                if let descriptor = script?.executeAndReturnError(&error) {
                    continuation.resume(returning: descriptor)
                } else if let error = error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
    }
    
    class func executeVoid(_ scriptText: String) async throws {
        _ = try await execute(scriptText)
    }
}
