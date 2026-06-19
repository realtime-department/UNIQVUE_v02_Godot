# UNIQVUE2 — Broadcast Background Visuals (Godot) — Developer Handover

> **Audience:** A developer taking ownership of this project with no prior context.
> **Source of truth:** This document was generated from a full static read of the *code* (GDScript, shaders, scenes, project config) — not from the other `.md` notes in the repo. Where the code and the older notes disagree, trust the code.
> **Last reviewed against code:** 2026-06-19.

---

## 0. Table of Contents

1. [What this is, in one paragraph](#1-what-this-is-in-one-paragraph)
2. [Tech stack & requirements](#2-tech-stack--requirements)
3. [How to open, run, and build](#3-how-to-open-run-and-build)
4. [Repository layout](#4-repository-layout)
5. [Architecture overview](#5-architecture-overview)
6. [Boot sequence (the 11 autoloads)](#6-boot-sequence-the-11-autoloads)
7. [The render engine (BackgroundStage)](#7-the-render-engine-backgroundstage)
8. [The parameter / preset / sequencer system](#8-the-parameter--preset--sequencer-system)
9. [The 9 background scenes](#9-the-9-background-scenes)
10. [Shaders](#10-shaders)
11. [Multi-monitor / wall output (DisplaySetup)](#11-multi-monitor--wall-output-displaysetup)
12. [The overlay module system (slots, slideshow, text, agenda)](#12-the-overlay-module-system)
12.5. [The launcher / boot gate (Launcher)](#125-the-launcher--boot-gate-launcher)
13. [Runtime control panel (RuntimeUI)](#13-runtime-control-panel-runtimeui)
14. [Performance HUD (PerfMonitor, F1)](#14-performance-hud-perfmonitor-f1)
15. [Persistence: where state lives on disk](#15-persistence-where-state-lives-on-disk)
16. [Input & UI quick reference](#16-input--ui-quick-reference)
17. [Performance: what was optimized, what's deferred](#17-performance-what-was-optimized-whats-deferred)
18. [Known issues, incomplete work & tech debt](#18-known-issues-incomplete-work--tech-debt)
19. [Roadmap / what it *should* do next](#19-roadmap--what-it-should-do-next)
20. [Verification checklist for the new owner](#20-verification-checklist-for-the-new-owner)
21. [Conventions & gotchas for maintainers](#21-conventions--gotchas-for-maintainers)
22. [Glossary](#22-glossary)

---

## 1. What this is, in one paragraph

**UNIQVUE2-Backgrounds** is a real-time **broadcast background-visuals generator** built in **Godot 4.7 (Forward+)**. It renders animated full-screen 3D/2D backgrounds (nine of them: tunnel, particle wave, stripes, lines, plexus, cubic, structure, smooth-wave, quantum), lets an operator tune every parameter live from an in-app panel, cross-fades between backgrounds with a hardware-accelerated zoom transition, and composites everything through an HDR pipeline (bloom → ACES tonemap → vignette/grain/dither) to a video wall that can **span multiple physical monitors**. On top of the background it can overlay **content modules** — image slideshows, rich-text panels, and an agenda/rundown system — placed into freely-positioned "slots". Full looks can be saved as **presets**, chained into a **sequencer playlist**, or captured as **agenda cues**. It is a 1:1 Godot port of an earlier web tool (`studio-v005.html` / `studio-v026.html`), which the code references throughout.

The project targets a **Windows broadcast workstation** (the only export preset is Windows x86_64; the hardware HUD uses Windows-only tooling).

---

## 2. Tech stack & requirements

| Item | Value |
|---|---|
| **Engine** | Godot **4.7**, **Forward+** renderer (`project.godot` → `config/features = ("4.7", "Forward Plus")`). *Note:* `config/description` still says "4.6.1" — stale string, ignore it. |
| **Language** | GDScript only. (`[dotnet]` assembly name is set but there is **no C# code** in the tree.) |
| **Platform** | Windows 11 (developed/tested). Renders fine cross-platform, but the F1 hardware HUD and BPTC textures are Windows-first (see §14, §18). |
| **GPU features used** | HDR-2D SubViewports (FP16), TAA/MSAA/SSAA, glow/bloom, `use_point_size` (4.7+), `RenderingServer.multimesh_set_buffer`. |
| **Default render resolution** | 1920×1080 window; wall target defaults to a **3×1 grid of 3840×2160** screens (= 11520×2160). |
| **External tools (optional, HUD only)** | `nvidia-smi`, `powershell.exe` (WMI). All have graceful fallbacks. |
| **Lines of GDScript** | ~11,000 across 32 scripts. The two biggest: `runtime_ui.gd` (~1457) and `modules/text/text_settings.gd` (~804). |

---

## 3. How to open, run, and build

### Open
1. Install **Godot 4.7** (standard build; no Mono required despite the `[dotnet]` section).
2. `File → Open Project` → select `project.godot` at the repo root.
3. On first load the editor regenerates `.godot/` caches and texture `.ctex` files automatically.

### Run
- **F5** (Play). `main.tscn` is an **empty `Node`** — *all* logic lives in autoloads. The app boots into the **Launcher** (a full-screen gate overlay, windowed); the background stage (`tunnel_wave`) and control panel run *behind* it. Enter PIN **2468**, pick a session, press **Playout starten** to reveal the live runtime. **F12** re-opens the launcher.
- **Tab** toggles the control panel; **F1** toggles the performance HUD.

### Command-line display overrides
```
godot --windowed     # force a normal framed window
godot --span         # force borderless across all connected screens
```
These set the **playout target** mode (resolved at boot; see §11). They do **not** change the launcher itself — the launcher is always a framed window. With no flag the playout target is: saved SPAN/PREVIEW if any, else 1 screen → windowed, 2+ screens → span (auto-detected). The chosen mode is applied only when **Playout starten** is pressed.

### Build (Windows)
- Export preset **"Windows Desktop"** is pre-configured in `export_presets.cfg`:
  - Output: `BUILDED/AlphaBuild.exe`
  - `embed_pck = true` → single self-contained `.exe` (all assets embedded).
  - Texture compression: **S3TC/BPTC** only (`etc2_astc` is off — see cross-platform caveat in §18).
  - Shader baking enabled.
- `Project → Export → Windows Desktop → Export Project`. Requires Windows export templates installed in the editor.

---

## 4. Repository layout

Flat root for the core engine + backgrounds; `modules/` for the overlay content system.

```
project.godot              Engine config: 11 autoloads, shader globals, display
main.tscn                  Empty Node (entry point; logic is in autoloads)
export_presets.cfg         Windows export profile → BUILDED/AlphaBuild.exe
icon.svg                   App icon

# ── Core singletons (autoloads) ───────────────────────────
style.gd                   S0  Global color palette → global shader uniforms
display_setup.gd           --  Window / multi-monitor (WINDOWED/PREVIEW/SPAN)
background_stage.gd        S1  Dual-viewport render engine + transitions + post
param_store.gd             S2  Flat parameter registry (capture/apply/lerp)
bg_core.gd                 S3  Preset JSON I/O (scene + style presets)
sequencer.gd               S4  Preset playlist playback
runtime_ui.gd              --  In-app control panel (auto-built from params)
perf_monitor.gd            --  F1 performance/hardware HUD
launcher.gd                --  Boot gate overlay (PIN/session/playout); CanvasLayer 200

# ── The 9 backgrounds (each: root/sim script + shader(s) + .tscn) ──
tunnel_sim.gd        tunnel_head.gdshader  tunnel_streak.gdshader  tunnel_wave.tscn
particle_wave_root.gd particle_wave.gdshader wave_wire.gdshader     particle_wave.tscn
stripes_root.gd      stripes.gdshader                               stripes.tscn
lines_root.gd        lines.gdshader                                 lines.tscn
plexus_sim.gd        plexus.gdshader        plexus_line.gdshader    plexus.tscn
cubic_sim.gd         cubic_surf/line/part.gdshader                  cubic.tscn
structure_sim.gd     structure_surf/grid/ground/part.gdshader       structure.tscn
smoothwave_root.gd   smoothwave.gdshader                            smoothwave.tscn
quantum_sim.gd       quantum.gdshader  quantum_edge/point.gdshader  quantum.tscn
grid_builder.gd      gradient_sky.gdshader   (shared helpers)

# ── Overlay content modules ───────────────────────────────
modules/slot_manager.gd        Autoload "SlotManager": 64-slot wall layout
modules/slot_node.gd           Per-slot SubViewportContainer host
modules/slot_settings.gd       Slideshow settings panel (embedded in editor)
modules/slot_layout_editor.gd  F2 drag-to-arrange layout editor (+ .tscn)
modules/module_drag_button.gd  Palette drag source
modules/agenda_manager.gd      Autoload "Agenda": show-state cues
modules/agenda_ui.gd           "A" key cue panel (+ .tscn)
modules/slideshow/             Slideshow module (carousel/coverflow/grid/…)
modules/text/                  Text module (static/ticker/clock/countdown/cycle)

# ── Assets & misc ─────────────────────────────────────────
textures/                      Structure_*.png, Grid_Rectangles.png (BPTC+mips),
                               structure_geo.json (corridor geometry)
test_spans.gd                  Standalone SceneTree self-test for text BBCode spans
.godot/  .omc/  .claude/       Tooling/cache — not part of the app
```

Every `.gd`/`.gdshader`/`.tscn` has a sibling `.uid`/`.import` — Godot bookkeeping, leave them alone.

---

## 5. Architecture overview

The system is layered. The author labelled the layers **S0–S4** in code comments:

| Layer | Singleton | Role |
|---|---|---|
| **S0** | `Style` | One global color palette (8 colors) pushed to **global shader uniforms**. Every background reads the same `elem_a`, `elem_b`, `fog_color`, `sky_*`. |
| **S1** | `BackgroundStage` | The render engine: two off-screen viewports, the zoom-crossfade, the HDR master composite, and the final on-screen post pass. |
| **S2** | `ParamStore` | A flat registry of *every* tunable value in the active scene, with type-aware get/set. The bridge that makes presets and morphing possible. |
| **S3** | `BgCore` | Saves/loads `ParamStore` snapshots (and style palettes) as JSON presets. |
| **S4** | `Sequencer` | Plays an ordered playlist of presets, blending between them. |

Supporting systems: `DisplaySetup` (wall config), `RuntimeUI` (the panel that *views* `ParamStore`), `PerfMonitor` (HUD), and the `modules/` overlay system (`SlotManager` + `Agenda` + content modules).

### Component map

```
                                   [ SCREEN ]
                                       ▲
                _final TextureRect (CanvasLayer 0)
                OVERLAY_SHADER: ACES tonemap + Vignette + Grain + Dither
                                       ▲
   RuntimeUI (CanvasLayer 100)  ─────► reads/writes via getters/setters
   PerfMonitor (CanvasLayer 102, F1)
   Agenda UI (103, "A")  /  Slot editor (101, F2)  /  Slots (50)
                                       ▲
   ┌──────────────── BackgroundStage (CanvasLayer 0) ────────────────┐
   │  _master SubViewport (HDR-2D)  ── WorldEnvironment: GLOW/BLOOM   │
   │     ▲ additive composite of two layer rects (zoom+fade shader)   │
   │  ┌─ _vps[0] (ACTIVE, UPDATE_ALWAYS) ─┐ ┌─ _vps[1] (STANDBY) ─┐   │
   │  │  scene root + Camera3D + WE        │ │  next scene root    │   │
   │  │  own World3D                       │ │  own World3D        │   │
   │  └────────────────────────────────────┘ └─────────────────────┘   │
   └─────────────────────────────────────────────────────────────────┘
             ▲ active_changed(root)            ▲ aspect_changed(aspect)
             │                                 │
   ParamStore (S2) ◄── BgCore (S3 presets)  ◄── Sequencer (S4 playlist)
        ▲   registry: style/ scene/ mat/ post/ overlay/
        │
   Style (S0) ─► RenderingServer.global_shader_parameter_set(...)
   DisplaySetup ─► WINDOWED / PREVIEW / SPAN, render-size override
```

**Key idea:** scenes are *dumb* — they expose `@export` vars and shader uniforms and animate themselves in `_process`. They know nothing about presets, the UI, or transitions. Everything else is wired through `ParamStore` and the `active_changed` signal.

---

## 6. Boot sequence (the 11 autoloads)

Order is defined in `project.godot [autoload]` and **matters**:

1. **Style** — initializes the 8-color palette into global shader uniforms. No deps.
2. **DisplaySetup** — must come *before* BackgroundStage so the window is sized correctly before the viewports are created. Reads `user://display_config.cfg`, **boots WINDOWED** (the launcher gate), and resolves the *playout-target* mode (applied later by `start_playout()`; see §11).
3. **BackgroundStage** — builds the two SubViewports + master composite + overlay; loads `SCENES[0]` (tunnel); fires `active_changed`.
4. **ParamStore** — defers `_connect_stage()` one frame, then listens to `active_changed` and builds its registry from the active scene.
5. **BgCore** — preset file I/O; lazily grabs the ParamStore reference.
6. **Sequencer** — loads `user://sequence.json` (playlist); transport idle at start.
7. **RuntimeUI** — the panel (CanvasLayer 100); rebuilds its controls every `active_changed`.
8. **PerfMonitor** — F1 HUD (CanvasLayer 102).
9. **SlotManager** — overlay slot layer (CanvasLayer 50); loads `user://slot_layouts.json`.
10. **Agenda** — show-state cue manager; instantiates its UI (CanvasLayer 103).
11. **Launcher** — boot gate overlay (CanvasLayer 200, above everything). Built last so `Agenda`/`DisplaySetup` exist when it queries the session list. Shows opaque on top of the already-running stage until **Playout starten** (see §12.5).

> If you reorder these (especially moving `ParamStore` before `BackgroundStage`, or `DisplaySetup` after it), initialization breaks **silently**. There's no runtime assert guarding the order.

---

## 7. The render engine (BackgroundStage)

This is the most important file in the project (`background_stage.gd`, ~537 LOC). It is a **CanvasLayer at layer 0** (below all UI).

### What it builds in `_ready()`
- **Two layer viewports** `_vps[0]`, `_vps[1]` — each `own_world_3d`, `use_hdr_2d` (FP16), `use_debanding`. Only the active one runs (`UPDATE_ALWAYS`); the standby is `UPDATE_DISABLED` (no GPU cost).
- **Two layer rects** `_rects[0..1]` — full-screen `TextureRect`s textured from the viewports, each driven by `LAYER_SHADER` (a `canvas_item` shader, `render_mode blend_add`, with `zoom` + `fade` uniforms).
- **A master composite viewport** `_master` — HDR-2D, `own_world_3d`, holds the two layer rects + a `WorldEnvironment` whose **only job is glow/bloom** across the additive blend.
- **A final on-screen rect** `_final` — textured from `_master`, driven by `OVERLAY_SHADER` which does **ACES tonemap → vignette → film grain → triangular-PDF dither**. This pass runs *after* TAA, so the dither uses a static integer hash (no temporal crawl).
- **A blackout `ColorRect`** for broadcast cuts (`set_blackout(alpha)`).

### The transition (`transition_to(target_idx, mode)`)
Default `mode = "zoom"`, duration `transition_time` (default `1.2 s`), `ZOOM_SPAN = 2.0`:
- Load the new scene into the standby slot, find its `Camera3D`, **pre-apply cached params** (`ParamStore.preapply_to_scene`) so it renders in its target state — no visible ramp.
- `await get_tree().process_frame` (warm-up frame, avoids a white flash).
- Parallel tween:
  - outgoing: `zoom 1 → 2` (ease-in), `fade 1 → 0`
  - incoming: `zoom 2 → 1` (ease-out), `fade 0 → 1`
  - At t=0.5 both layers are at zoom 2 (same perceived depth); additive blend with complementary fades preserves luminance — **no mid-transition darkening or transparency hole**.
- At 90% of the duration the outgoing viewport is set `UPDATE_DISABLED`.
- On `finished`: free the old scene, swap `_active`, emit `active_changed(new_root)`.
- A `_busy` latch prevents overlapping transitions; a `dur + 1.0 s` fallback timer clears it even if the tween is orphaned (scene reload).
- `mode = "cross"` does a pure fade with no zoom.

### Public API you'll actually call
`transition()` (next scene), `transition_to(idx, mode)`, `active_root()`, `active_texture()` (the composited master, used by preview windows), `set_hdr_mode(bool)`, `set_blackout(a)`, `set_render_size_override(Vector2i)` / `clear_render_size_override()`, `set_antialiasing(msaa, ssaa, taa)`, `set_deband(lsb)`, `canvas_aspect()`, `width_factor()`. Signals: `active_changed(root)`, `aspect_changed(aspect)`.

> **`set_hdr_mode` is not a bug, despite appearances.** It sets `aces_enabled = not enabled`. That is intentional: in true-HDR output mode you *skip* the ACES SDR tone-compression and send linear HDR to the display; in SDR mode you apply ACES. `get_hdr_mode()` inverts back. Read it as "HDR on ⇒ ACES off."

### Aspect handling
On resize / SPAN / render-size override, `_apply_vp_size()` resizes all viewports, updates the global `sky_viewport_h` uniform (the sky gradient is screen-space), and emits `aspect_changed`. 3D backgrounds multiply their **X extent** by `width_factor() = aspect / (16:9)` so content fills ultrawide walls instead of clustering in the center. Only X is scaled (no vertical distortion).

---

## 8. The parameter / preset / sequencer system

### ParamStore (S2) — the registry
On every `active_changed`, `ParamStore` rebuilds a flat list of **entries**, each `{key, type, getter, setter}`. Keys follow a fixed schema:

| Prefix | Source | Scope |
|---|---|---|
| `style/<name>` | `Style` palette color | cross-scene |
| `scene/<export>` | an `@export` var on the scene root script | scene-specific |
| `mat/<NodeName>/<uniform>` | a `ShaderMaterial` uniform in the scene | scene-specific |
| `post/<prop>` | master glow Environment (`glow_intensity/strength/bloom/hdr_threshold`) | global |
| `overlay/<prop>` | overlay material (`vignette`, `grain`) | global |

- **Shader uniform groups whose name starts with `_` (e.g. `_Sync`, `_Live`) are skipped** — they hold values the script pushes every frame and that should *not* appear as UI sliders. This is the central dedup mechanism (together with: a uniform whose name exactly matches an `@export` is also hidden).
- `capture()` → `{key: value}` snapshot. `apply(dict)` → set everything (keys not in the current scene are silently skipped — clean partial recall). `lerp_values(a,b,t)` / `apply_lerp` → type-aware morph (Color/Vector lerp, int round-lerp, bool step at 0.5).
- **Scene cache:** when you leave a scene, its `scene/*` + `mat/*` values are cached in `_scene_cache[name]` and re-applied when you return — so live tweaks survive scene switches within a session (they are *not* written to disk; save a preset for that).

### Style (S0)
8-color palette (`sky_zenith/mid/horizon/ground_mid/ground`, `fog_color`, `elem_a`, `elem_b`). `set_color` immediately calls `RenderingServer.global_shader_parameter_set`, so all shaders update next frame. Pickers work in sRGB; shaders receive linear via `:source_color`.

### BgCore (S3) — presets
- `save_current(name)` captures ParamStore, **strips `style/*`** (palette has its own presets), encodes Color/Vector as tagged JSON objects, writes `user://presets/<name>.json` with `{version, scene, params}`.
- `load_preset(name)` reads + decodes + `ParamStore.apply`.
- Separate **style presets** in `user://style_presets/`.
- Also exposes `diff/resolve/summarize` (sparse root+delta utilities) and public `encode_snapshot/decode_snapshot` (used by Agenda).

### Sequencer (S4) — playlist
- Steps: `{preset, hold, trans, mode}` (only these four keys are valid; others are rejected with a `push_warning`). Persisted to `user://sequence.json`.
- `play()` loops: apply start step → wait `hold` → blend to next over `trans`. **Same scene ⇒ parameter morph** (`apply_lerp`); **different scene ⇒** `BackgroundStage.transition_to` then apply the preset.
- `next()/prev()` work while stopped. Abort safety uses a **generation counter** (`_gen`): each new transport op increments it; running coroutines bail when their captured generation goes stale.
- `_ensure_scene` has a timeout guard (won't hang if `active_changed` never fires).

### End-to-end: what happens when you drag a slider
1. RuntimeUI's bound setter runs `material.set_shader_parameter(...)` (or `obj.set(prop, ...)`) immediately — live feedback.
2. The value is read back by ParamStore's getter whenever a snapshot is captured.
3. Save → `BgCore.save_current` → JSON. Load → `BgCore.load_preset` → `ParamStore.apply` → setters fire → UI re-syncs.

---

## 9. The 9 background scenes

`BackgroundStage.SCENES` order (and `SCENE_LABELS`):

| # | Scene file | Label | Script | Technique (short) |
|---|---|---|---|---|
| 0 | `tunnel_wave.tscn` | Tunnel | `tunnel_sim.gd` | Radial light-streak tube + swirling particles; ≤6000 particles; CPU sim → batched mesh upload |
| 1 | `particle_wave.tscn` | Wave | `particle_wave_root.gd` + `grid_builder.gd` | Two mirrored point grids (default 220×220) wave-deformed **in the vertex shader**; wire overlay |
| 2 | `stripes.tscn` | Stripes | `stripes_root.gd` | Full-screen `canvas_item` shader; 3 cross-drifting slat layers |
| 3 | `lines.tscn` | Lines | `lines_root.gd` | 40 000 instanced speed-streaks (MultiMesh + orthographic camera; vertex writes clip-space directly) |
| 4 | `plexus.tscn` | Plexus | `plexus_sim.gd` | ≤900-point drifting network with spatial-grid neighbour links (lines + points) |
| 5 | `cubic.tscn` | Cubic | `cubic_sim.gd` | 6000-cube MultiMesh grid w/ Half-Lambert lighting + optional wireframe + particles |
| 6 | `structure.tscn` | Structure | `structure_sim.gd` | Pre-loaded lightmapped corridor (`structure_geo.json`) + ceiling grid + scrolling ground + particles |
| 7 | `smoothwave.tscn` | SmoothWave | `smoothwave_root.gd` | 4 group-clones × 6 layer sheets (MultiMesh cloth) with harmonic vertex displacement |
| 8 | `quantum.tscn` | Quantum | `quantum_sim.gd` | K-NN triangulated tube (1100 verts) rendered as polys + edges + points, 1–5 clones |

**Common structure of each scene:** root `Node3D` → `WorldEnvironment` (sky uses `gradient_sky.gdshader`) + `Camera3D` (internally animated, not input-driven) + geometry. They read global `elem_a/elem_b/fog_color`, expose grouped `@export`s (e.g. `Welt & Flug`, `Material`, `Kamera` — UI groups are partly German), and animate in `_process` with `minf(delta, 0.05)` delta-clamping (most of them).

**Performance patterns to know:**
- `cubic_sim` and the particle uploads use the **fast path**: fill a persistent `PackedArray` once per frame and push it in one call (`RenderingServer.multimesh_set_buffer` / `add_surface_from_arrays`) — *not* per-instance/per-vertex calls.
- `structure_sim` still uses **per-instance** `set_instance_transform()` (~270 calls/frame) — a known un-migrated hot spot (see §18).
- `grid_builder` adds per-point jitter + progressive X-drift to break the moiré/phase-lock that a regular lattice produces against the pixel grid.

**Origin:** all nine are ported 1:1 from the web tool; comments cite `studio-v005.html` / `studio-v026.html` line numbers. The newest five (plexus, cubic, structure, smoothwave, quantum) were added most recently.

---

## 10. Shaders

21 `.gdshader` files. Conventions:

- **Color comes from global uniforms** `elem_a`, `elem_b`, `fog_color`, `sky_*` (declared `: source_color`, set via `RenderingServer.global_shader_parameter_set`). Change the palette once, every shader updates.
- Most overlay geometry is `unshaded`, `depth_draw_never`, `blend_add` (additive bloom feed); SmoothWave is the exception (`blend_mix`, translucent).
- `group_uniforms _Sync` / `_Live` mark script-pushed-per-frame uniforms that ParamStore/RuntimeUI deliberately **hide** (z_near/z_far, computed opacities, style tints pushed from `@export`s with mismatched names).
- **Two compositing shaders are defined inline as strings** in `background_stage.gd`: `LAYER_SHADER` (zoom+fade, additive) and `OVERLAY_SHADER` (ACES + vignette + grain + dither). `DisplaySetup` similarly defines `SLICE_SHADER` inline for preview windows.
- `gradient_sky.gdshader` is a **screen-space** 5-stop vertical gradient (uses the global `sky_viewport_h` float, not the camera) so it scales correctly on any wall aspect.
- `lines.gdshader` switched to an **integer hash** (`lowbias32`) to avoid `fract(sin())` banding at 40k instance IDs — a pattern the other procedural shaders mostly do not yet follow.

---

## 11. Multi-monitor / wall output (DisplaySetup)

`display_setup.gd` manages three modes (`enum Mode { WINDOWED, PREVIEW, SPAN }`):

- **WINDOWED** — normal framed 1920×1080 window.
- **SPAN** — borderless window over the **union rectangle of all connected screens** (auto-detects count/arrangement via `DisplayServer`). This is the live broadcast-wall mode.
- **PREVIEW** — a dev convenience: opens **one OS window per virtual grid cell**, each showing exactly its slice of the full composited image via `SLICE_SHADER`, with a `gap` between windows to simulate the bezel seam. Renders the stage at full wall resolution via `set_render_size_override`.

Virtual grid is configurable (`configure(cols, rows, screen_w, screen_h)`), **default 3×1 @ 3840×2160**. State persists to `user://display_config.cfg`. CLI: `--span` / `--windowed`.

### Launcher gating (the boot mode is decoupled from the playout mode)

Because the **Launcher** (§12.5) is shown first, the app **always boots WINDOWED** — it no longer auto-spans at startup. DisplaySetup splits this in two:

- At boot, `_resolve_playout_mode(saved)` decides the intended **live-output** mode and stores it in `_playout_mode` (priority: `--windowed` → `--span` → saved SPAN/PREVIEW → multi-screen auto-span → windowed). It does **not** apply it — it calls `restore_window(false)` and stays framed.
- `start_playout()` applies `_playout_mode` (span / preview / window). The Launcher calls it on **Playout starten**.
- `enter_launcher()` drops back to a framed window (called on F12 re-lock).
- `restore_window(persist := true)` gained the flag: launcher gating passes `persist=false` so dropping to a window does **not** overwrite the saved SPAN/PREVIEW preference in `display_config.cfg`. The live RuntimeUI STAGE buttons still persist (they call with the default `true`).

---

## 12. The overlay module system

Content drawn *on top of* the background. Two autoloads plus content modules.

### SlotManager (autoload, CanvasLayer z=50)
- A **slot** is a rectangle in **normalized wall space (0..1)** that hosts one content module. Slots may overlap; they reflow to pixels on window/aspect change (`normalized_rect × render_size`).
- `MODULE_REGISTRY` currently maps two types → scenes: **`slideshow`** and **`text`** (each entry has `{name, scene, color}`). Adding a type is a **code edit** (registry + palette) — no data-driven plugin system.
- API: `add_slot`, `remove_slot`, `assign_module`, `set_slot_rect`, `apply_preset` (Full/2x1/1x2/2x2/1x3/3x1 grids), `capture_layout`/`apply_layout`, `save_layout`/`load_layout`/`delete_layout` (named layouts in `user://slot_layouts.json`), `toggle_editor` (**F2**), `monitor_cells()` (real OS screens). `MAX_SLOTS = 64`.
- **Important persistence detail:** the *live* layout is **not** persisted between sessions — each launch starts empty. Only **named layouts** are saved to disk. `commit()` is an intentional no-op stub.
- `SlotNode` wraps each module in a `SubViewportContainer`, scales it to the pixel rect, fades it in (0.35 s), and passes an `instance_id = str(slot_id)` so stateful modules (slideshow image pools) stay isolated per slot.

### Slot Layout Editor (F2)
Drag to move/resize slots (Shift = lock 16:9), preset-grid buttons, a module palette you drag-drop onto the canvas or onto a slot, named-layout save/load, monitor outlines for reference, and a selected-slot inspector (pixel size, module assign, remove). Per-slot settings are embedded panels (`slot_settings.gd` for slideshow, `text_settings.gd` for text). Note: a "double-click monitor to zoom" feature is **declared but not implemented** (`_view_origin/_view_size` are unused).

### Slideshow module (`modules/slideshow/`)
A `SubViewport` carousel. Loads images from disk (`slide_loader.gd`, persisted in `user://slides.json`), builds a pool of quad meshes/materials, and offers layout modes: **slidedeck** (6 transition types), **gallery**, **grid** (focus-zoom), **coverflow**, **carousel**. Cross-fades via `slide.gdshader`. Handles arrows/pagination/click-picking; exposes `pick_targets` for the overlay to drive input. Persisted state subset: `mode, fit, transition, transition_time, auto_run, auto_run_seconds, loop, slide_count, show_nav, show_pagination, index`.

### Text module (`modules/text/`)
A `SubViewport` text panel with five modes: **static** (BBCode via character-range spans → `RichTextLabel`), **ticker** (scrolling), **clock**, **countdown**, **cycle** (rotating items). Rich styling: font size, colors, outline, shadow, alignment, background, uppercase. `capture_state`/`apply_state` serialize Colors/Vectors to arrays. Has Godot-4.7 `RichTextLabel`/`TextEdit` quirks the author worked around (no true WYSIWYG, `shadow_outline_size`, bold-font slots). `test_spans.gd` is a standalone self-test for the span→BBCode logic.

### Agenda / Rundown (autoload "Agenda", UI on "A")
A **cue** captures a *full show state*: the active scene + a `ParamStore.capture()` snapshot + the `SlotManager.capture_layout()`. `go_to(i)` plays a cue: if the scene differs it triggers the zoom transition with the cue's own `trans` time, concurrently morphs parameters, waits for `active_changed`, then applies the slot layout. Multiple named agendas persist to `user://agendas.json` (params encoded via `BgCore.encode_snapshot`). This is a higher-level sibling of the Sequencer — Sequencer chains *background presets*, Agenda chains *whole-show cues including overlays*.

---

## 12.5 The launcher / boot gate (Launcher)

`launcher.gd` is an **autoload at CanvasLayer 200** (above every runtime UI). It is a **native Godot port of `launcher_v10_3.html`** — a full-screen, opaque boot gate that sits on top of the already-running background stage until the operator starts playout. UI is built **procedurally** (same idiom as `runtime_ui.gd`; no `.tscn`), using design tokens copied from the HTML `:root` (yellow `#FFCD00`, dark grays, green/orange/red status colors).

**Layout** (three columns inside a centered 1180-px shell, plus a bottom mock dev bar):
- **Left — System:** status header + stat rows (Lizenz / Runtime / Netzwerk / Speicher / Update-Dienst), version footer. **Visual mock.**
- **Middle — Freigabe:** the **PIN gate** (4 cells + 3×4 keypad), then after unlock the **connect stage** (Remote/Manager segment, QR box, device line, **Playout starten** + **Sperren**).
- **Right — Session:** session state tags + the **session picker**.

**What is real vs. mock (v1):**
- **PIN gate — REAL.** Hard-coded `CORRECT_PIN = "2468"`. Keypad *and* number-row/keypad digits work; wrong PIN shakes and clears.
- **Session picker — REAL.** Populated from `Agenda.list_agendas()`. A "session" *is* a named agenda. If the list is empty it shows a notice and playout just starts the default runtime.
- **Playout start — REAL.** `_on_start()` does: `Agenda.load_agenda(sel)` + `go_to(0)` (if the agenda has cues) → `DisplaySetup.start_playout()` (apply span/preview/window) → hide the overlay so the live runtime shows.
- **Update notice / License toggle / Remote-Manager QR — VISUAL MOCK.** Driven by the bottom dev bar (Touch toggle, Update-Hinweis, Lizenz, Gerät verbinden). The QR is a white placeholder panel (Godot has no offline QR generator; the HTML used an external API).

**Keys & flow:** boot → windowed launcher → PIN **2468** → pick session → **Playout starten** → runtime live (span/auto mode). **Sperren** or **Esc** re-locks to the PIN gate; **F12** re-opens the launcher from the running runtime (`show_locked()` → `DisplaySetup.enter_launcher()` back to a framed window).

**Caveats / known limits:**
- **Hotkey blocking is best-effort.** While the launcher is up, `_input` swallows PIN digits reliably; Tab/F1/F2/A are swallowed too, but that depends on `_input` ordering — harmless if it slips (toggles panels hidden behind the opaque overlay).
- The HTML's **non-touch "pregate"** (phone-scans-QR-then-enters-PIN) is folded into the touch PIN stage for v1; `_is_touch` exists but the separate pregate screen is not built.
- Verified by `--check-only` parse only; a full **F5 in Godot 4.7** is still needed to confirm layout/visuals (only 4.5.1 was available on the dev machine when this was written).

---

## 13. Runtime control panel (RuntimeUI)

`runtime_ui.gd` (~1457 LOC) is a **CanvasLayer at 100**, toggled with **Tab**, draggable by its title bar. It is the *view* over ParamStore — it never stores parameter state itself.

- On each `active_changed` it **auto-builds** controls in three passes: (1) the scene root's `@export` vars grouped by `@export_group`; (2) every `ShaderMaterial` uniform (skipping names that match an `@export` and skipping `_`-prefixed groups); (3) fixed POST controls.
- Type dispatch: float/int → slider (double-click label resets); the special int `shape` → a 5-button picker (Dot/Ring/Square/Star/Cross); Vector2/3 → linked axis sliders; Color / Vector3-with-color-hint → color picker; bool → checkbox.
- **Persistent (built once) sections:** `STAGE` (grid/screen/display-mode/scene-selector buttons/blackout/HDR toggle), `BACKGROUND STYLE` (8 palette swatches + style preset save/load/del), `PRESET` (scene preset save/load/del), `SEQUENCE` (playlist builder + transport + JSON import/export). Collapsed-state and panel position persist across scene switches.
- `POST` section: glow (intensity/strength/bloom/hdr_threshold), vignette, grain, render-resolution buttons (½/¾/1×), a 7-mode AA selector (None/FXAA/2×/4×/8×/TAA/TAA+2×), and a dither (deband) slider.
- Section/group labels for the backgrounds are **German** (e.g. *Welt & Flug*, *Material*, *Kamera*, *Darstellung*, *Tiefe & Fog*); structural labels (STAGE/PRESET/POST…) are English.
- Graceful degradation: any missing autoload is `get_node_or_null`-guarded and its section is simply skipped — which also means failures are silent.

---

## 14. Performance HUD (PerfMonitor, F1)

`perf_monitor.gd` — CanvasLayer 102, toggled **F1**, draggable, mouse-wheel font scaling (7–24 pt).

- **Frame stats** from a 120-sample ring buffer: fps, min/avg/cur/max frame time, stddev, plus an ASCII bar-graph.
- **Godot internals** via the `Performance` singleton: draw calls, primitives, objects, VRAM/texture/buffer/static memory, node/orphan/resource counts, process/physics/audio latency, viewport size.
- **Hardware** polled on a **background thread** every 2 s (mutex-guarded): GPU via `nvidia-smi` (util/mem/temp/clock/power/VRAM), CPU+RAM via **PowerShell WMI**.
  - The WMI call uses `-EncodedCommand` (Base64 UTF-16LE) to dodge Godot's `OS.execute` arg-mangling, and sets `$ProgressPreference='SilentlyContinue'` to suppress CLIXML noise — a hard-won fix; keep it.
  - Fallbacks: `nvidia-smi` fail → WMI baseline; WMI fail → `OS.get_processor_name()` + `OS.get_memory_info()` (always works). Missing metrics render as `N/A`.
- **Windows-only** for the hardware section; on other OSes it degrades to fps + Godot internals + RAM baseline.

---

## 15. Persistence: where state lives on disk

All under the Godot user dir (Windows: `%APPDATA%/Godot/app_userdata/UNIQVUE2-Backgrounds-Godot-Test/`):

| File | Written by | Contents |
|---|---|---|
| `user://presets/<name>.json` | BgCore | Scene + shader + post/overlay snapshot (no palette) |
| `user://style_presets/<name>.json` | BgCore | 8-color palette only |
| `user://sequence.json` | Sequencer | Playlist steps |
| `user://slot_layouts.json` | SlotManager | Named slot layouts |
| `user://agendas.json` | Agenda | Show cues (scene + params + slots) |
| `user://slides.json` (+ per-slot variants) | SlideLoader | Slideshow image path lists |
| `user://display_config.cfg` | DisplaySetup | Grid, screen size, last mode |

The **live** slot layout and live parameter tweaks are *not* auto-persisted; capture them as a preset / named layout / agenda cue.

---

## 16. Input & UI quick reference

| Key / action | Effect |
|---|---|
| **Launcher (boot)** | PIN **2468** → pick session → **Playout starten** to enter the runtime |
| **F12** | Re-open the launcher (re-lock) from the running runtime |
| **Esc** (in launcher) | Re-lock to the PIN gate |
| Digits / keypad / Backspace | PIN entry while the launcher is up |
| **Tab** | Toggle the RuntimeUI control panel |
| **F1** | Toggle the performance HUD |
| **F2** | Toggle the slot layout editor |
| **A** | Toggle the Agenda cue panel |
| **Esc** | Close the layout editor / agenda panel |
| Drag a panel title bar | Move it (clamped to viewport) |
| Double-click a slider label | Reset that value to default |
| TRANSITION button / scene buttons | Switch background (zoom transition) |
| `--span` / `--windowed` CLI | Set the **playout-target** display mode (launcher stays windowed) |

---

## 17. Performance: what was optimized, what's deferred

Already applied in code (verified):
- **Cubic** instance transforms uploaded in one `multimesh_set_buffer` call/frame (was 6000 per-instance calls).
- **Tunnel** particle meshes use persistent buffers + single `add_surface_from_arrays` (was per-vertex `ImmediateMesh` rebuild).
- Four `textures/*.png` imported as **BPTC + mipmaps** (was uncompressed).
- F1 hardware metrics fixed (the PowerShell encoding workaround).

Known *not-yet-done* / deferred (need runtime profiling to justify):
- **Structure** still uses ~270 per-instance `set_instance_transform()` calls/frame — port it to the buffer pattern.
- **Master-composite bypass at idle** — when only one layer is visible the glow+composite pass still runs every frame (~40–60% of idle GPU by estimate). Could be skipped when `_busy == false`.
- **Render-target memory** — three FP16 viewports held at native res always (~50 MB @1080p, up to ~600 MB at a 3×4K wall). Consider internal render-scale or freeing the idle layer.

---

## 18. Known issues, incomplete work & tech debt

**From `push_warning` / `push_error` / debug prints in code:**
- `sequencer.gd` — warns and drops unknown playlist step keys (so a hand-edited `sequence.json` with extra fields silently loses them).
- `slot_node.gd` — warns on unknown module type / failed scene load (slot just stays hidden).
- `slot_manager.gd` — warns if `slot_layout_editor.tscn` is missing (editor disabled, app continues).
- `structure_sim.gd` — `push_error` if `structure_geo.json` is missing/corrupt, then continues with **empty geometry → blank structure layer, no on-screen error**.
- `grid_builder.gd` — `print()`s point/segment counts on every density rebuild (informational; consider gating behind a debug flag).

**Stubs / unfinished:**
- `SlotManager.commit()` — intentional no-op (live layout not persisted).
- Slot editor **monitor-zoom** ("double-click to zoom") — declared, not implemented.
- `test_spans.gd` — a standalone SceneTree test that calls `quit()`; must **not** be wired into shipped builds.
- **Launcher (§12.5)** — v1: Update/License/Remote-QR are visual mock, the non-touch QR "pregate" screen is unbuilt (`_is_touch` exists, the screen does not), and hotkey blocking while the launcher is up is best-effort. PIN is hard-coded `2468`. Not yet F5-verified in Godot 4.7.

**Cross-platform / platform-coupling:**
- Export enables **only S3TC/BPTC** (`etc2_astc = false`) → textures would be **black on non-Windows** unless you add fallback formats.
- F1 hardware HUD is Windows-only (nvidia-smi/WMI); CPU temperature is best-effort and often `N/A` on AMD/Intel.

**Robustness / debt:**
- **Silent failures everywhere** — `get_node_or_null` + skip. Great for resilience, harder to debug. Consider a debug log channel.
- **`_find_camera` returns the first `Camera3D`** depth-first — a stray second camera in a scene would be picked wrongly.
- **`_scene_cache` grows unbounded** across many scene visits (no pruning).
- **Aspect-scaling logic is duplicated** across `structure_sim`, `plexus_sim`, `smoothwave_root`, `grid_builder` — extract a helper.
- **Speed conventions differ per scene** (`×1`, `×28`, `×100`) — hard to sync.
- **`tunnel_sim` `custom_aabb` is not recomputed on aspect change** — on ultrawide, new particles can spawn outside the culling box and disappear.
- Some shaders (`quantum`, `stripes`) still use `fract(sin())` hashing that can band on weaker GPUs; `lines.gdshader` already moved to an integer hash — port that.
- Lots of **magic numbers** ported verbatim from the web version with little explanation.

> The repo also contains `FIXPLAN.md` and `PERFORMANCE_AUDIT.md`. Several P0/P1 items they list (sequencer key validation, `_ensure_scene` timeout guard, `_busy` fallback timer, perf_monitor div-by-zero guard) **are already fixed in the current code** — those docs are partly stale, which is exactly why this handover was generated from the code.

---

## 19. Roadmap / what it *should* do next

Inferred from the code's direction, the deferred items, and the older planning notes (treat as suggestions, confirm with the product owner):

1. **Finish the module system polish** — data-driven `MODULE_REGISTRY` (so new module types don't need code edits), implement the editor monitor-zoom, and persist (or explicitly choose not to persist) the live slot layout.
2. **Profile and land the deferred GPU work** — master-composite idle bypass and render-target scaling for big walls (this is the biggest remaining perf lever).
3. **Migrate `structure_sim` to batched MultiMesh uploads** for parity with `cubic_sim`.
4. **Cross-platform export** if ever needed — add ETC2/ASTC fallbacks and a non-Windows HUD path.
5. **Hardening for long-running installs** — wrap unbounded float accumulators with `fmod`, prune `_scene_cache`, unify the integer-hash in shaders to stop banding over hours of runtime.
6. **Broadcast integration** — NDI/Spout output is explicitly out of scope today; the wall is fed via an embedded `TextureRect`. A real mixer feed would be a natural next step.

---

## 20. Verification checklist for the new owner

Run these to confirm your mental model matches reality (several came out of the analysis as "claims worth checking"):

- [ ] Open in Godot 4.7, press **F5** → Tunnel renders with the panel available; **F1** shows real CPU/RAM/GPU (not all `N/A`).
- [ ] Cycle all 9 scenes via the scene buttons; confirm smooth zoom transitions with no white flash and no mid-fade darkening.
- [ ] Move a slider, save a **preset**, switch scene, switch back, **load** the preset → values restore; loading a preset from a *different* scene doesn't crash (keys are skipped).
- [ ] Build a 3-step **Sequencer** playlist mixing same-scene and cross-scene steps → same-scene morphs, cross-scene zoom-transitions; PLAY loops cleanly.
- [ ] **F2** editor: drop a slideshow + a text slot, resize/drag them, save a named layout, `clear`, load it back.
- [ ] Two slideshow slots with different images stay **isolated** (per-slot `instance_id`).
- [ ] Text module: bold/italic/size/color spans render; **clock** ticks every second; **countdown** counts to target.
- [ ] **A** panel: capture a cue with a 2×2 layout, change live to 1×1, capture another, jump back → first layout + params restore.
- [ ] Resize the window mid-transition → no crash/stutter; viewports adapt.
- [ ] Multi-monitor: **SPAN** across 2+ screens fills the union with no gaps; **PREVIEW** shows one window per cell.
- [ ] Confirm whether the **live slot layout is empty on relaunch** (expected: yes — only named layouts persist).
- [ ] Push `particle_wave` density toward max → confirm FPS stays acceptable on the target wall hardware.

---

## 21. Conventions & gotchas for maintainers

- **Add a new background:** create `<name>.tscn` (root `Node3D` + `Camera3D` + `WorldEnvironment` with `gradient_sky` + geometry), write `<name>_root.gd`/`_sim.gd` exposing `@export`s and reading `elem_a/elem_b/fog_color`, then **append the path to `SCENES` and a label to `SCENE_LABELS` in `background_stage.gd`** (their lengths are asserted equal). The UI, ParamStore, and preset system pick it up automatically.
- **Hide a uniform from the panel:** put it in a `group_uniforms _Sync` (or `_Live`) block, *or* give the scene root an `@export` of the exact same name.
- **Stable preset keys depend on the scene root node's name** — renaming a `.tscn` root breaks existing presets (no migration path).
- **Delta-clamp every accumulator** (`minf(delta, 0.05)`) so a frame hitch doesn't pop the animation — most scenes do; match that.
- **Per-frame geometry** must use the persistent-buffer + single-upload pattern (see `cubic_sim`/`plexus_sim`), never per-instance/per-vertex calls.
- **`VIEWPORT_SIZE` is invalid in spatial vertex shaders** — feed aspect from GDScript as a uniform (as `lines.gdshader` does).
- **Editing this project from outside Godot:** the user instruction here is to avoid creating stray `.md`/`.txt` files in the tree; this handover is the intended exception.
- The user's standing preferences in this workspace: **don't run git commands** (describe them instead), and keep commit messages to a single short subject line.

---

## 22. Glossary

| Term | Meaning |
|---|---|
| **Autoload** | Godot global singleton (declared in `project.godot`), persists across scenes. This project has 11. |
| **Layer / slot viewport** | One of the two `_vps` SubViewports holding a background scene in its own `World3D`. |
| **Master composite** | The HDR-2D `_master` viewport where the two layers blend additively and glow is applied. |
| **Present / overlay pass** | The final on-screen `_final` rect: ACES tonemap + vignette + grain + dither. |
| **Zoom transition** | The default scene change: symmetric zoom (1↔2) + complementary fades, additive (no luminance dip). |
| **Preset** | A saved `ParamStore` snapshot for one scene (`user://presets`). |
| **Style preset** | A saved 8-color palette (`user://style_presets`). |
| **Sequencer step** | `{preset, hold, trans, mode}` in the playlist. |
| **Agenda cue** | A whole-show snapshot: scene + params + slot layout. |
| **Slot** | A normalized (0..1) rectangle on the wall hosting one content module. |
| **Module** | A content scene placed in a slot: slideshow or text (registered in `MODULE_REGISTRY`). |
| **SPAN / PREVIEW / WINDOWED** | Display modes (borderless multi-monitor / per-cell dev windows / framed window). |
| **Launcher** | Boot gate overlay (CanvasLayer 200): PIN → session → Playout. Boots windowed; applies the playout-target display mode on start. |
| **Playout-target mode** | The live-output display mode (`_playout_mode`) resolved at boot but applied only when **Playout starten** is pressed — keeps the launcher windowed. |
| **`_Sync` / `_Live`** | Shader uniform group prefixes that hide script-driven uniforms from the panel. |
| **`elem_a` / `elem_b` / `fog_color` / `sky_*`** | Global shader color uniforms driven by `Style`. |
| **`width_factor()`** | `aspect / (16:9)`; backgrounds scale their X extent by this for ultrawide walls. |
| **HDR-2D** | FP16 SubViewport render target (bloom can exceed 1.0 without clamping). |
| **S0–S4** | The author's layer labels: Style, (Stage), ParamStore, BgCore presets, Sequencer. |

---

*Generated from a full code read of `UNIQVUE2-Backgrounds-Godot-Test`. If anything here surprises you, the code wins — start at `background_stage.gd` (engine), `param_store.gd` (state), and `project.godot` (wiring).*
