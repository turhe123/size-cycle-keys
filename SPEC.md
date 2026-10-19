# SizeCycleKeys — specification

**Tagline:** Press one hotkey repeatedly to cycle a window through half, two-thirds and one-third widths, edge by edge.

**Category:** Window Management

**Inspired by (paid):** SizeUp ($12.99 one-time)

**Frameworks:** SwiftUI, AppKit, ApplicationServices, CoreGraphics, Carbon, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

(1) What the paid app does. SizeUp from Irradiated Software is a keyboard-first window sizer sold at about 13 dollars one time. Beyond fixed halves it is known for cycling sizes with repeated presses and for throwing windows between displays. It has been recommended for years by keyboard-centric users in comparison posts about Mac window managers. Our clean-room version, SizeCycleKeys, concentrates on the cycling idea, where one shortcut per direction walks through several sizes so you need very few shortcuts.

(2) Feature set. Four directional hotkeys, Control plus Option plus Left, Right, Up and Down. Pressing Left the first time sets the window to the left half, pressing again within two seconds changes it to the left two-thirds, then left one-third, then returns to half. The same applies to Right. Up cycles top half, top two-thirds, top third. Down cycles bottom equivalents. A Maximize hotkey toggles between maximized and the previous frame. A Center hotkey cycles center at 60 percent, 80 percent and original size. A Next Display hotkey moves the window to the next screen keeping its relative position and size. Cycle sequences are editable as lists of fractions. A small transient HUD displays the current layout name, such as Left 2/3.

(3) UI spec. MenuBarExtra listing each action and its hotkey for mouse use, plus Pause, Settings and Quit. Settings has a tab for Shortcuts with recorder fields for each action, a tab for Cycles where each direction has an editable ordered list of fractions chosen from a picker of 1/4, 1/3, 1/2, 2/3, 3/4, a tab for General containing the cycle reset timeout slider from 0.5 to 5 seconds, HUD toggle, gap size stepper, and launch at login. The HUD is a small centered rounded panel shown for 0.7 seconds. If Accessibility is missing the menu shows a grant button and shortcuts are disabled.

(4) Technical approach. Use AXIsProcessTrustedWithOptions for permission. Register hotkeys with Carbon RegisterEventHotKey. On each press, read the focused window of the frontmost application through the AX focused window attribute and its current frame, compute the screen with the largest overlap using NSScreen visibleFrame, and keep a small state struct recording last action, index in cycle and timestamp. If the same action repeats within the timeout and the window frame still equals the frame we last applied within 4 points, advance the index, else restart at index zero. Compute target frames by fraction with gap adjustments, then set position and size attributes using AXValue. Convert coordinates between Quartz and AppKit using the primary display height. Store cycles as Codable arrays in UserDefaults. Register launch at login with SMAppService. Around 400 lines.

(5) Edge cases. Windows with minimum sizes may not reach one-third, so detect failure by rereading the frame and skip to the next cycle step. Ignore full screen and non-resizable windows beyond moving them. Hotkeys that conflict with system shortcuts, like Mission Control arrow combos, should be flagged in the recorder with a warning. Remember the original frame per window ID for the maximize toggle, and drop entries when windows close. Multiple displays of different size use fractions of each display's own visible frame. Do not apply if the user is typing in a text field and the shortcut includes only Option, which is why the default includes Control.
