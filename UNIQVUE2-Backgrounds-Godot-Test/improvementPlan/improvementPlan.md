# UNIQVUE2 Backgrounds — Improvement Plan

_Godot 4.6.1 · Forward+ · broadcast background-visuals tool_

This plan proposes improvements across the whole project, ordered by impact. The
goal is to take a solid technical demo and make it a **deployable, unattended
broadcast tool** — without disturbing the parts that already work well (the
SubViewport zoom-crossfade engine, the auto-introspecting control panel, and the
multi-wall span/preview system).

> **Constraint:** No git commands will be executed. After each milestone, a
> ready-to-run commit message is provided for you to run yourself.

> **This revision** corrects several claims that did not match the source, splits
> one task that conflated two different rendering cases, promotes a latent
> load-risk out of housekeeping, and surfaces hidden scope in three Tier-1 items.
> Each correction is grounded in a specific file/line and flagged **[verified]**.

---

## Current state (as built)

**Autoloads** (order matters): `DisplaySetup` → `BackgroundStage` → `RuntimeUI`.

- **`background_stage.gd`** — Dual-slot engine. Each background renders into its
  own off-screen `SubViewport` (own `World3D`, camera, `WorldEnvironment`).
  Displayed via two full-screen `TextureRect`s driven by a zoom/fade
  `canvas_item` shader. Transition = symmetric additive zoom-crossfade
  (`ZOOM_SPAN = 2.0`, `blend_add`), warm-up frame, early viewport-sleep at 90%.
  **Easing [verified]:** old-layer zoom `SINE/EASE_IN`, new-layer zoom
  `SINE/EASE_OUT`, **both fades `SINE/EASE_IN_OUT`** (`background_stage.gd:199-206`).
  Because sine-in-out is symmetric, `fade_out + fade_in == 1` exactly, so the
  additive blend preserves luminance — this holds for both linear and sine fades.
  Scenes are a hardcoded `SCENES` array (paths only, no display names).
  `transition_to(idx)` already exists, guards `_busy` / out-of-range /
  re-selecting the current scene, but has no UI driving it.
- **`runtime_ui.gd`** — One global panel (autoload). Auto-discovers controls from
  (1) the **scene-root script's** `@export` vars + groups, (2) all `ShaderMaterial`
  uniforms (read from `material_override`) with hint ranges, (3) fixed
  `WorldEnvironment` POST params. TAB toggles, title bar drags. Hosts the STAGE
  display-config section. **Discovery is root-script-only [verified]:** see the
  preset note in 1.3.
- **`display_setup.gd`** — Virtual grid (cols × rows × per-screen px). WINDOW /
  SPAN (borderless union of all screens) / PREVIEW (one OS window per virtual
  screen, sliced via a `canvas_item` shader to simulate bezels).
- **Scenes** — `tunnel_wave` (CPU `ImmediateMesh` light-streaks; root carries
  `tunnel_sim.gd`) and `particle_wave` (GPU vertex-shader dot-grid;
  **root `Node3D` has no script** — the `@export`s live on the `Grid` child via
  `grid_builder.gd` `[verified]`).

**Gaps for broadcast use:** nothing persists across restarts; no unattended
auto-cycling; live tweaks are lost on exit; you can only blindly cycle to the
"next" scene; preview shows only the active layer's *raw* texture mid-transition
(no zoom, no crossfade).

---

## Tier 0 — Pre-flight de-risking (do before M1)

### 0.1 Sanitize `particle_wave.tscn` — non-standard `unique_id=` keys
**[verified]** The node headers carry numeric `unique_id=...` attributes
(`particle_wave.tscn:45,47,50,57`) that are **not valid Godot 4 `.tscn` node
syntax** — Godot never writes them. `tunnel_wave.tscn` is clean, confirming an
external tool injected them. The scene loads today only because Godot's text
parser tolerantly ignores unknown header keys; a re-save or a format migration
makes the outcome undefined. **A scene that fails to load at showtime is the
worst-case broadcast failure**, so this is fixed first, not buried in cleanup.
- Open `particle_wave.tscn` in the editor, re-save, and diff: confirm the
  `unique_id=` keys are dropped and nothing else changes.
- Verify both scenes still transition cleanly afterward.
- **Why first:** five minutes of de-risking that removes a latent load failure
  before any feature work builds on top of it.

---

## Tier 1 — Broadcast essentials (highest value)

### 1.1 Config persistence (`user://config.cfg`)
Persist and restore on launch: display grid (`cols`, `rows`, `screen_w`,
`screen_h`), `transition_time`, last active scene index, and window mode.
- New small helper (e.g. `config_store.gd` or methods on `DisplaySetup`) using
  `ConfigFile`.
- Save on change (debounced) and on quit. **Wiring note:**
  `NOTIFICATION_WM_CLOSE_REQUEST` only fires if you first call
  `get_tree().set_auto_accept_quit(false)` — otherwise the on-quit save never
  runs.
