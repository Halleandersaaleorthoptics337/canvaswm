// TileWM - A minimal tiling window manager for macOS
// ===================================================
// Build: swiftc -framework Cocoa -framework ApplicationServices -o tilewm main.swift
// Run:   ./tilewm
// Note:  Grant Accessibility permissions in System Settings → Privacy & Security → Accessibility

import Cocoa
import ApplicationServices

// MARK: - Configuration

struct Config {
    static let gapSize: CGFloat = 8.0
    static let modifier: NSEvent.ModifierFlags = [.option, .control]

    // Keybindings: modifier + key
    enum Action: UInt16 {
        case tileLeft     = 123  // ←
        case tileRight    = 124  // →
        case tileTop      = 126  // ↑
        case tileBottom   = 125  // ↓
        case maximize     = 36   // Return
        case tileTopLeft  = 18   // 1
        case tileTopRight = 19   // 2
        case tileBotLeft  = 20   // 3
        case tileBotRight = 21   // 4
        case thirds1      = 29   // 0 — first third
        case thirds2      = 25   // 9 — center third
        case thirds3      = 22   // 8 — last third
        case cycleMonitor = 8    // C
    }
}

// MARK: - AXWindow wrapper

struct AXWindow {
    let element: AXUIElement
    let ownerPID: pid_t
    let ownerName: String

    var position: CGPoint? {
        get {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
                  let val = ref else { return nil }
            var point = CGPoint.zero
            AXValueGetValue(val as! AXValue, .cgPoint, &point)
            return point
        }
        set {
            guard var point = newValue else { return }
            let val = AXValueCreate(.cgPoint, &point)!
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val)
        }
    }

    var size: CGSize? {
        get {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
                  let val = ref else { return nil }
            var size = CGSize.zero
            AXValueGetValue(val as! AXValue, .cgSize, &size)
            return size
        }
        set {
            guard var size = newValue else { return }
            let val = AXValueCreate(.cgSize, &size)!
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, val)
        }
    }

    var title: String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    var isMinimized: Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &ref) == .success else {
            return false
        }
        return (ref as? Bool) ?? false
    }

    func focus() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Also bring the owning app to front
        if let app = NSRunningApplication(processIdentifier: ownerPID) {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    /// Move and resize in one call. Sets position twice to handle
    /// apps that constrain minimum sizes and shift origin.
    func setFrame(_ rect: CGRect) {
        var origin = rect.origin
        var size = rect.size

        let posVal1 = AXValueCreate(.cgPoint, &origin)!
        let sizeVal = AXValueCreate(.cgSize, &size)!
        let posVal2 = AXValueCreate(.cgPoint, &origin)!

        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal1)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        // Re-set position to correct for apps that shift after resize
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal2)
    }
}

// MARK: - Window discovery

func getFocusedWindow() -> AXWindow? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontApp.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)

    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
          let windowEl = ref else { return nil }

    // CFTypeRef is already an AXUIElement
    return AXWindow(
        element: windowEl as! AXUIElement,
        ownerPID: pid,
        ownerName: frontApp.localizedName ?? "Unknown"
    )
}

func getAllWindows() -> [AXWindow] {
    var result: [AXWindow] = []
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

    for app in apps {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { continue }

        for win in windows {
            let axWin = AXWindow(element: win, ownerPID: app.processIdentifier,
                                 ownerName: app.localizedName ?? "Unknown")
            if !axWin.isMinimized {
                result.append(axWin)
            }
        }
    }
    return result
}

// MARK: - Screen geometry helpers

/// Returns the usable frame (excluding menu bar and dock) for the screen
/// containing the given window, or the main screen as fallback.
func screenFrame(for window: AXWindow? = nil) -> CGRect {
    var targetScreen = NSScreen.main!

    if let pos = window?.position {
        // Find which screen contains the window's top-left corner.
        // NSScreen uses bottom-left origin, but AX uses top-left,
        // so we need to convert.
        let mainHeight = NSScreen.screens.first!.frame.height
        let nsPoint = NSPoint(x: pos.x, y: mainHeight - pos.y)

        for screen in NSScreen.screens {
            if screen.frame.contains(nsPoint) {
                targetScreen = screen
                break
            }
        }
    }

    // visibleFrame excludes menu bar and dock
    let visible = targetScreen.visibleFrame
    let mainHeight = NSScreen.screens.first!.frame.height

    // Convert from NSScreen coords (bottom-left origin) to AX coords (top-left origin)
    return CGRect(
        x: visible.origin.x,
        y: mainHeight - visible.origin.y - visible.height,
        width: visible.width,
        height: visible.height
    )
}

