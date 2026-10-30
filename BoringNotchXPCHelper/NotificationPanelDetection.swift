//
//  NotificationPanelDetection.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation

enum NotificationPanelDetection {
    static let panelListIdentifier = "AXNotificationListItems"
    static let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterBannerStack",
        "AXNotificationCenterAlert",
        "AXNotificationCenterNotification",
        "AXNotificationCenterBannerWindow",
        "AXNotificationCenterAlertStack"
    ]
    /// The one surface a card can stand in for. Alerts stay until they're answered, and a stack holds
    /// several notifications but only shows the newest. Notification Center on 27.2 itself only knows
    /// Banner, BannerStack, Alert and AlertStack.
    static let mirrorableSubrole = "AXNotificationCenterBanner"

    static func isPanel(
        subrole: String?,
        identifier: String?,
        stackingIdentifier: String? = nil,
        insideNotificationList: Bool = false
    ) -> Bool {
        subrole == "AXNotificationCenterPanel"
            || identifier == "widget-editor-button"
            || (insideNotificationList
                && subrole == "AXButton"
                && stackingIdentifier?.hasPrefix("stack-") == true)
    }

    static func isDesktopWidget(identifier: String?) -> Bool {
        identifier?.hasPrefix("widget-local:") == true
    }

    static func isBanner(subrole: String?) -> Bool {
        bannerSubroles.contains(subrole ?? "")
    }

    static func isMirrorable(subrole: String?) -> Bool {
        subrole == mirrorableSubrole
    }
}

enum NotificationObservationPolicy {
    static let structuralNotifications: Set<String> = [
        "AXWindowCreated",
        "AXCreated",
        "AXUIElementDestroyed",
        "AXChildrenChanged",
        "AXLayoutChanged"
    ]

    static func shouldObserveElement(subrole: String?, identifier: String?) -> Bool {
        !NotificationPanelDetection.isPanel(subrole: subrole, identifier: identifier)
            && !NotificationPanelDetection.isDesktopWidget(identifier: identifier)
    }

    static func shouldScan(
        notification: String,
        subrole: String? = nil,
        identifier: String? = nil
    ) -> Bool {
        guard structuralNotifications.contains(notification) else { return false }
        if notification == "AXWindowCreated" { return true }
        return shouldObserveElement(subrole: subrole, identifier: identifier)
    }
}
