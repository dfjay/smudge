import AppKit
import ApplicationServices
import IOKit.hid

func log(_ message: String) {
    FileHandle.standardError.write(Data("smudge: \(message)\n".utf8))
}

struct Options {
    var display: String?
    var verbose = false
    var list = false
    var returnCursor = false

    init(_ args: ArraySlice<String>) {
        var args = args
        while let arg = args.popFirst() {
            switch arg {
            case "--display", "-d":
                guard let value = args.popFirst(), !value.hasPrefix("-") else {
                    log("\(arg) needs a display name (see --list)")
                    exit(64)
                }
                display = value
            case "--verbose", "-v": verbose = true
            case "--list", "-l": list = true
            case "--return-cursor", "-r": returnCursor = true
            case "--help", "-h":
                print("""
                usage: smudge [--display NAME] [--return-cursor] [--verbose] [--list]

                  -d, --display NAME  map touches to the display whose name contains NAME
                                      (default: first external display)
                  -r, --return-cursor put the pointer back after a gesture
                                      if it was on another display
                  -v, --verbose       log recognized gestures
                  -l, --list          list displays and touchscreens, then exit
                """)
                exit(0)
            default:
                log("unknown argument \(arg)")
                exit(64)
            }
        }
    }
}

/// Resolves the target display on every touch-down, so reconnects and rearrangements are picked up.
struct DisplayTarget {
    let query: String?

    func screen() -> NSScreen? {
        let screens = NSScreen.screens
        if let query {
            return screens.first { $0.localizedName.localizedCaseInsensitiveContains(query) }
        }
        return screens.first { CGDisplayIsBuiltin($0.displayID) == 0 }
    }

    /// Global display bounds in CoreGraphics coordinates (origin top-left of the main display).
    func bounds() -> CGRect? {
        screen().map { CGDisplayBounds($0.displayID) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? kCGNullDirectDisplay
    }
}

final class Bridge {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var panels: [IOHIDDevice: TouchPanel] = [:]
    private let target: DisplayTarget
    private let gestures = GestureEngine()
    private var bounds: CGRect?
    private var touching = false

    init(_ options: Options) {
        target = DisplayTarget(query: options.display)
        gestures.verbose = options.verbose
        gestures.returnCursor = options.returnCursor
    }

    /// Opens the HID manager; returns the IOKit result. Matching panels attach once the run loop runs.
    func start() -> IOReturn {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 0x0D,
            kIOHIDDeviceUsageKey: 0x04,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<Bridge>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<Bridge>.fromOpaque(context!).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { return result }

        // Panels fall back to mouse mode after sleep; switch them again on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.panels.values.forEach { $0.activateMultiTouch() }
            }
        }
        return result
    }

    private func attach(_ device: IOHIDDevice) {
        guard panels[device] == nil else { return }
        guard let panel = TouchPanel(device) else {
            log("ignoring touchscreen without a multi-touch report layout")
            return
        }
        panel.onFrame = { [weak self] contacts in self?.frame(contacts) }
        panel.start()
        panels[device] = panel
        log("attached \(panel.summary)")
    }

    private func detach(_ device: IOHIDDevice) {
        guard let panel = panels.removeValue(forKey: device) else { return }
        // Unplugged mid-gesture: release the button and end scrolling instead of leaving them stuck.
        gestures.cancel()
        touching = false
        bounds = nil
        log("detached \(panel.name)")
    }

    private func frame(_ contacts: [Contact]) {
        if !touching, !contacts.isEmpty {
            bounds = target.bounds()
            if bounds == nil { log("target display not found") }
            gestures.touchBounds = bounds
        }
        touching = !contacts.isEmpty
        guard let bounds else { return }
        gestures.handle(contacts.map {
            Touch(id: $0.id, point: CGPoint(x: bounds.minX + $0.x * bounds.width, y: bounds.minY + $0.y * bounds.height))
        })
    }
}

func list() {
    print("displays:")
    for screen in NSScreen.screens {
        let builtin = CGDisplayIsBuiltin(screen.displayID) != 0 ? " (built-in)" : ""
        print("  \(screen.localizedName)\(builtin) \(CGDisplayBounds(screen.displayID))")
    }
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x04] as CFDictionary)
    print("touchscreens:")
    for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
        print("  \(TouchPanel(device)?.summary ?? "unsupported device")")
    }
}

let options = Options(CommandLine.arguments.dropFirst())
if options.list {
    list()
    exit(0)
}

/// Exits when a permission is missing. Asking adds smudge to the lists in System Settings.
/// A grant made while the process runs is not picked up, so exit and let launchd
/// (KeepAlive) start a fresh process that sees it.
func requirePermissions(hidResult: IOReturn) {
    var missing: [String] = []
    // Checked by actually opening the devices: IOHIDCheckAccess ignores a grant
    // inherited from the terminal smudge was started from.
    if hidResult == kIOReturnNotPermitted {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        missing.append("Input Monitoring (to read the touchscreen)")
    } else if hidResult != kIOReturnSuccess {
        log(String(format: "cannot open HID devices (0x%X)", hidResult))
        exit(1)
    }
    // The Accessibility prompt is a dialog; show it once rather than on every restart.
    let marker = URL.cachesDirectory.appending(path: "com.dfjay.smudge/accessibility-prompted")
    let prompt = !FileManager.default.fileExists(atPath: marker.path)
    if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary) {
        if prompt {
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        }
        missing.append("Accessibility (to post input events)")
    }
    guard !missing.isEmpty else { return }
    log("missing permissions: \(missing.joined(separator: ", ")); grant them in System Settings → Privacy & Security, then restart smudge (launchd does it automatically)")
    sleep(10) // keep launchd from restarting in a tight loop
    exit(75)
}

let bridge = Bridge(options)
requirePermissions(hidResult: bridge.start())
log("running; target display: \(DisplayTarget(query: options.display).screen()?.localizedName ?? "none")")
RunLoop.main.run()
