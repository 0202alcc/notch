//
//  OutputDeviceMonitor.swift
//  AlecsNook
//
//  Created by Alec Candidato on 8/7/26.
//

import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os


/// User-visible description of an audio output device.
struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    /// True when the device is currently routable. Hidden devices
    /// (`kAudioDevicePropertyDeviceIsHidden == true`) are typically
    /// offline — remembered AirPlay targets, disconnected external
    /// displays, etc. System Settings → Sound still lists them so the
    /// user can pick them and the connection re-establishes, but the
    /// device is not currently selectable as a default output target.
    /// We mirror that behavior: show them in the menu, but mark them
    /// as unavailable so the user knows the click won't take effect
    /// immediately.
    let isAvailable: Bool
}

/// User-visible description of an AirPlay receiver discovered via
/// Bonjour on the local network.
///
/// AirPlay receivers are discovered two ways in parallel:
/// 1. Core Audio's `kAudioHardwarePropertyDevices` enumeration, which
///    exposes a hidden device record for receivers that have ever
///    connected to this Mac.
/// 2. A Bonjour browse for `_airplay._tcp` services, which finds
///    receivers that are visible on the network right now.
///
/// The Bonjour path is what surfaces devices System Settings shows
/// when Core Audio has no record of them yet (the TV was never paired
/// with this Mac, but it is on the Wi-Fi network).
struct AirPlayDevice: Identifiable, Hashable {
    let bonjourName: String
    let hostName: String?
    let port: Int
    let isResolving: Bool

    /// Stable id derived from the Bonjour service name. The same TV
    /// will keep the same id across discovery cycles so SwiftUI
    /// doesn't churn the menu.
    var id: String { bonjourName }
}

/// Discovers available audio output devices, tracks the current default
/// output device, and lets the user switch between them.
///
/// The published `devices` and `currentOutputDeviceID` are kept in sync
/// with Core Audio via property listeners on the system object. List
/// changes (a device is plugged in or unplugged) and default-output
/// changes (the user picked a different device in System Settings, or
/// this monitor wrote a new default) both propagate to SwiftUI.
@MainActor
final class OutputDeviceMonitor: ObservableObject {
    static let shared = OutputDeviceMonitor()

    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var airplayDevices: [AirPlayDevice] = []
    @Published private(set) var currentOutputDeviceID: AudioDeviceID?
    @Published private(set) var lastError: String?

    private var listListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultListenerBlock: AudioObjectPropertyListenerBlock?

    private let airplayBrowser = AirPlayBrowser()

    private init() {
        refresh()

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        // React to device list changes (plug/unplug, enumeration changes).
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listBlock: AudioObjectPropertyListenerBlock = {
            [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        let listStatus = AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &listAddress,
            DispatchQueue.main,
            listBlock
        )

        if listStatus == noErr {
            listListenerBlock = listBlock
        } else {
            NSLog(
                "OutputDeviceMonitor: failed to install device-list "
                + "listener (\(listStatus))"
            )
        }

        // React to default-output changes. This fires when the user picks
        // a different device in System Settings or when we change it
        // ourselves.
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let defaultBlock: AudioObjectPropertyListenerBlock = {
            [weak self] _, _ in
            Task { @MainActor in
                self?.refreshCurrentDevice()
            }
        }

        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            systemObjectID,
            &defaultAddress,
            DispatchQueue.main,
            defaultBlock
        )

        if defaultStatus == noErr {
            defaultListenerBlock = defaultBlock
        } else {
            NSLog(
                "OutputDeviceMonitor: failed to install default-output "
                + "listener (\(defaultStatus))"
            )
        }

        // Kick off the Bonjour AirPlay scan. The browser delivers
        // results on its own queue, so we just republish on the main
        // actor.
        airplayBrowser.onUpdate = { [weak self] devices in
            Task { @MainActor in
                self?.airplayDevices = devices
            }
        }
        airplayBrowser.start()
    }

    deinit {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        if let listBlock = listListenerBlock {
            var listAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectRemovePropertyListenerBlock(
                systemObjectID,
                &listAddress,
                DispatchQueue.main,
                listBlock
            )
        }

        if let defaultBlock = defaultListenerBlock {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectRemovePropertyListenerBlock(
                systemObjectID,
                &defaultAddress,
                DispatchQueue.main,
                defaultBlock
            )
        }

        airplayBrowser.stop()
    }

