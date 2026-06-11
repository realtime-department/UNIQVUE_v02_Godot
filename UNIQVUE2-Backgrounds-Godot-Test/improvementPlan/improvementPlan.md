# UNIQVUE2 Backgrounds — Improvement Plan

_Godot 4.6.1 · Forward+ · broadcast background-visuals tool_

This plan proposes improvements across the whole project, ordered by impact. The
goal is to take a solid technical demo and make it a **deployable, unattended
broadcast tool** — without disturbing the parts that already work well (the
SubViewport zoom-crossfade engine, the auto-introspecting control panel, and the
multi-wall span/preview system).

> **Constraint:** No git commands will be executed. After each milestone, a
> ready-to-run commit message is provided for you to run yourself.

---

## Current state (as built)

**Autoloads** (order matters): `DisplaySetup` → `BackgroundStage` → `RuntimeUI`.

- **`background_stage.gd`** — Dual-slot engine. Each background renders into its
  own off-screen `SubViewport` (own `World3D`, camera, `WorldEnvironment`).
  Displayed via two full-screen `TextureRect`s driven by a zoom/fade
  `canvas_item` shader. Transition = symmetric additive zoom-crossfade
  (`ZOOM_SPAN = 2.0`, `blend_add`), warm-up frame, early viewport-sleep at 90%.
  Scenes are a hardcoded `SCENES` array. `transition_to(idx)` already exists but
  has no UI driving it.
- **`runtime_ui.gd`** — One global panel (autoload). Auto-discovers controls from
  (1) scene-root `@export` vars + groups, (2) all `ShaderMaterial` uniforms with
  hint ranges, (3) fixed `WorldEnvironment` POST params. TAB toggles, title bar
  drags. Hosts the STAGE display-config section.
- **`display_setup.gd`** — Virtual grid (cols × rows × per-screen px). WINDOW /
  SPAN (borderless union of all screens) / PREVIEW (one OS window per virtual
  screen, sliced via a `canvas_item` shader to simulate bezels).
- **Scenes** — `tunnel_wave` (CPU `ImmediateMesh` light-streaks) and
  `particle_wave` (GPU vertex-shader dot-grid).

**Gaps for broadcast use:** nothing persists across restarts; no unattended
auto-cycling; live tweaks are lost on exit; you can only blindly cycle to the
"next" scene; preview shows only the active layer mid-transition.

---

## Tier 1 — Broadcast essentials (highest value)

### 1.1 Config persistence (`user://config.cfg`)
Persist and restore on launch: display grid (`cols`, `rows`, `screen_w`,
`screen_h`), `transition_time`, last active scene index, and window mode.
- New small helper (e.g. `config_store.gd` or methods on `DisplaySetup`) using
  `ConfigFile`.
- Save on change (debounced) and on quit (`NOTIFICATION_WM_CLOSE_REQUEST`).
- Load in `_ready()` **before** the first scene is shown.
- **Why:** today every value resets each launch — unworkable for a fixed install.

### 1.2 Auto-cycle / playlist mode
Optional unattended looping: crossfade to the next scene every _N_ seconds.
- Add to `BackgroundStage`: `autocycle_enabled: bool`, `dwell_time: float`, an
  internal `Timer` that calls `transition()` and is paused while `_busy`.
- UI: a checkbox + "dwell (s)" SpinBox in the STAGE section.
- **Why:** the core broadcast use-case (set it and leave it) is currently absent.

### 1.3 Preset save / recall
Capture all live control values per scene to named presets on disk; recall
instantly.
- Serialize the current scene's `@export` vars + shader uniforms + POST params to
  `user://presets/<scene>/<name>.cfg`.
- UI: a preset name field, SAVE, and a recall dropdown that re-applies values and
  refreshes the panel.
- **Why:** "Look A / Look B" recall for a show; today every tweak dies on exit.

### 1.4 Scene selector in the UI
Replace blind "next" cycling with explicit scene choice.
- UI: a row of buttons (or `OptionButton`) listing scene display names, each
  calling the existing `BackgroundStage.transition_to(idx)`.
