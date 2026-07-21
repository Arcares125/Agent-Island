import AppKit
import CoreAudio
import OSLog

// MARK: - Pure decoding and arithmetic

/// The media keys this app cares about.
enum MediaKeyAction: Equatable {
    case volumeUp
    case volumeDown
    case mute
}

/// A media-key press decoded from a system-defined event's `data1` word.
struct MediaKeyEvent: Equatable {
    let action: MediaKeyAction
    let isDown: Bool
    let isRepeat: Bool
}

/// Decode `NSEvent.data1` for a subtype-8 system-defined event.
///
/// Layout is a packed word: key code in the high half, key state in the second
/// byte (`0x0A` down, `0x0B` up), and auto-repeat in bit 0.
func decodeMediaKey(data1: Int) -> MediaKeyEvent? {
    let keyCode = (data1 & 0xFFFF_0000) >> 16
    let flags = data1 & 0x0000_FFFF

    let action: MediaKeyAction
    switch keyCode {
    case 0: action = .volumeUp      // NX_KEYTYPE_SOUND_UP
    case 1: action = .volumeDown    // NX_KEYTYPE_SOUND_DOWN
    case 7: action = .mute          // NX_KEYTYPE_MUTE
    default: return nil             // brightness, playback, everything else
    }

    return MediaKeyEvent(
        action: action,
        isDown: ((flags & 0xFF00) >> 8) == 0x0A,
        isRepeat: (flags & 0x1) == 1
    )
}

/// macOS moves output volume in sixteenths, and in quarter-sixteenths while
/// Shift+Option is held.
let volumeStepCount: Float = 16

/// The level a press should land on.
///
/// Snapping to the step grid rather than adding a delta is what stops repeated
/// presses drifting off the notches the system HUD would have shown — without
/// it, a swallowed key feels subtly different from the real one.
func steppedVolume(current: Float, up: Bool, fineGrained: Bool = false) -> Float {
    let steps = volumeStepCount * (fineGrained ? 4 : 1)
    let currentStep = (min(max(current, 0), 1) * steps).rounded()
    let next = currentStep + (up ? 1 : -1)
    return min(max(next / steps, 0), 1)
}

// MARK: - CoreAudio output volume

/// Reads and writes the default output device's level.
///
/// Volume is not a permissioned property, so this needs no entitlement and no
/// TCC prompt — unlike the event tap that drives it.
enum SystemVolume {
    private static let logger = Logger(subsystem: "com.xiao.agentisland", category: "volume")

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func scalarAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &address) { return address }
        // Some devices expose per-channel volume only.
        address.mElement = 1
        return AudioObjectHasProperty(device, &address) ? address : nil
    }

    static func level() -> Float? {
        guard let device = defaultOutputDevice(),
              var address = scalarAddress(for: device) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// Returns whether the write actually landed. The caller uses this to decide
    /// whether it may swallow the key press.
    @discardableResult
    static func setLevel(_ level: Float) -> Bool {
        guard let device = defaultOutputDevice(),
              var address = scalarAddress(for: device) else { return false }

        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }

        var value = Float32(min(max(level, 0), 1))
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if status != noErr {
            logger.error("volume write failed (status \(status, privacy: .public))")
            return false
        }
        return true
    }

    static func isMuted() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}

// MARK: - The tap

/// Swallows the volume keys so macOS never draws its own HUD, and applies the
/// change itself so the island's HUD is the only one on screen.
///
/// This is the app's single most dangerous piece of code: a tap that eats keys
/// but fails to act on them leaves the user with no volume control until the app
/// quits. Every path is therefore biased toward *not* swallowing — the event is
/// only consumed after the volume write has already succeeded.
@MainActor
final class VolumeKeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let logger = Logger(subsystem: "com.xiao.agentisland", category: "volume-tap")

    /// System-defined events (`NX_SYSDEFINED`) carry the media keys.
    private static let systemDefinedType = CGEventType(rawValue: 14)!
    /// Subtype 8 is `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    private static let auxControlSubtype: Int16 = 8

    var isRunning: Bool { tap != nil }

    /// Whether the user has granted Accessibility. Without it a tap can observe
    /// but never suppress, so there is no point creating one.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Ask for Accessibility, showing the system prompt that deep-links to
    /// Settings. Returns the current state, which is almost always false on the
    /// first call because granting it is asynchronous.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasAccessibilityPermission() else {
            logger.info("volume tap not started: Accessibility not granted")
            return false
        }

        let mask = CGEventMask(1 << Self.systemDefinedType.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<VolumeKeyTap>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    tap.handle(proxy: proxy, type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("failed to create the volume event tap")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        logger.info("volume tap started")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        source = nil
        logger.info("volume tap stopped")
    }

    private func handle(
        proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // The system disables a tap that runs slow or when input is switched.
        // Re-arming here is what stops the feature dying silently mid-session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            logger.info("volume tap re-armed after being disabled by the system")
            return passThrough
        }

        guard type == Self.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlSubtype,
              let key = decodeMediaKey(data1: nsEvent.data1)
        else { return passThrough }

        // Key-up carries no change; swallowing it without its key-down would
        // desynchronise anything else listening.
        guard key.isDown else {
            return handled(key.action) ? nil : passThrough
        }

        let fineGrained = nsEvent.modifierFlags
            .isSuperset(of: [.shift, .option])

        let applied: Bool
        switch key.action {
        case .mute:
            applied = key.isRepeat ? true : toggleMute()
        case .volumeUp, .volumeDown:
            applied = adjust(up: key.action == .volumeUp, fineGrained: fineGrained)
        }

        // The safety rule: only eat the key once the change has actually landed.
        return applied ? nil : passThrough
    }

    /// Whether we would have consumed the matching key-down, so the key-up is
    /// suppressed consistently.
    private func handled(_ action: MediaKeyAction) -> Bool {
        switch action {
        case .volumeUp, .volumeDown, .mute: return true
        }
    }

    private func adjust(up: Bool, fineGrained: Bool) -> Bool {
        guard let current = SystemVolume.level() else { return false }
        // Raising volume while muted should unmute, matching the system.
        if up, SystemVolume.isMuted() == true {
            SystemVolume.setMuted(false)
        }
        return SystemVolume.setLevel(
            steppedVolume(current: current, up: up, fineGrained: fineGrained))
    }

    private func toggleMute() -> Bool {
        guard let muted = SystemVolume.isMuted() else { return false }
        return SystemVolume.setMuted(!muted)
    }
}
