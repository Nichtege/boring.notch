//
//  DragDetector.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-20.
//

import Cocoa
import UniformTypeIdentifiers

final class DragDetector {

    // MARK: - Callbacks

    typealias VoidCallback = () -> Void

    var onDragEntersNotchRegion: VoidCallback?
    /// Only after a drag that reached the region: it can't have been dropped there.
    var onDragEndsOutsideNotchRegion: VoidCallback?

    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?

    private var pasteboardChangeCount: Int = -1
    private var isDragging: Bool = false
    private var isContentDragging: Bool = false
    private var hasEnteredNotchRegion: Bool = false
    private var hasReachedNotchRegion: Bool = false

    private let notchRegion: CGRect
    private let dragPasteboard = NSPasteboard(name: .drag)

    init(notchRegion: CGRect) {
        self.notchRegion = notchRegion
    }

    // MARK: - Private Helpers
    
    /// Checks if the drag pasteboard contains valid content types that can be dropped on the shelf
    private func hasValidDragContent() -> Bool {
        let validTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.url.identifier),
            .string
        ]
        return dragPasteboard.types?.contains(where: validTypes.contains) ?? false
    }

    func startMonitoring() {
        stopMonitoring()

        // Track pasteboard to detect content drag
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            self.pasteboardChangeCount = self.dragPasteboard.changeCount
            self.isDragging = true
            self.isContentDragging = false
            self.hasEnteredNotchRegion = false
            self.hasReachedNotchRegion = false
        }

        // Track drag movement and notch region intersection
        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            guard self.isDragging else { return }

            // The pasteboard is another process, so only a drag that reaches the notch asks it
            guard self.notchRegion.contains(NSEvent.mouseLocation) else {
                self.hasEnteredNotchRegion = false
                return
            }

            // Detect if actual content is being dragged AND it's valid content
            if !self.isContentDragging
                && self.dragPasteboard.changeCount != self.pasteboardChangeCount
                && self.hasValidDragContent() {
                self.isContentDragging = true
            }

            if self.isContentDragging && !self.hasEnteredNotchRegion {
                self.hasEnteredNotchRegion = true
                self.hasReachedNotchRegion = true
                self.onDragEntersNotchRegion?()
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self = self else { return }
            guard self.isDragging else { return }

            if self.hasReachedNotchRegion && !self.notchRegion.contains(NSEvent.mouseLocation) {
                self.onDragEndsOutsideNotchRegion?()
            }
            self.isDragging = false
            self.isContentDragging = false
            self.hasEnteredNotchRegion = false
            self.hasReachedNotchRegion = false
            self.pasteboardChangeCount = -1
        }
    }

    func stopMonitoring() {
        [mouseDownMonitor, mouseDraggedMonitor, mouseUpMonitor].forEach { monitor in
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        mouseDownMonitor = nil
        mouseDraggedMonitor = nil
        mouseUpMonitor = nil
        isDragging = false
        isContentDragging = false
        hasEnteredNotchRegion = false
        hasReachedNotchRegion = false
    }

    deinit {
        stopMonitoring()
    }
}