    // MARK: - Public API

    /// Switches the system's default output device. The listener
    /// installed in `init` will pick up the change and update
    /// `currentOutputDeviceID` / `devices`.
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &value
        )

        if status != noErr {
            let deviceName = devices.first(where: { $0.id == deviceID })?
                .name ?? "device \(deviceID)"
            lastError =
                "Couldn't switch to \(deviceName) — it may be "
                + "disconnected (Core Audio status \(status))."
            NSLog(
                "OutputDeviceMonitor: failed to set default output "
                + "device (\(status))"
            )
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Refresh

    private func refresh() {
        devices = Self.discoverOutputDevices()
        refreshCurrentDevice()
    }

    private func refreshCurrentDevice() {
        currentOutputDeviceID = Self.readDefaultOutputDevice()
    }

    private static func discoverOutputDevices() -> [OutputDevice] {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            systemObjectID,
            &listAddress,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr, dataSize > 0 else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var rawIDs = [AudioDeviceID](
            repeating: 0,
            count: deviceCount
        )

        let listStatus = AudioObjectGetPropertyData(
            systemObjectID,
            &listAddress,
            0,
            nil,
            &dataSize,
            &rawIDs
        )

        guard listStatus == noErr else {
            return []
        }

        var result: [OutputDevice] = []
        for deviceID in rawIDs {
            guard hasOutputChannels(deviceID: deviceID) else {
                continue
            }

            let name = readDeviceName(deviceID: deviceID)
                ?? readDeviceUID(deviceID: deviceID)
                ?? "Output Device \(deviceID)"

            let uid = readDeviceUID(deviceID: deviceID)
                ?? "device-\(deviceID)"

            // Skip Core Audio's internal routing devices that exist for
            // HAL plumbing but never appear in System Settings → Sound.
            // `CADefaultDeviceAggregate-*` is the system-managed default
            // aggregate (used as a fallback for Multi-Output / AirPlay
            // routing). Virtual transport devices (`kAudioDeviceTransportTypeVirtual`)
            // are third-party virtual audio sinks (Zoom, BlackHole, etc.)
            // that System Settings also hides.
            if isDefaultAggregateDevice(name: name) {
                continue
            }

            if let transport = readTransportType(deviceID: deviceID) {
                if transport == kAudioDeviceTransportTypeVirtual {
                    continue
                }
            }

            // Surface hidden devices (offline AirPlay targets, etc.) so
            // the menu matches what System Settings → Sound shows. The
            // still-routable flag is computed once down here so the
            // menu can render them distinctly.
            let available = !isHiddenDevice(deviceID: deviceID)

            result.append(
                OutputDevice(
                    id: deviceID,
                    name: name,
                    uid: uid,
                    isAvailable: available
                )
            )
        }

        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    /// Core Audio always exposes a hidden default aggregate device
    /// named `CADefaultDeviceAggregate-<pid>-<n>`. It is HAL plumbing
    /// for Multi-Output / AirPlay routing and is never a user-visible
    /// output target, so System Settings → Sound does not list it.
    private static func isDefaultAggregateDevice(name: String) -> Bool {
        name.hasPrefix("CADefaultDeviceAggregate")
    }

    /// Returns true for devices that Core Audio has marked as hidden
    /// (typically offline AirPlay targets, disconnected external
    /// displays, or aggregated halves of a multi-output device that
    /// aren't user-selectable on their own). System Settings still
    /// surfaces these in its Sound output picker so the user can pick
    /// one and trigger a reconnect.
    private static func isHiddenDevice(deviceID: AudioDeviceID) -> Bool {
        // `kAudioDevicePropertyDeviceIsHidden` is the four-char code
        // `'hid?'`. The C macro is not directly imported into Swift
        // in this toolchain, so we build the selector value by hand.
        // `'h' = 0x68`, `'i' = 0x69`, `'d' = 0x64`, `'?' = 0x3F`,
        // packed big-endian (the byte order four-char codes use).
        let hiddenSelector = AudioObjectPropertySelector(
            0x68 << 24 | 0x69 << 16 | 0x64 << 8 | 0x3F
        )

        var address = AudioObjectPropertyAddress(
            mSelector: hiddenSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return false
        }

        return value != 0
    }

    private static func readTransportType(
        deviceID: AudioDeviceID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return nil
        }

        return value
    }

    private static func hasOutputChannels(
        deviceID: AudioDeviceID
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr, dataSize > 0 else {
            return false
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )

        defer {
            raw.deallocate()
        }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            raw
        )

        guard status == noErr else {
            return false
        }

        let bufferList = raw.assumingMemoryBound(
            to: AudioBufferList.self
        )

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers {
            if buffer.mNumberChannels > 0 {
                return true
            }
        }

        return false
    }

    private static func readDeviceName(
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var ref: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &ref
        )

        guard status == noErr, let ref else {
            return nil
        }

        let string = ref.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func readDeviceUID(
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var ref: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &ref
        )

        guard status == noErr, let ref else {
            return nil
        }

        let string = ref.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func readDefaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }
}

