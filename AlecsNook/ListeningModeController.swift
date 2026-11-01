//
//  ListeningModeController.swift
//  AlecsNook
//
//  Created by Alec Candidato on 11/1/26.
//

import AppKit
import ApplicationServices
import Foundation
import NookKit
import os

private let listeningLog = Logger(
    subsystem: "io.github.0202alcc.AlecsNook",
    category: "ListeningMode"
)

/// Reads and sets the AirPods noise-control mode by driving Control
/// Center's Sound panel through the Accessibility API.
///
/// This is the only viable mechanism on macOS 26: the private
/// `AVOutputDevice` listening-mode API is server-side entitlement-gated
/// (probed), the HAL exposes no property (probed), and there is no
/// public API. The AX hierarchy is stable and exposes the four modes as
/// pressable, value-carrying checkboxes.
///
/// Refreshes are on-demand (nook panel open, slider interaction), never
/// on a timer - opening Control Center is a visible on-screen action.
@MainActor
final class ListeningModeController: ObservableObject {
    static let shared = ListeningModeController()

    /// The AirPods' current mode, when known (AirPods active as output
    /// and the Sound panel exposes the Listening Mode row).
    @Published private(set) var currentMode: ListeningMode?

    /// The modes the device currently offers - non-empty means the
    /// slider can render.
    @Published private(set) var availableModes: [ListeningMode] = []

    /// True when the app lacks Accessibility permission - the UI shows
    /// a hint instead of a dead slider.
    @Published private(set) var accessibilityDenied = false

    private let axQueue = DispatchQueue(
        label: "org.aleccandidato.MyNook.listening-mode-ax",
        qos: .userInitiated
    )

    private init() {
        // Prompt for Accessibility permission on first use (System
        // Settings opens; the user toggles AlecsNook manually).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        accessibilityDenied = !AXIsProcessTrustedWithOptions(options)
    }

