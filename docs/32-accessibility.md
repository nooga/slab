# 32 — Accessibility: the UI as a tree

How a UI that draws every pixel itself becomes visible to VoiceOver,
to the Accessibility Inspector, and to scripts and agents that want to
read and drive it by name instead of by screenshot and coordinates.

Status: planned (2026-10-05). Nothing is built. Phases below.

## Why it is missing, and why it is cheap here

Slab draws through raylib into one OpenGL view. To macOS the window is a
single opaque canvas: VoiceOver says "Slab, window" and nothing else,
the Accessibility Inspector sees no children, and UI automation (XCUI,
AX scripting, an agent's computer use) has nothing but pixels. No
toolkit gives us accessibility for free; a custom-drawn UI publishes its
own tree or has none.

Three things make publishing one cheap in Slab:

- **Widget ids are explicit keys** (docs/06 §The `Ui` core), never rect
  hashes. Every control already has a stable identity from frame to
  frame, which is exactly what an accessibility element needs and what
  most immediate-mode UIs lack.
- **Controls come from one catalogue** (`ui/controls.zig`). A knob, a
  slider, a latch, a selector, a list, tabs: each is one function. If
  each one reports itself while it draws, most of the app is described,
  machine panels included, because their widget words go through the
  same catalogue (docs/15).
- **There is already a native bridge.** `native_app.m` installs the menu
  bar and talks to the `NSWindow` raylib hands us (`GetWindowHandle`);
  an accessibility bridge is one more file of the same kind.

## What else it buys

The same tree is a **test and automation surface**. Today the GUI is
verified by screenshots: a script or an agent clicks at guessed
coordinates and reads pixels back. With the tree, "press TUNE on clip
Vox", "what is CUTOFF on track 3", "is the Explode dialog open" become
lookups by name. That is worth building even before anyone runs
VoiceOver on Slab, and it is phase 1.

## The model

Each frame the `Ui` collects a flat list of **nodes** alongside its draw
list: what the frame drew, as a reader would want to hear it.

```zig
pub const Role = enum {
    window, group, toolbar, tab_group, tab,
    button, toggle, checkbox, radio, slider, knob, // knob = slider, round
    stepper, popup, list, row, cell, text_field, static_text,
    display, meter, menu, menu_item, dialog,
    // working surfaces
    timeline, lane, clip, note, marker, point, ruler, keyboard, key,
};

pub const Node = struct {
    id: Id,            // the widget id (stable across frames)
    parent: Id,        // the enclosing scope's node, 0 = window
    role: Role,
    rect: Rect,        // logical px; the bridge converts to screen points
    label: []const u8, // "CUTOFF", "Vox", "C4"
    value: Value,      // none | number (+min/max/step, formatted text) |
                       // on/off | choice index + text | text
    help: []const u8,  // the tooltip text, shortcut included
    actions: Actions,  // press, increment, decrement, show_menu,
                       // confirm, cancel, set_value, select, open
    flags: Flags,      // focused, selected, disabled, active, hidden
};
```

- **Collected, not retained.** Nodes live in a per-frame arena like the
  draw list (bounded: `MAX_NODES`, overflow sets a flag and drops
  leaves first). Strings are copied into the frame's text arena, since
  labels are often formatted into stack buffers.
- **Parents come from id scopes.** `pushId`/`popId` already nest
  (machine bay → panel → strip → control); a scope that wants to be a
  group (a panel, a dialog, a track header) opens one with
  `ui.group(role, label)` and every node inside gets it as parent.
- **Catalogue controls report themselves.** `knob`, `slider`, `toggle`,
  `latch`, `button`, `radio`, `list`, `tabs`, the display selectors,
  `ledToggle`, `meter`: each calls `ui.node(...)` with its role, label,
  formatted value (the same text the title-strip display shows,
  `setTouch`) and the actions it takes. One change per control; no
  per-panel work.
- **Working surfaces report their objects.** The arrangement reports
  lanes and the clips in view, the piano roll the keys and the notes in
  view, the audio editor its markers, automation lanes their points.
  Only what is on screen: a node per visible object, so a 20 000-note
  clip costs what its viewport shows. The surface node itself carries
  the scroll position and the visible range so a reader can say "bars
  9 to 16".
- **Off when nobody listens.** Collection costs a few hundred small
  writes per frame; it runs only while a client is attached (the
  bridge has been asked for children within the last few seconds, or
  `--ax-dump` / the test hook is on). The audio thread never sees any
  of it.

## The macOS bridge

`native_ax.m` turns the node list into `NSAccessibilityElement`s hung
off the window's content view.

- **Identity by id.** One element per node id, kept in a dictionary and
  reused across frames, so VoiceOver's cursor stays on "CUTOFF" while it
  moves. Elements whose id did not appear this frame are removed.
- **Lazy where it matters.** `accessibilityChildren` of a timeline or a
  clip is answered from the last frame's nodes on demand, not pushed.
- **Frames.** Logical rects through the renderer's scale and the
  window's origin to screen points, flipped to Cocoa's bottom-left
  origin.
- **Notifications.** Focus moved → `FocusedUIElementChanged`; a
  focused value changed → `ValueChanged`, coalesced to one per 100 ms
  while a knob is dragged; a dialog appeared → `WindowCreated`-style
  layout change; selection changed on a surface →
  `SelectedChildrenChanged`.
- **Actions come back as input.** `accessibilityPerformPress`,
  `Increment`, `Decrement`, `setAccessibilityValue:`, `ShowMenu` are
  queued (a lock-free ring from the main-thread AppKit callback to the
  frame; both run on the main thread, so a plain array swapped at
  `beginFrame` is enough) and the next frame applies them to the node
  id: a press becomes a synthetic click on its rect, increment and
  decrement the same step the arrow keys take on a focused control, a
  set value the same parse a typed value goes through. No control
  grows a second code path for accessibility.

## Keyboard operation

Reading the tree is half of it; a VoiceOver user also has to operate
Slab without the pointer. Most of this is the same work docs/31 does
for everyone:

- **Focus order.** Tab / Shift-Tab move focus through the focusable
  nodes of the focused pane in reading order (top-left to
  bottom-right by rect, groups kept together); Ctrl-Tab moves between
  panes (arrangement, clip editor, machine bay, mixer, browser).
  docs/06's focus-visible ring already draws it.
- **Value controls** already step with the arrows and take typed
  values (docs/06 §Interaction contract).
- **Buttons** press with Space or Return when focused (today they never
  take focus on click, which stays: they take it from Tab only).
- **Surfaces** move a cursor through their objects: arrows step clip
  to clip (lane to lane) or note to note (pitch to pitch); the command
  table of docs/31 acts on what is selected. Every surface command is
  a command with a key, so nothing needs a drag.
- **Menus and dialogs** are already keyboard-driven (arrows, Return,
  Escape).

## Testing hooks

- `slab --ax-dump <project> [--frames N]` opens the project headless,
  runs N frames and prints the node tree as JSON (id, role, label,
  value, rect, actions), the way `--describe` prints the document.
- A test helper builds a `Ui`, draws a pane or a panel, and asserts on
  its nodes: "the Explode dialog has five toggles and BASS is disabled
  without stems". UI tests without pixels.
- The same queue the bridge feeds takes scripted actions, so a test
  can press a node by label and draw the next frame.

## Phasing

1. **Collect and dump.** `Node`, `ui.node`, `ui.group`, the per-frame
   arena; every catalogue control reports itself; dialogs and menus
   report; `--ax-dump` and the test helper. Exit: the dump of the demo
   song names every control on every visible panel with its value.
2. **Read-only bridge.** `native_ax.m`: elements by id, frames, lazy
   children, focus and value notifications. Exit: the Accessibility
   Inspector walks the window; VoiceOver reads a machine panel and the
   track headers.
3. **Surfaces.** Lanes, clips, notes, markers, points, the piano-roll
   keys, with labels a reader can use ("Bass, clip 2, bars 5 to 9";
   "E2, beat 3.5, quarter, velocity 96").
4. **Act and focus.** Actions from the bridge, Tab focus order, buttons
   on Space/Return, surface cursors. Exit: load a song, pick a preset,
   play, mute a track and change a knob with VoiceOver and no mouse.

## Open questions

- Value text for VoiceOver: the dot-matrix strings are uppercase and
  abbreviated ("1.2K", "-6DB"). Probably a second, spoken format per
  unit ("1.2 kilohertz", "minus 6 decibels"), produced by the same
  formatter.
- Live machine panels are re-declared by fy code that may change while
  playing. Ids are keyed by panel word and control key, so a hot-patch
  that keeps keys keeps the reader's place; one that renames them
  moves it. That is acceptable.
- Large-text and contrast preferences: docs/06 already allows
  fractional scales; whether to follow the system's "increase
  contrast" with a second palette is a separate question.