- Load in `_ready()` **before** the first scene is shown. **Wiring note
  [verified]:** `BackgroundStage._ready()` currently hardcodes
  `_scene_idx = 0; _load_into(0, SCENES[0])` (`background_stage.gd:115-118`).
  Restoring the last scene means `BackgroundStage` must read the config at
  `_ready`. `DisplaySetup` is autoload #1 (runs first), so have it own the config
  load and expose the values; `BackgroundStage` (#2) reads them at its `_ready`.
  A `--scene=` CLI flag (see 3.2) must override the persisted index.
- **Why:** today every value resets each launch — unworkable for a fixed install.

### 1.2 Auto-cycle / playlist mode
Optional unattended looping: crossfade to the next scene every _N_ seconds.
- Add to `BackgroundStage`: `autocycle_enabled: bool`, `dwell_time: float`, an
  internal `Timer` that calls `transition()`. The existing `_busy` guard already
  drops a tick that lands mid-transition safely.
- **Reset the dwell timer on any manual transition** (TRANSITION button or scene
  selector), or a manual change will be followed by an unwanted auto-transition
  moments later.
- UI: a checkbox + "dwell (s)" SpinBox in the STAGE section.
- **Why:** the core broadcast use-case (set it and leave it) is currently absent.

### 1.3 Preset save / recall
Capture live control values per scene to named presets on disk; recall instantly.
- Serialize to `user://presets/<scene>/<name>.cfg`: the scene's root-script
  `@export` vars + all `ShaderMaterial` uniforms + POST params.
- **Scope caveat [verified]:** the panel only discovers `@export`s on the
  **scene root's** script (`runtime_ui.gd:178-179`). For `particle_wave` the
  root has no script — its tuning lives in shader uniforms, while
  `grid_builder.gd`'s `@export`s (`grid_w`, `grid_h`, `span_x`, `span_z`) sit on
  the `Grid` **child** and are both panel-invisible **and** build-time only
  (consumed once in `_build_grid()`). Decide explicitly:
  - **Recommended:** presets capture only panel-visible runtime values (shader
    uniforms + root `@export`s + POST). This matches what the operator can
    actually tweak live and keeps recall instant.
  - If grid params must be presettable, the recall path needs a mesh rebuild
    hook — larger scope; defer unless requested.
- UI: a preset name field, SAVE, and a recall dropdown that re-applies values and
  refreshes the panel.
- **Why:** "Look A / Look B" recall for a show; today every tweak dies on exit.

### 1.4 Scene selector in the UI
Replace blind "next" cycling with explicit scene choice.
- **Prerequisite [verified]:** `SCENES` holds paths only
  (`background_stage.gd:28-31`); the only human-readable name is the instanced
  root's `.name`, unavailable without loading. Add a parallel display-name table
  (e.g. `SCENE_LABELS` array or a `{path, label}` list) so the selector can label
  buttons without instancing every scene.
- UI: a row of buttons (or `OptionButton`) listing those names, each calling the
  existing `BackgroundStage.transition_to(idx)`. Clicking the active scene already
  no-ops safely.
- **Why:** the engine already supports targeted transitions; only the UI (and a
  name table) is missing.

---

## Tier 2 — Polish & correctness

### 2.1 Composite-correct preview
**[verified]** During a transition, preview windows sample
`BackgroundStage.active_texture()`, which returns the **raw active SubViewport
texture** (`display_setup.gd:131`, `background_stage.gd:132-133`) — i.e. *before*
the zoom/fade shader. So the preview shows neither the zoom nor the crossfade,
only the active layer's untransformed image.
- Option A (preferred): render both layers' shaded `TextureRect`s into a single
  wall-resolution compositing `SubViewport`, and slice **that** in the preview
  windows. Note this is a real refactor — today the zoom/fade compositing happens
  in screen-space on the `CanvasLayer`, not in a viewport, so a dedicated
  composite viewport must be introduced.
- Side benefit: fixes the main window looking distorted while preview is open
  (it currently shows the wall-aspect texture stretched into the dev window).
- Reduces the cross-window `SubViewport` sampling risk (one shared texture).

### 2.2 Master dim / fade-to-black
A global brightness control + instant blackout.
- Implement as a full-screen black `ColorRect` on its **own `CanvasLayer` between
  the stage and the UI** — `layer ≈ 50` (stage is `layer = 0`, UI is
  `layer = 100` `[verified]`). A top-most layer would also black out the
  operator's control panel; the dim must hide the **wall**, not the controls.
- Animatable alpha (works regardless of scene) + a slider/button in the panel.
- **Why:** standard broadcast need — cut/dim to black between segments.

### 2.3 Anti-aliasing — per-scene, not one knob
**[verified]** The two scenes alias for different reasons and need different
fixes. MSAA resolves polygon/line edges but does **not** meaningfully
antialias point sprites.
- **`tunnel_wave`** (`ImmediateMesh` line-streaks): set `msaa_3d` on its
  SubViewport — this is where MSAA actually helps.
- **`particle_wave`** (`Mesh.PRIMITIVE_POINTS`, `grid_builder.gd:44`): MSAA buys
  almost nothing on point primitives while costing ~4× SubViewport bandwidth.
  Instead, make the points soft/round in the **fragment shader** (`smoothstep`
  alpha falloff on `POINT_COORD`).
- Expose MSAA level as configurable with a sensible default; keep it off the
  particle viewport.

### 2.4 Hide cursor + clean output
Auto-hide the mouse pointer when in SPAN/PREVIEW output so the wall stays clean
(`Input.mouse_mode = MOUSE_MODE_HIDDEN`); restore in WINDOW mode. In PREVIEW
(multiple OS windows) confirm the hide applies as intended.

---

## Tier 3 — Housekeeping & deployment

### 3.1 Repo cleanup
- Remove the 3 stray backup files in the project root:
  `particle_wave.tscn.2026-06-11.bak`, `tunnel_sim.gd.2026-06-11.bak`,
  `tunnel_wave.tscn.2026-06-11.bak`.
- Add a `.gitignore` (none exists): ignore `.godot/`, `*.bak`, `*.tmp`, export
  artifacts. **Do not ignore `*.uid`** — in Godot 4.4+ these are meant to be
  version-controlled.
- Add a short `README.md` (run, controls, deploy on the wall, CLI flags).

### 3.2 Deployment CLI args
Extend the existing `--span` / `--windowed` (parsed in `display_setup.gd:42` via
`OS.get_cmdline_user_args()`):
- `--scene=<name>` — start on a specific background (overrides persisted index).
- `--autocycle=<sec>` — launch already looping.
- `--grid=CxR` — set the virtual grid at launch.
- Consider parsing all flags in one place (`DisplaySetup`, the first autoload)
  and exposing them, rather than each autoload re-reading the command line.
- **Why:** the wall machine launches in the correct state with zero clicks.

### 3.3 Sync `TRANSITION_CHANGES.md` with the code
**[verified]** `TRANSITION_CHANGES.md` claims "Both fades kept `TRANS_LINEAR`",
but the code uses `SINE/EASE_IN_OUT` on both fades (`background_stage.gd:201-206`).
The Risk notes below treat that doc as the tuning contract, so it must match
reality first. Update the doc; the luminance behavior is unchanged (sine-in-out is
symmetric, so `fade_out + fade_in == 1` still holds).

---

## Ideas / future (not in scope unless requested)

- **New scenes:** 1–2 more GPU background generators (flow-field ribbons,
  audio-reactive bars) for variety. Each is a `.tscn` + shader + entry in
  `SCENES` (and the new label table from 1.4); the auto-UI picks up their
  shader/root-script parameters with no panel code.
- **NDI / Spout output:** feed a broadcast switcher directly. Requires a
  GDExtension addon — larger effort, separate milestone.
- **Audio reactivity:** drive `amp` / `speed` / `glow_boost` from a live audio
  bus for music-synced visuals.

---

## Suggested execution order & milestones

0. **M0 — Pre-flight** (0.1, 3.3): sanitize `particle_wave.tscn`, fix the stale
   transition doc. Minutes of work, removes a load risk and a misleading contract.
1. **M1 — Persistence + scene selector** (1.1, 1.4): immediate quality-of-life,
   low risk, foundation for everything else.
2. **M2 — Auto-cycle + presets** (1.2, 1.3): completes the broadcast core.
3. **M3 — Polish** (2.1–2.4): visual quality and operator comfort.
4. **M4 — Housekeeping + CLI** (3.1, 3.2): deploy-ready.
5. **M5 — (optional)** new scenes / advanced ideas.

Each milestone is independently shippable. Tell me which milestones to run (or
"all"), and I'll implement them in order, verifying each before moving on.

---

## Risk notes

- The transition/crossfade engine and additive-blend luminance behavior are
  carefully tuned — changes will avoid altering `ZOOM_SPAN`, the easing curves,
  or the `blend_add` compositing. **Reference the code, not `TRANSITION_CHANGES.md`,
  until M0 reconciles the two** (the doc currently misstates the fade easing as
  linear; the code is sine-in-out).
- Cross-window `SubViewport` texture sampling (preview) can be platform-sensitive;
  2.1's single-composite approach also reduces that risk.
- All new config/preset I/O uses `user://` (never the project dir) so it survives
  exported builds on the wall machine.
- Preset serialization captures only panel-visible runtime values by default
  (see 1.3) — build-time grid params are intentionally out of scope unless a
  rebuild path is added.