    /// Fetch the current mode + available modes.
    func refresh() {
        guard !accessibilityDenied else { return }
        axQueue.async { [weak self] in
            let result = Self.readModes()
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.availableModes = result.available
                    self.currentMode = result.current
                } else {
                    self.availableModes = []
                    self.currentMode = nil
                }
            }
        }
    }

    /// Switch to a mode by pressing its Control Center checkbox.
    func setMode(_ mode: ListeningMode) {
        guard !accessibilityDenied else { return }
        axQueue.async { [weak self] in
            let result = Self.pressMode(mode)
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.availableModes = result.available
                    self.currentMode = result.current
                }
            }
        }
    }

    // MARK: - AX plumbing (runs on axQueue; blocking, seconds-long)

    private struct ModeRead {
        let available: [ListeningMode]
        let current: ListeningMode?
    }

    private static func readModes() -> ModeRead? {
        performPanelOperation { window in
            findModeElements(in: window)
        }
    }

    private static func pressMode(_ mode: ListeningMode) -> ModeRead? {
        performPanelOperation { window in
            let elements = findModeElements(in: window)
            guard
                let target = elements.first(where: {
                    ListeningMode(axDescription: $0.desc) == mode
                })
            else {
                return elements
            }
            AXUIElementPerformAction(target.element, kAXPressAction as CFString)
            // Give the device a beat to apply, then read the settled state.
            Thread.sleep(forTimeInterval: 0.8)
            return findModeElements(in: window)
        }
    }

    /// Shared traversal: open CC grid → press Sound → collect the
    /// Listening Mode row's checkboxes → close.
    private static func performPanelOperation(
        _ body: (AXUIElement) -> [ModeElement]
    ) -> ModeRead? {
        guard
            let ccPID = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.controlcenter"
            ).first?.processIdentifier
        else {
            return nil
        }
        let ccApp = AXUIElementCreateApplication(ccPID)

        for _ in 0..<3 {
            guard
                openSoundPanel(app: ccApp),
                let window = currentWindow(app: ccApp)
            else {
                pressEscape()
                usleep(400_000)
                continue
            }

            let elements = body(window)

            pressEscape()
            usleep(300_000)

            guard !elements.isEmpty else { return nil }

            let available = elements.compactMap {
                ListeningMode(axDescription: $0.desc)
            }
            let current = elements
                .first(where: { $0.value })
                .flatMap { ListeningMode(axDescription: $0.desc) }
            return ModeRead(available: available, current: current)
        }
        listeningLog.error("failed to open the Sound panel after retries")
        return nil
    }

    private struct ModeElement {
        let element: AXUIElement
        let desc: String
        let value: Bool
    }

    /// Finds the "Listening Mode" heading's checkbox row: the siblings
    /// between this heading and the next heading whose descriptions
    /// parse as modes.
    private static func findModeElements(
        in window: AXUIElement
    ) -> [ModeElement] {
        var result: [ModeElement] = []
        collectModeElements(in: window, into: &result)
        return result
    }

    private static func collectModeElements(
        in element: AXUIElement,
        into result: inout [ModeElement]
    ) {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if role == "AXHeading" {
            let heading = stringValue(element, kAXDescriptionAttribute)
                ?? stringValue(element, kAXTitleAttribute) ?? ""
            guard heading == "Listening Mode" else { return }

            // The checkboxes are siblings within the heading's parent.
            guard let parent = parentOf(element) else { return }
            for sibling in childrenOf(parent) {
                guard stringValue(sibling, kAXRoleAttribute) == "AXCheckBox" else {
                    continue
                }
                let desc = stringValue(sibling, kAXDescriptionAttribute) ?? ""
                let value = boolValue(sibling, kAXValueAttribute)
                result.append(
                    ModeElement(element: sibling, desc: desc, value: value)
                )
            }
            return
        }

        for child in childrenOf(element) {
            collectModeElements(in: child, into: &result)
        }
    }

    // MARK: - AX helpers

    private static func stringValue(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    private static func boolValue(
        _ element: AXUIElement,
        _ attribute: String
    ) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    private static func childrenOf(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value
        )
        guard let array = value as? NSArray else { return [] }
        return array.map { $0 as! AXUIElement }
    }

    private static func parentOf(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        return value.map { $0 as! AXUIElement }
    }

    /// Opens the Control Center grid and presses its Sound button.
    /// Returns false when any step failed (caller retries).
    private static func openSoundPanel(app ccApp: AXUIElement) -> Bool {
        var menuBarValue: CFTypeRef?
        AXUIElementCopyAttributeValue(
            ccApp, "AXExtrasMenuBar" as CFString, &menuBarValue
        )
        guard
            let menuBarValue,
            let menuBarArray = menuBarValue as? NSArray,
            let firstObject = menuBarArray.firstObject
        else {
            listeningLog.error("no AXExtrasMenuBar on Control Center")
            return false
        }
        let menuBar = firstObject as! AXUIElement

        // The grid item's description starts with "Control Center".
        var gridItem: AXUIElement?
        for child in childrenOf(menuBar) {
            let desc = stringValue(child, kAXDescriptionAttribute) ?? ""
            if desc.hasPrefix("Control Center") {
                gridItem = child
                break
            }
        }
        guard let gridItem else {
            listeningLog.error("no Control Center grid item")
            return false
        }

        AXUIElementPerformAction(gridItem, kAXPressAction as CFString)
        usleep(1_200_000)

        guard let window = currentWindow(app: ccApp) else {
            return false
        }

        guard
            let soundButton = findDescendant(window, matching: { $0 == "Sound" })
        else {
            return false
        }
        AXUIElementPerformAction(soundButton, kAXPressAction as CFString)
        usleep(1_200_000)

        return currentWindow(app: ccApp) != nil
    }

    private static func currentWindow(app ccApp: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(
            ccApp, kAXWindowsAttribute as CFString, &value
        )
        guard let array = value as? NSArray else { return nil }
        return array.firstObject.map { $0 as! AXUIElement }
    }

    private static func findDescendant(
        _ element: AXUIElement,
        matching desc: (String) -> Bool
    ) -> AXUIElement? {
        let elementDesc = stringValue(element, kAXDescriptionAttribute) ?? ""
        if desc(elementDesc) { return element }
        for child in childrenOf(element) {
            if let hit = findDescendant(child, matching: desc) {
                return hit
            }
        }
        return nil
    }

    private static func pressEscape() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }
}
