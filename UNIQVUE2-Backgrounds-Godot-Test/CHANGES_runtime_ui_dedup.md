# Runtime UI — Duplicate Param Fix

## Problem

Runtime UI showed duplicate and dead parameter sliders across multiple backgrounds.

`runtime_ui.gd` excludes shader uniforms that share an **exact name** with a scene `@export`
variable. Three failure modes bypassed this:

| Failure | Example |
|---|---|
| Name mismatch | `edge_glow` @export ≠ `glow` shader uniform |
| Computed value exposed | `z_far` set from `_span_z` every frame, not user-controllable |
| Style/animation value exposed | `opacity` / `scroll` / `tint` pushed from @export or Style every frame |

---

## Already Fixed (before this session)

| Background | Mechanism |
|---|---|
| SmoothWave | `group_uniforms _Live` in `smoothwave.gdshader` |
| Quantum | `group_uniforms _Live` in all 3 quantum shaders |
| ParticleWave | `group_uniforms _Sync` + `Appearance` in `wave_wire.gdshader`; Grid/GridTop share one material RID |

---

## Changes — 8 Shaders

### Cubic

**`cubic_surf.gdshader`**
- `z_far` → `_Sync` (pushed from `_span_z` every frame)

**`cubic_line.gdshader`**
- `glow` → `_Sync` (pushed from `edge_glow` @export, name mismatch)
- `z_far` → `_Sync` (same as surf)

**`cubic_part.gdshader`**
- `z_far` → `_Sync` (same as surf)

Result: all three shader sections (SURF / LINE / PART) are empty after exclude → pruned from UI.

---

### Plexus

**`plexus.gdshader`**
- `z_near` / `z_far` → `_Sync` (pushed from internal script vars every frame)
- `shape` stays visible — legitimate shader-only control (point style, not in @exports)

**`plexus_line.gdshader`**
- `z_near` / `z_far` → `_Sync`
- `line_opacity` / `depth_fade` already excluded via @exports

Result: STREAKS section empty → pruned. POINTS section shows only `shape`.

---

### Structure

**`structure_ground.gdshader`**
- `opacity` → `_Sync` (pushed from `ground` @export, name mismatch)
- `scroll` → `_Sync` (computed from `_travel` every frame)
- `tint` → `_Sync` (pushed from Style color every frame)
- `repeat_y` stays visible — moved **before** the `_Sync` block so it lands in the main section body

**`structure_grid.gdshader`**
- `opacity` → `_Sync` (pushed from `grid` @export, name mismatch)

Result: GRID section empty → pruned. GROUND section shows only `repeat_y`.

**`structure_part.gdshader`**
- `part_size` → `_Sync` (pushed from `particle_size` @export, name mismatch)
- `near_dist` / `far_dist` stay visible — moved **before** `_Sync` block
- Added `hint_range` to both for usable slider calibration:
  - `near_dist : hint_range(0.0, 2000.0, 50.0)`
  - `far_dist  : hint_range(500.0, 12000.0, 100.0)`

---

## Resulting UI Per Background

| Background | Sections |
|---|---|
| Tunnel | Flight · Distribution · Appearance · Camera |
| ParticleWave | Grid · Camera + **GRID** shader (16 wave params) |
| Stripes | Streifen · Variation · Darstellung |
| Lines | Linien · Form · Darstellung |
| Plexus | Netz & Bewegung · Komposition · Darstellung · Kamera + **POINTS** (`shape`) |
| Cubic | Welt & Flug · Material · Partikel · Tiefe & Fog · Kamera |
| Structure | Welt & Flug · Material · Elemente · Tiefe & Fog + **GROUND** (`repeat_y`) + **PART** (`near_dist` / `far_dist`) |
| SmoothWave | Form & Bewegung · Tuecher · Gruppen-Klone · Darstellung · Kamera |
| Quantum | Bewegung · Form · Klone · Sichtbare Ebenen · Polygone · Kanten & Punkte · Tiefe · Kamera |

All backgrounds: POST section (glow · vignette · grain · res · AA · dither) at bottom.

---

## Commit

```
hide dead/duplicate shader uniforms from runtime UI via _Sync groups
```
