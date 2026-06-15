# Background Transition & Runtime UI — Change Summary

## Overview
Polished the crossfade transition between the two 3D backgrounds and made the
runtime control panel stable during transitions. The transition is a
zoom-crossfade rendered from two independent SubViewports (each its own
World3D / Camera3D / WorldEnvironment) onto full-screen TextureRects driven by
a zoom/fade `canvas_item` shader.

## `background_stage.gd`

### Runtime-adjustable transition time
- Kept `const TRANSITION_TIME := 1.2` as the default.
- Added `var transition_time := TRANSITION_TIME`, settable at runtime from the UI.
- `transition_to()` clamps duration with `maxf(0.05, transition_time)`.

### Easing of the motion (#1)
- Old layer zoom: `TRANS_SINE` / `EASE_IN` (accelerates into the camera).
- New layer zoom: `TRANS_SINE` / `EASE_OUT` (rises from depth, settles softly).
- Both fades use `TRANS_SINE` / `EASE_IN_OUT` for a smooth sinusoidal cross-dissolve.

### Transparent shader edges (#2)
- Out-of-bounds UVs (when `zoom < 1`) are made transparent instead of clamped,
  so no dark smears/borders — the black backdrop shows through:
  ```glsl
  float inside = step(uv.x, 1.0) * step(0.0, uv.x) * step(uv.y, 1.0) * step(0.0, uv.y);
  COLOR = vec4(c.rgb, c.a * fade * inside);
  ```

### Warm-up frame (#3)
- `await get_tree().process_frame` after instancing the new scene, before the
  tween starts — avoids an empty/white flash on the first visible frame.

### Early viewport sleep (#4)
- At ~90% of the duration (old layer effectively invisible), the outgoing
  viewport's `render_target_update_mode` is set to `UPDATE_DISABLED` — stops
  double-rendering a near-invisible layer.

### `transition_to(target_idx)` API
- Refactored `transition()` to delegate to `transition_to((_scene_idx + 1) % SCENES.size())`.
- `transition_to()` allows jumping to a specific scene index (basis for a
  future scene-selector in the UI). Guards against busy state, out-of-range
  indices, and re-selecting the current scene.

## `runtime_ui.gd`

### Fixed-size panel
- Added `const PANEL_HEIGHT := 660.0` (removed `BODY_HEIGHT`).
- Panel pinned: `custom_minimum_size` and `size` both set to
  `Vector2(PANEL_WIDTH, PANEL_HEIGHT)`, plus `clip_contents = true` — no more
  resizing while transitioning.

### Stable content (no horizontal shift)
- Root cause: content jumped because the scrollbar appeared/disappeared.
- Fix: `scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS`
  permanently reserves the scrollbar gutter.
- `scroll.custom_minimum_size = Vector2(0, 0)` and
  `size_flags_vertical = Control.SIZE_EXPAND_FILL`.

### Transition-time SpinBox
- Added a "trans time (s)" SpinBox above the TRANSITION button
  (min 0.1, max 10.0, step 0.05), writing to `BackgroundStage.transition_time`.
- Seeded from the stage via `_stage_transition_time()` helper (falls back to 1.2).

## Notes / things to verify
- Confirm the `\` line continuations in the tween chain parse cleanly in the editor.
- If a frozen-motion tail is visible at the end, nudge the viewport-sleep factor
  from `0.9` toward `0.95`.