- **Why:** the engine already supports targeted transitions; only the UI is
  missing.

---

## Tier 2 — Polish & correctness

### 2.1 Composite-correct preview
During a transition, preview windows currently show only the **active** layer's
texture, not the live crossfade composite.
- Option A (preferred): composite both layers into a single wall-resolution
  viewport/texture and slice **that** in the preview windows.
- Side benefit: fixes the main window looking distorted while preview is open
  (it currently shows the wall-aspect texture stretched into the dev window).

### 2.2 Master dim / fade-to-black
A global brightness control + instant blackout.
- Implement as a top-most full-screen black `ColorRect` on a high `CanvasLayer`
  with animatable alpha (so it works regardless of scene), plus a slider/button
  in the panel.
- **Why:** standard broadcast need — cut/dim to black between segments.

### 2.3 MSAA on the SubViewports
Points and lines alias badly on a large wall; the tunnel scene currently has no
MSAA. Set `msaa_3d` on the SubViewports (configurable / sensible default).

### 2.4 Hide cursor + clean output
Auto-hide the mouse pointer when in SPAN/PREVIEW output so the wall stays clean;
restore in WINDOW mode.

---

## Tier 3 — Housekeeping

### 3.1 Repo cleanup
- Remove the 3 stray backup files in the project root:
  `particle_wave.tscn.2026-06-11.bak`, `tunnel_sim.gd.2026-06-11.bak`,
  `tunnel_wave.tscn.2026-06-11.bak`.
- Add a `.gitignore` (none exists): ignore `.godot/`, `*.bak`, `*.tmp`,
  export artifacts.
- Add a short `README.md` (run, controls, deploy on the wall, CLI flags).

### 3.2 Deployment CLI args
Extend the existing `--span` / `--windowed`:
- `--scene=<name>` — start on a specific background.
- `--autocycle=<sec>` — launch already looping.
- `--grid=CxR` — set the virtual grid at launch.
- **Why:** the wall machine launches in the correct state with zero clicks.

### 3.3 Verify `unique_id=` in `particle_wave.tscn`
The node lines carry non-standard `unique_id=...` attributes that are not part of
standard Godot `.tscn` node syntax. Confirm whether Godot wrote these or they were
injected; clean up if they risk a load failure. (`tunnel_wave.tscn` does **not**
have them — likely the safer reference.)

---

## Ideas / future (not in scope unless requested)

- **New scenes:** 1–2 more GPU background generators (flow-field ribbons,
  audio-reactive bars) for variety. Each is a `.tscn` + shader + entry in
  `SCENES`; the auto-UI picks up their parameters with no panel code.
- **NDI / Spout output:** feed a broadcast switcher directly. Requires a
  GDExtension addon — larger effort, separate milestone.
- **Audio reactivity:** drive `amp` / `speed` / `glow_boost` from a live audio
  bus for music-synced visuals.

---

## Suggested execution order & milestones

1. **M1 — Persistence + scene selector** (1.1, 1.4): immediate quality-of-life,
   low risk, foundation for everything else.
2. **M2 — Auto-cycle + presets** (1.2, 1.3): completes the broadcast core.
3. **M3 — Polish** (2.1–2.4): visual quality and operator comfort.
4. **M4 — Housekeeping + CLI** (3.1–3.3): deploy-ready.
5. **M5 — (optional)** new scenes / advanced ideas.

Each milestone is independently shippable. Tell me which milestones to run (or
"all"), and I'll implement them in order, verifying each before moving on.

---

## Risk notes

- The transition/crossfade engine and additive-blend luminance behavior are
  carefully tuned (see `TRANSITION_CHANGES.md`) — changes will avoid altering
  `ZOOM_SPAN`, the easing, or the `blend_add` compositing.
- Cross-window `SubViewport` texture sampling (preview) can be platform-sensitive;
  2.1's single-composite approach also reduces that risk.
- All new config/preset I/O uses `user://` (never the project dir) so it survives
  exported builds on the wall machine.
