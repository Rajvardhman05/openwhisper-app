import Cocoa
import ApplicationServices
import CoreGraphics

final class GlobalHotkey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// What's currently driving the recording, if anything.
    /// - `idle`: nothing pressed.
    /// - `holding`: Right Option held → release stops recording.
    /// - `handsFree`: Option+Space toggled on → bare Space stops it.
    private enum Mode { case idle, holding, handsFree }
    private var mode: Mode = .idle

    private let rightOptionKeyCode: UInt16 = 61
    private let spaceKeyCode: Int64 = 49

    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Check and optionally prompt for Accessibility permissions.
    /// Uses a real functional test (AXUIElement) instead of trusting AXIsProcessTrusted(),
    /// which can return stale results with ad-hoc or self-signed binaries.
    static func checkAccessibility(prompt: Bool) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        if result == .success || result == .noValue {
            owLog("[GlobalHotkey] Accessibility real test: PASS (AXUIElement result=\(result.rawValue))")
            return true
        }

        if AXIsProcessTrusted() {
            owLog("[GlobalHotkey] AXIsProcessTrusted=true (but AXUIElement failed with \(result.rawValue))")
            return true
        }

        owLog("[GlobalHotkey] Accessibility NOT granted (AXUIElement=\(result.rawValue), AXIsProcessTrusted=false)")

        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    /// Register monitors for Right Option hold-to-talk and Option+Space hands-free toggle.
    func register() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        installSpaceEventTap()
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        removeSpaceEventTap()
    }

    // MARK: - Right Option (hold-to-talk)

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == rightOptionKeyCode else { return }
        let optionPressed = event.modifierFlags.contains(.option)

        switch mode {
        case .idle:
            if optionPressed {
                mode = .holding
                onPress()
            }
        case .holding:
            if !optionPressed {
                mode = .idle
                onRelease()
            }
        case .handsFree:
            // Hands-free recording ignores Option presses — only Space toggles it off.
            break
        }
    }

    // MARK: - Space key (hands-free toggle)

    /// Called from the CGEventTap callback on every Space keyDown.
    /// Returns `true` if the event should be swallowed (don't pass through to the focused app).
    fileprivate func handleSpaceKeyDown(flags: CGEventFlags) -> Bool {
        let optionDown = flags.contains(.maskAlternate)
        // Ignore the chord if Cmd/Ctrl are also down — those are reserved for other shortcuts.
        let onlyOption = optionDown
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)

        switch mode {
        case .idle:
            if onlyOption {
                mode = .handsFree
                onPress()
                return true
            }
            return false
        case .holding:
            // User is already hold-to-talking; tapping Space locks it into hands-free.
            // Don't fire onPress/onRelease — the recording is already running.
            if onlyOption {
                mode = .handsFree
                return true
            }
            return false
        case .handsFree:
            mode = .idle
            onRelease()
            return true
        }
    }

    private func installSpaceEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<GlobalHotkey>.fromOpaque(refcon).takeUnretainedValue()

            // macOS disables the tap if our callback is too slow or the system was overloaded.
            // Re-enable and pass the event through unchanged.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 49 {
                if me.handleSpaceKeyDown(flags: event.flags) {
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            owLog("[GlobalHotkey] Failed to create CGEventTap for Space — hands-free mode disabled")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        owLog("[GlobalHotkey] CGEventTap installed (hands-free: ⌥Space to start, Space to stop)")
    }

    private func removeSpaceEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    deinit {
        unregister()
    }
}
