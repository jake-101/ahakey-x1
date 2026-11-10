import CoreGraphics
import Foundation

// Logs key down events (keycode + name) via CGEventTap (listen-only).
// Needs Accessibility permission for the host terminal app — approve the prompt.
// Usage: swift keylogger.swift [seconds]

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 30.0 : 30.0

let keyNames: [UInt32: String] = [
    105: "F13", 107: "F14", 106: "F16", 109: "F15", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    58: "Option", 56: "Shift", 55: "Cmd", 59: "Ctrl",
    36: "Return", 53: "Escape", 49: "Space", 51: "Delete", 123: "Left", 124: "Right",
]

let callback: CGEventTapCallBack = { _, _, event, _ in
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let name = keyNames[UInt32(bitPattern: Int32(truncatingIfNeeded: code))] ?? "keycode \(code)"
    print("KEY: \(name) (\(code))")
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap,
    options: .listenOnly, eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
    callback: callback, userInfo: nil
) else {
    print("Could not create event tap. Grant Accessibility permission to this terminal app, then rerun.")
    print("(System Settings → Privacy & Security → Accessibility)")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
CGEvent.tapEnable(tap: tap, enable: true)

print("Listening for \(duration)s — press each X1 key once...")
RunLoop.main.run(until: Date().addingTimeInterval(duration))
print("--- keylogger done ---")