/// Apply gaps to a frame
func applyGaps(_ rect: CGRect, gap: CGFloat = Config.gapSize) -> CGRect {
    return rect.insetBy(dx: gap, dy: gap)
}

// MARK: - Tiling layouts

enum TileRegion {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize
    case firstThird, centerThird, lastThird
}

func tileRect(for region: TileRegion, on screen: CGRect) -> CGRect {
    let x = screen.origin.x
    let y = screen.origin.y
    let w = screen.width
    let h = screen.height
    let half_w = w / 2
    let half_h = h / 2
    let third_w = w / 3

    let rect: CGRect
    switch region {
    case .left:         rect = CGRect(x: x, y: y, width: half_w, height: h)
    case .right:        rect = CGRect(x: x + half_w, y: y, width: half_w, height: h)
    case .top:          rect = CGRect(x: x, y: y, width: w, height: half_h)
    case .bottom:       rect = CGRect(x: x, y: y + half_h, width: w, height: half_h)
    case .topLeft:      rect = CGRect(x: x, y: y, width: half_w, height: half_h)
    case .topRight:     rect = CGRect(x: x + half_w, y: y, width: half_w, height: half_h)
    case .bottomLeft:   rect = CGRect(x: x, y: y + half_h, width: half_w, height: half_h)
    case .bottomRight:  rect = CGRect(x: x + half_w, y: y + half_h, width: half_w, height: half_h)
    case .maximize:     rect = screen
    case .firstThird:   rect = CGRect(x: x, y: y, width: third_w, height: h)
    case .centerThird:  rect = CGRect(x: x + third_w, y: y, width: third_w, height: h)
    case .lastThird:    rect = CGRect(x: x + 2 * third_w, y: y, width: third_w, height: h)
    }
    return applyGaps(rect)
}

func tileFocusedWindow(_ region: TileRegion) {
    guard let window = getFocusedWindow() else {
        print("⚠️  No focused window found")
        return
    }
    let screen = screenFrame(for: window)
    let frame = tileRect(for: region, on: screen)
    window.setFrame(frame)
    print("✅ Tiled '\(window.title ?? "untitled")' → \(region)")
}

// MARK: - Cycle window to next monitor

func cycleToNextMonitor() {
    guard let window = getFocusedWindow(), let pos = window.position else { return }
    let screens = NSScreen.screens
    guard screens.count > 1 else { return }

    let mainHeight = screens.first!.frame.height
    let nsPoint = NSPoint(x: pos.x, y: mainHeight - pos.y)

    var currentIndex = 0
    for (i, screen) in screens.enumerated() {
        if screen.frame.contains(nsPoint) {
            currentIndex = i
            break
        }
    }

    let nextIndex = (currentIndex + 1) % screens.count
    let nextVisible = screens[nextIndex].visibleFrame
    let target = CGRect(
        x: nextVisible.origin.x,
        y: mainHeight - nextVisible.origin.y - nextVisible.height,
        width: nextVisible.width,
        height: nextVisible.height
    )

    // Maintain relative position proportionally
    let currentScreen = screenFrame(for: window)
    let currentSize = window.size ?? CGSize(width: 800, height: 600)
    let relX = (pos.x - currentScreen.origin.x) / currentScreen.width
    let relY = (pos.y - currentScreen.origin.y) / currentScreen.height

    let newOrigin = CGPoint(
        x: target.origin.x + relX * target.width,
        y: target.origin.y + relY * target.height
    )
    window.setFrame(CGRect(origin: newOrigin, size: currentSize))
    window.focus()
    print("✅ Moved '\(window.title ?? "untitled")' to monitor \(nextIndex)")
}

// MARK: - Accessibility permission check

func checkAccessibilityPermissions() -> Bool {
    let trusted = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    )
    return trusted
}

// MARK: - Event tap for global hotkeys

