# Session Summary — Particle Wave POC — 2026-06-10

## Project
UNIQVUE2 broadcast background — Godot 4.6.1 Forward+  
Port of Three.js/WebGL animated particle-wave field (220×220 point grid, GPU vertex-shader).  
Path: `particleWave-godot-CG-09062026/particle-wave-godot-extracted/particle-wave-godot/`

---

## Problems Fixed This Session

### 1. Vertical Stripe — Perspective Convergence (broad density band)
**Root cause:** Camera3D had near-zero yaw (forward vector ≈ (0, −0.259, 0.966)), meaning the
camera looked almost straight down the grid's Z-columns. Every constant-world-X column
converged to the vanishing point at exactly 50% screen width, creating a bright vertical
density pile-up dead-center.

**Fix:** Added +5° world-Y yaw to the Camera3D transform. Convergence point shifted from 50%
to ~54.9% screen width (field shifts right, no longer center-locked). Camera origin X also
moved from 9.34 → 0 to re-center the field symmetrically.

**File:** `particle_wave.tscn` — Camera3D transform line:
```
Transform3D(-0.996195, 0.022558, -0.084186, 0, 0.965926, 0.258819, 0.087156, 0.257834, -0.962250, 0, 4, -15)
```

---

### 2. Vertical Stripe — Moiré Aliasing (crisp residual seam)
**Root cause:** The perfectly regular 220×220 point lattice beat against the pixel grid,
producing a screen-locked seam that moved with camera X-translation. This survived every
camera orientation fix because it is purely a sampling artifact of the regular spacing,
independent of wave phase, glow, or post settings.

**Fix:** Seeded per-point positional jitter in `grid_builder.gd` (RNG seed=1337 for
reproducibility). Each point gets a random sub-cell offset in both X and Z, dissolving
the lattice regularity. Also added a progressive X-drift over depth (3 column-widths over
full Z range) to prevent identical `q.x` sampling along screen-columns.

**File:** `grid_builder.gd` — `_build_grid()` function.  
User confirmed: **"Fixed."**

---

### 3. Left-Heavy Asymmetric Framing
**Root cause:** Camera origin X was 9.34 (left of center relative to the grid).

**Fix:** Camera origin X → 0. Applied together with the yaw fix in `particle_wave.tscn`.

---

### 4. stretch/mode Canvas Items (2D resampling on 3D viewport)
**Root cause:** `project.godot` had `window/stretch/mode="canvas_items"`, a 2D mode that
resamples the 3D frame at non-native sizes, introducing blur and potentially aliasing.

**Fix:** Changed to `window/stretch/mode="disabled"` (correct for a 3D-only project).  
**File:** `project.godot`

---

## Feature Added This Session

### Subtle Animated X-Axis Noise (x_noise)
Two-frequency depth-varying horizontal sway on each particle column. Does not touch `field()`
(frozen). Controlled by inspector-tunable uniform `x_noise` (Wave group, 0.0–1.0, default 0.15).

**Shader:** `particle_wave.gdshader`
```glsl
uniform float x_noise : hint_range(0.0, 1.0) = 0.15;

// In vertex(), after pos.y = h * amp + y_off:
float xt = TIME * speed;
pos.x += x_noise * (sin(pos.z * 0.7 + xt * 1.3) * 0.6 + sin(pos.z * 2.3 - xt * 0.9) * 0.4);
```

**Scene:** `particle_wave.tscn` — `shader_parameter/x_noise = 0.15`

Tuning: 0.05–0.08 = barely visible / 0.15 = default subtle / 0.25–0.3 = visible sway.

---

## Current State of All Key Files

| File | Key State |
|------|-----------|
| `particle_wave.tscn` | Camera yaw +5°, origin X=0, x_noise=0.15 |
| `particle_wave.gdshader` | x_noise uniform + sway in vertex(); field() frozen |
| `grid_builder.gd` | Seeded jitter (seed=1337) + x_drift; regular lattice dissolved |
| `project.godot` | stretch/mode=disabled, msaa_3d=2, 1920×1080 Forward+ |

Backups of all changed files saved with `.2026-06-10.bak` suffix in the same directory.

---

## Known Stale Item (Minor)

`particle_wave.gdshader` line 3 comment says `depth_draw_opaque`; line 4 actually uses
`depth_draw_never`. Harmless — comment is wrong, shader behavior is correct.

---

## Step-by-Step Plan: What To Do Next

### Step 1 — Verify x_noise in Godot (immediate)
- F5 the project. The wave field should show gentle animated lateral sway.
- If too strong: lower `x_noise` toward 0.05–0.08 in the Inspector.
- If not visible: raise toward 0.2–0.3.
- If it looks right: lock the value by saving the scene (Ctrl+S in editor).
- Already checked. Ask if done anyways for confirmation.

### Step 2 — Fix Stale Shader Comment (quick housekeeping, ~1 min)
- `particle_wave.gdshader` line 3: replace  
  `// depth_draw_opaque sorgt dafuer, dass DOF ...`  
  with  
  `// depth_draw_never: Punkte schreiben keine Tiefe -> transparentes Additivblending korrekt.`

### Step 3 — Evaluate msaa_3d=2 on PRIMITIVE_POINTS
- MSAA has limited effect on point primitives (no geometry edges to smooth).
- Test with `anti_aliasing/quality/msaa_3d=0` (off) — if visually identical, remove it to
  save GPU cost. Change in `project.godot` or Project Settings → Rendering → Anti Aliasing.

### Step 4 — Next POC: Silk-Mesh
Port the second broadcast background visual.  
Architecture (planned):
- `PlaneMesh` with high subdivision count (e.g. 200×200 quads) — no ArrayMesh needed.
- Same vertex-shader wave approach: `field()` drives Y displacement.
- **Key difference from particle wave:** normals must be recomputed in the shader  
  (finite-difference cross-product from neighbor samples) for correct specular/lighting.
- Render mode: `vertex_lighting` or `unshaded` + custom specular — TBD based on look target.
- Lighting: add at least one `DirectionalLight3D` or `OmniLight3D` to the scene.
- DOF, Glow, tonemap: reuse same `WorldEnvironment` setup (copy from particle wave scene).
- Start with a duplicate of `particle_wave.tscn` as base, strip the ArrayMesh/grid_builder,
  replace with `PlaneMesh` MeshInstance3D + new shader.

### Step 5 — Per-POC Quality Gate Before Moving On
For each POC before calling it done:
1. Stripe-check: move camera ±5 units on X — no screen-locked seams.
2. Framing-check: field centered, no heavy left/right bias.
3. Glow-check: crest bloom present but not blown out (white/clipped).
4. Performance: confirm 60fps at 1920×1080 on target hardware.
5. Screenshot for archive.

---

## Constraints (Never Violate)

- `field()` function in every shader is **FROZEN** — 1:1 Three.js port, must not be modified.
- Renderer must stay **Forward+** — Glow/HDR/Bloom require it.
- Post-processing (Glow, DOF, tonemap, color adjust) stays in `WorldEnvironment`, not shader.
- Godot `.tscn` Transform3D: stored **row-major**; axis columns at stride 3.  
  Camera forward = −z_axis = −(basis[2], basis[5], basis[8]).
