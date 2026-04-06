# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build
bash build.sh
# or directly:
swiftc -framework Cocoa -framework ApplicationServices -o tilewm main.swift

# Run
./tilewm
```

No test suite or linter is configured.

**System requirement:** macOS only. The app requires Accessibility permissions (System Settings → Privacy & Security → Accessibility) to control windows.

## What This Is

**TileWM** is a minimal macOS tiling window manager (~450 lines, single file `main.swift`, no external dependencies). It intercepts global keyboard shortcuts (Ctrl+Opt + arrow keys / number keys) to snap the focused window into halves, quarters, thirds, or full-screen on the current or a different monitor.

## Architecture

The entire application lives in `main.swift`, organized into three logical layers:

1. **`AXWindow` wrapper** — Wraps the macOS Accessibility API (`AXUIElement`). Provides position, size, title, minimized status, plus `focus()` and `setFrame()`. Handles coordinate conversion between Cocoa (bottom-left origin) and the AX API (top-left origin).

2. **Window discovery & layout** — `getFocusedWindow()`, `getAllWindows()`, screen geometry helpers with multi-monitor support, and tiling functions that compute target `NSRect` values for each layout (halves, quarters, thirds, maximize, cycle-monitor).

3. **Event system** — A `CGEventTap` intercepts Ctrl+Opt key combinations globally and routes them to tiling actions via the `Config.Action` enum. An `AXObserver`-based `WindowObserver` tracks application lifecycle (window open/close) for potential future auto-tiling.

### Key patterns

- **Coordinate conversion** appears in multiple places: `nsPoint.y = mainHeight - posY` converts between Cocoa and AX origins.
- **CFTypeRef unwrapping**: get AX reference → cast to Swift type → extract value. This pattern repeats throughout all Accessibility API calls.
- **Enum dispatch**: `Config.Action` holds raw key-code values; a switch statement in the event tap callback routes actions cleanly.
- **Observer registry**: `WindowObserver.observers` maps app PIDs to `AXObserver` instances; `knownPIDs` prevents duplicates and cleanup runs on app termination.

### Keyboard shortcuts (defined in `Config.Action`)

| Shortcut | Action |
|---|---|
| Ctrl+Opt + ←/→/↑/↓ | Tile to left/right/top/bottom half |
| Ctrl+Opt + 1/2/3/4 | Tile to top-left/top-right/bottom-left/bottom-right quarter |
| Ctrl+Opt + Return | Maximize |
| Ctrl+Opt + 0/9/8 | Tile to first/center/last third |
| Ctrl+Opt + C | Move window to next display |
