# KOReader Patches

A collection of user-space patches for [KOReader](https://github.com/koreader/koreader) — the open-source document viewer for E Ink devices.

These patches are loaded via KOReader's `userPatch` mechanism and applied at runtime without modifying core source files.

## Patches

### `2-nonblocking-wifi.lua`

Replaces the default Wi-Fi connection flow with a **non-blocking popup UI**.

**Problem:** KOReader's built-in Wi-Fi toggle freezes the UI while scanning for networks and connecting, leaving the user staring at an unresponsive screen.

**Solution:** This patch monkey-patches `NetworkMgr:toggleWifiOn` and `NetworkMgr:toggleWifiOff` to show a `WiFiQuickPopup` widget that:

- Runs network scanning in a **background subprocess** (via `ffiutil.runInSubProcess`) and polls for results, keeping the UI fully responsive.
- **Auto-connects** to known/saved networks by signal strength after each scan.
- Displays a live list of available networks with a refresh button.
- Provides a Wi-Fi on/off toggle button within the popup.
- Caches scan results so re-opening the popup is instant.
- Handles edge cases: popup closed mid-scan, multiple concurrent scan requests, Kobo-specific Wi-Fi enable.

## Installation

1. On your e-reader, navigate to the KOReader installation directory.
2. Create the `patches` directory if it doesn't exist:
   ```
   koreader/patches/
   ```
3. Copy the desired `.lua` patch file(s) into that directory.
4. Restart KOReader.

Patches are loaded in alphabetical order. The `2-` prefix controls load ordering.

## File Naming Convention

| Prefix | Meaning |
|--------|---------|
| `1-`   | Early-load patches (core overrides) |
| `2-`   | Standard patches (UI & feature mods) |
| `3-`   | Late-load patches (cosmetic tweaks) |

## Compatibility

- Tested on **Kobo** devices.
- Targets KOReader's Lua widget and network management APIs.
- May need updates when KOReader's internal APIs change.

## License

These patches are provided as-is for personal use with KOReader.
