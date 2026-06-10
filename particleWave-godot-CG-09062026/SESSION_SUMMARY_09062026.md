# Session Summary — Particle Wave Godot Port
**Date:** 2026-06-09  
**Working directory:** `particle-wave-godot-extracted/particle-wave-godot/`

---

## What Was Done

### A) Camera Transform (Issue A from handover)

**Problem:** Default camera produced a black screen on first open.  
**Fix:** Corrected `Camera3D` transform in `particle_wave.tscn`.

| Parameter | Old (broken) | New (correct) |
|---|---|---|
| Position | (0, 8, -14) | (9.34, 4, -15) ¹ |
| Rotation | ~+15° X tilt | -15° X, 180° Y |

**Transform3D:** `(-1, 0, 0, 0, 0.965926, 0.258819, 0, 0.258819, -0.965926, 9.34, 4, -15)`

> ¹ X=9.34 is the user's live-adjusted value (camera moved during session). Original fix used X=0; user shifted laterally in Godot.

---

### B) Render Mode — Depth Write / Blend Mode

**Problem:** `depth_draw_opaque` caused semi-transparent near-points to occlude brighter far-points via depth buffer writes.  
**Fix:** Changed shader render mode.

```gdshader
// Before
render_mode unshaded, depth_draw_opaque, cull_disabled;

// After
render_mode unshaded, depth_draw_never, blend_add, cull_disabled;
```

**Why `blend_add`:** Glowing particles should accumulate additively. With depth writes disabled, points no longer occlude each other, and additive blending creates the correct HDR glow-feed behavior.

**Trade-off:** `depth_draw_never` means the DOF pass has no per-particle depth data. All particles receive a uniform far-blur amount. Acceptable for a background visual.

---

### C) Vertical Stripe Artifacts (Issue B from handover) — Three-Part Fix

#### C1 — Wave-Column Phase Lock (grid_builder.gd)

**Root cause:** The grid was a perfect rectangular lattice. Every point in a column shared the same world-X → same `q.x = pos.x * 6`. With `dir = Vector2(0, 1)` (pure Z flow), `q.x` was static in time. The dominant wave `sin(q.x + q.y * 0.6)` sampled the identical X-phase for every Z-row in a column. If that X-phase happened to be a wave trough, the entire vertical column was dark → permanent knife-cut stripe.

**Fix:** Added a progressive X-drift across depth in `grid_builder.gd`:

```gdscript
var col_spacing := span_x / float(grid_w - 1)
var x_drift := (float(zz) / float(grid_h - 1)) * col_spacing * 3.0
var fx := (float(xx) / float(grid_w - 1) - 0.5) * span_x + x_drift
```

**Effect:** 3 column-widths of drift over the full span_z (0.82 world units over 120) = 78% wave-cycle phase shift between near and far rows within any screen-column. No screen-column can stay locked to a trough across all depths. Visually imperceptible (0.014° tilt).

#### C2 — Static Crest Line (shader_parameter/dir)

**Root cause:** With `dir = Vector2(0, 1)`, the wave flowed purely in Z. Wave crests had fixed screen-X positions at any moment, occasionally projecting as a bright near-vertical line.

**Fix:** Added small X component to flow direction:
```
shader_parameter/dir = Vector2(0.2, 1)
```
Wave now drifts laterally at ~0.04 world-units/sec (one full X-cycle every ~25 s). No crest line can hold a fixed screen position.

#### C3 — Glow-Generated Screen-Space Stripes

**Root cause:** Confirmed screen-space (stripes moved with camera, not with world content). Godot 4's glow pipeline extracts pixels above `glow_hdr_threshold` (was 0.85). The particle cloud created a high-contrast binary bright-pass texture: additive crest areas far exceeded 0.85, dark troughs were entirely excluded. The separable Gaussian blur in the glow mip-pyramid could not fully smooth this high-contrast pattern. Vertical structure survived the blur and composited back as screen-space stripes.

**Fix:**
```
glow_hdr_threshold = 0.3   # was 0.85 — more particles contribute, uniform glow source
glow_hdr_scale    = 1.0   # was 2.0 — reduces HDR spike amplitude before blur
```

More particles in the glow source → smoother extraction → blur works as intended → no stripes.

---

## DOF Adjustment

`dof_blur_far_transition` changed from 30.0 → 45.0 during diagnostics (softer DOF falloff). Kept as improvement.

---

## Final State of Changed Files

### `particle_wave.gdshader` (line 4)
```gdshader
render_mode unshaded, depth_draw_never, blend_add, cull_disabled;
```

### `particle_wave.tscn` — key values
```
# Camera
transform = Transform3D(-1, 0, 0, 0, 0.965926, 0.258819, 0, 0.258819, -0.965926, 9.34, 4, -15)

# Environment
glow_hdr_threshold = 0.3
glow_hdr_scale = 1.0
dof_blur_far_transition = 45.0

# Shader parameters
shader_parameter/dir = Vector2(0.2, 1)
```

### `grid_builder.gd` (inside `_build_grid()`)
```gdscript
var col_spacing := span_x / float(grid_w - 1)
# ...
var x_drift := (float(zz) / float(grid_h - 1)) * col_spacing * 3.0
var fx := (float(xx) / float(grid_w - 1) - 0.5) * span_x + x_drift
```

---

## Open / Not Done

- **Issue C (parameterization / docs)** — not addressed this session.
- **Issue D (in-game control panel)** — explicitly deferred (post A–C).
- **Stripe verification** — glow parameter fix applied but not yet confirmed clean by user.
- **Next POC: Silk-Mesh** — not started.

---

## Constraints Carried Forward

- Godot 4.6.1, Forward+ renderer only (Glow requires it).
- `field()` function in shader is frozen — 1:1 Three.js port, do not rewrite.
- Post-pipeline lives in WorldEnvironment, not in shader.
- Point sprites capped at ~64px on most GPUs (NVIDIA, Apple M-series).
- Five point shapes (Ring/Star/Cross etc.) not ported — needs MultiMesh + QuadMesh if required.