func setupEventTap() {
    let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,       // active tap — can consume events
        eventsOfInterest: eventMask,
        callback: { _, _, event, _ -> Unmanaged<CGEvent>? in
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            // Check if our modifier combo is held
            let required: CGEventFlags = [.maskAlternate, .maskControl]
            guard flags.contains(required) else {
                return Unmanaged.passRetained(event)
            }

            guard let action = Config.Action(rawValue: keyCode) else {
                return Unmanaged.passRetained(event)
            }

            // Dispatch on main queue to safely use NS APIs
            DispatchQueue.main.async {
                switch action {
                case .tileLeft:     tileFocusedWindow(.left)
                case .tileRight:    tileFocusedWindow(.right)
                case .tileTop:      tileFocusedWindow(.top)
                case .tileBottom:   tileFocusedWindow(.bottom)
                case .maximize:     tileFocusedWindow(.maximize)
                case .tileTopLeft:  tileFocusedWindow(.topLeft)
                case .tileTopRight: tileFocusedWindow(.topRight)
                case .tileBotLeft:  tileFocusedWindow(.bottomLeft)
                case .tileBotRight: tileFocusedWindow(.bottomRight)
                case .thirds1:      tileFocusedWindow(.firstThird)
                case .thirds2:      tileFocusedWindow(.centerThird)
                case .thirds3:      tileFocusedWindow(.lastThird)
                case .cycleMonitor: cycleToNextMonitor()
                }
            }

            // Consume the event (don't pass it to other apps)
            return nil
        },
        userInfo: nil
    ) else {
        print("❌ Failed to create event tap. Are Accessibility permissions granted?")
        exit(1)
    }

    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    print("✅ Event tap installed")
}

// MARK: - Window observer (auto-tile new windows)

class WindowObserver {
    private var observers: [pid_t: AXObserver] = [:]
    private var knownPIDs: Set<pid_t> = []

    func startWatching() {
        // Observe workspace for new/terminated apps
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.watchApp(app)
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.unwatchApp(app.processIdentifier)
            }
        }

        // Watch all currently running apps
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            watchApp(app)
        }
        print("✅ Window observer started — watching \(observers.count) apps")
    }

    private func watchApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !knownPIDs.contains(pid) else { return }
        knownPIDs.insert(pid)

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            let notifStr = notification as String
            if notifStr == kAXWindowCreatedNotification as String {
                print("🪟 New window created")
                // You could auto-tile here, e.g.:
                // let win = AXWindow(element: element, ownerPID: pid, ownerName: "")
                // let screen = screenFrame(for: win)
                // win.setFrame(applyGaps(screen))
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success,
              let obs = observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, axApp, kAXWindowCreatedNotification as CFString, nil)
        AXObserverAddNotification(obs, axApp, kAXFocusedWindowChangedNotification as CFString, nil)

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
    }

    private func unwatchApp(_ pid: pid_t) {
        observers.removeValue(forKey: pid)
        knownPIDs.remove(pid)
    }
}

// MARK: - Main

print("""
╔══════════════════════════════════════════════╗
║            TileWM — Window Manager           ║
╠══════════════════════════════════════════════╣
║  Ctrl+Opt + ←/→/↑/↓    Tile halves          ║
║  Ctrl+Opt + 1/2/3/4    Tile quarters         ║
║  Ctrl+Opt + Return     Maximize              ║
║  Ctrl+Opt + 0/9/8      Tile thirds           ║
║  Ctrl+Opt + C           Cycle monitor         ║
╚══════════════════════════════════════════════╝
""")

guard checkAccessibilityPermissions() else {
    print("⏳ Waiting for Accessibility permissions...")
    print("   Grant access in: System Settings → Privacy & Security → Accessibility")
    // Keep running — the user might grant permission
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
    guard checkAccessibilityPermissions() else {
        print("❌ Accessibility permissions not granted. Exiting.")
        exit(1)
    }
}

print("✅ Accessibility permissions granted")

// Set up the event tap for hotkeys
setupEventTap()

// Set up window observer for new windows
let observer = WindowObserver()
observer.startWatching()

// Run the event loop
print("🚀 TileWM is running. Press Ctrl+C to quit.")
NSApplication.shared.run()