// MARK: - AirPlay Bonjour browser

/// Browses the local network for `_airplay._tcp` services so AirPlay
/// receivers that Core Audio has never seen can still appear in the
/// output device menu. This mirrors what System Settings → Sound does
/// for AirPlay targets: even a TV that has never been paired with
/// this Mac will show up as long as it is on the same network and
/// advertising the AirPlay service.
///
/// Browsing happens on a background queue; the assembled list of
/// `AirPlayDevice`s is delivered to the caller via `onUpdate`. The
/// browser holds nothing else — it's a thin shell over the
/// `NetServiceBrowser` delegate dance.
final class AirPlayBrowser: NSObject {
    /// Service type for AirPlay receivers. Apple documents this is
    /// the canonical service name to scan for when looking for
    /// AirPlay audio destinations.
    private static let serviceType = "_airplay._tcp."

    private let browser = NetServiceBrowser()
    private let lock = NSLock()
    private var services: [String: ResolvingService] = [:]

    /// Invoked on the main queue whenever the discovered list changes
    /// (services found, services lost, or a name/host resolves).
    var onUpdate: (([AirPlayDevice]) -> Void)?

    private struct ResolvingService {
        let service: NetService
        var hostName: String?
        var port: Int
        var isResolved: Bool
    }

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(
            ofType: Self.serviceType,
            inDomain: "local."
        )
    }

    func stop() {
        browser.stop()
        lock.withLock {
            for resolved in services.values {
                resolved.service.stop()
            }
            services.removeAll()
        }
    }

    private func publish() {
        let snapshot: [AirPlayDevice] = lock.withLock {
            services.values
                .sorted { $0.service.name < $1.service.name }
                .map { resolved in
                    AirPlayDevice(
                        bonjourName: resolved.service.name,
                        hostName: resolved.hostName,
                        port: resolved.port,
                        isResolving: !resolved.isResolved
                    )
                }
        }

        DispatchQueue.main.async { [onUpdate] in
            onUpdate?(snapshot)
        }
    }

    private func updateService(
        _ service: NetService,
        apply: (inout ResolvingService) -> Void
    ) {
        let key = service.name
        lock.withLock {
            var resolved = services[key] ?? ResolvingService(
                service: service,
                hostName: nil,
                port: 0,
                isResolved: false
            )
            apply(&resolved)
            services[key] = resolved
        }
    }

    private func removeService(_ service: NetService) {
        let key = service.name
        lock.withLock {
            services.removeValue(forKey: key)
        }
    }
}

extension AirPlayBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        // Hold a strong reference to the service until it disappears
        // or fails to resolve — otherwise the system's own retain will
        // drop it before we can read its name and addresses.
        service.delegate = self
        updateService(service) { resolved in
            resolved.isResolved = false
        }
        service.resolve(withTimeout: 5)
        publish()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        service.stop()
        removeService(service)
        publish()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        // `-72000` (NSNetServicesErrorUnknown) usually means the
        // process lacks `com.apple.security.network.multicast` /
        // `.network.client`. The entitlement fix lives in
        // `AlecsNook.entitlements`; this log only surfaces if the
        // entitlement was removed or the user is on a network where
        // mDNS is filtered.
        NSLog(
            "AirPlayBrowser: Bonjour search failed: \(errorDict)"
        )
    }
}

extension AirPlayBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ service: NetService) {
        updateService(service) { resolved in
            resolved.hostName = service.hostName
            resolved.port = Int(service.port)
            resolved.isResolved = true
        }
        publish()
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        NSLog(
            "AirPlayBrowser: failed to resolve \(sender.name): "
            + "\(errorDict)"
        )
        removeService(sender)
        publish()
    }
}
