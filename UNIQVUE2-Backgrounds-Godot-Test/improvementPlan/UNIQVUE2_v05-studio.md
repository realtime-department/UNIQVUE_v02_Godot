# UNIQVUE2 v05 — Studio Parity for the Godot Project

**Source:** `T:\Godot_BGs\studio-v005.html` (Three.js, single file, 2107 lines)
**Goal:** Port the missing logic & features of the web studio into the Godot project
(`UNIQVUE2-Backgrounds-Godot-Test`) — adapted to Godot's strengths,
not a 1:1 rebuild of the RT pipeline.

**Status:** S0–S5 implemented (see §4 / §8). S6 (content, 5 remaining modules) open.

All claims below are verified against the source code; web references as
`studio-v005.html:line`, Godot references as `file.gd:line`.

---

## 1. What the Web Studio Is (Architecture)

A self-contained module system with a central color/post/sequencer layer. The
self-description is at `studio-v005.html:147-158`:

> Each setup is a self-contained module with its own Scene+Camera.
> Interface: `{ id, name, schema, build(), update(dt,p), render(rt), dispose() }`

### 1.1 Seven Modules (Registry `studio-v005.html:1564-1573`)

| id | Name | Technique | Godot equivalent? |
|----|------|-----------|-------------------|
| `tunnel` | Tunnel / Streaks | LineSegments + Points heads, additive | ✅ `tunnel_wave.tscn` |
| `wave` | Particle Wave | Point-grid + Wireframe + image-space reflection | ✅ `particle_wave.tscn` |
| `plexus` | Plexus | networked points/links | ❌ missing |
| `lines` | Lines | diagonal streak field (2D shader) | ❌ missing |
| `stripes` | Stripes | louvre stripe field (2D shader) | ❌ missing |
| `cubic` | Cubic | instanced cube tunnel | ❌ missing |
| `structure` | Structure | architecture fly-through with lightmaps/textures | ❌ missing |

Each module provides a `schema` (`studio-v005.html:394-417` for tunnel) — groups
of items with `{k,label,min,max,step,dec}`, plus special types `dial:true`
(angle wheel), `toggle:true` (on/off) and `shape:'shape'` (shape picker Dot/Ring/
Square/Star/Cross, `studio-v005.html:1721`).

### 1.2 Central STYLE Color System (`studio-v005.html:230-260`)

**Global, shared across all backgrounds.** One palette applies to ALL modules:

- 5-stop vertical gradient: `zenith, skyMid, horizon, groundMid, ground`
- `fog` (depth fog) + 2 element tints `elemA` (valley/far/base), `elemB` (crest/near/highlight)

A `gradientPass` (`studio-v005.html:245-260`) renders the 5-stop gradient as
background BEFORE the module; modules draw additively on top and take their
colors from STYLE instead of local c1/c2/c3 (e.g. `studio-v005.html:356`,
`studio-v005.html:501`: `U.uC1.value.copy(_SC.fog)` etc.).

### 1.3 Global Post Pipeline (`studio-v005.html:205-275`, Loop `2090-2099`)

Over the **composited** image:
`bright (Threshold) → 2× separable Gauss-blur (4 passes, two radii) →
tonemap (ACES + Grain + Vignette)`. Controlled via `GLOBAL = {bloom, thresh,
vignette, grain}` (`studio-v005.html:220`).

### 1.4 Transition Pass (`studio-v005.html:179-203`)

Combines rtA+rtB. Two modes:
- `uMode 0` = Crossfade
- `uMode 1` = Z-Push (B grows from depth, radial front + bright edge)

### 1.5 State/Sequencer System "BgCore" (`studio-v005.html:1575-1693`)

The core piece that is completely missing in Godot:

- **One Root State** holds full values across **3 zones**: `gradient` (STYLE), `module`
  (`{moduleId, params}`), `post` (GLOBAL).
- **`states[]`** are **Deltas** (patches) against Root. If a zone is missing from the patch →
  inherits Root. Root changes propagate to all inheriting states (central control,
  `studio-v005.html:1586-1589`).
- Operations: `resolve(root,state)`, `diff(root,full)`, `interpolate(A,B,t)`,
  `summarize` (`studio-v005.html:1614-1692`).
- **Playback** (`studio-v005.html:2051-2071`): hold timer per state → auto-advance →
  `interpolate` across all 3 zones. Same module → param lerp (live morph,
  `studio-v005.html:2065-2068`). Different module → Z-push/crossfade via the
  transition pass (`studio-v005.html:2078-2088`).
- Per state: `hold`, `transition` (zpush/cross), `dur`. Drag-reorder
  (`studio-v005.html:1962-1966`). Export/Import JSON (`studio-v005.html:2026-2027`).

### 1.6 Schema-Driven UI

Param panel, post panel, style panel, setup selector and sequencer are built
dynamically from `schema` + STYLE + GLOBAL (`studio-v005.html:1748-1853`).

---

## 2. What the Godot Project Has Today (after S0)

| Area | Status | Reference |
|------|--------|-----------|
| Autoloads | `Style → DisplaySetup → BackgroundStage → RuntimeUI` | `project.godot:19-24` |
| Scenes | exactly 2, hardcoded, cyclic switch | `background_stage.gd:28-31` |
| Transition | ONE type: symmetric zoom + additive complementary fade | `background_stage.gd:198-206` |
| **Colors** | ✅ **central STYLE palette (8 colors) via global shader uniforms; gradient sky per scene** | `style.gd`, `gradient_sky.gdshader` |
| Post | only per-scene `WorldEnvironment` Glow + Adjustments, no global composite post | `runtime_ui.gd:23-30` |
| UI | auto-introspective (Root `@export` + shader uniforms + fixed POST params) + STYLE picker | `runtime_ui.gd:170-193`, `_build_style_config` |
| States/Presets/Sequencer | **nothing** | — |

What Godot does **better** and must be kept:
- Real 3D scenes with their own camera/world/environment per SubViewport — no
  render-to-RT hacks.
- The zoom transition (`background_stage.gd:198-214`) is higher quality than the
  JS Z-push and is effectively already the "zpush" mode.
- The auto-introspective UI (`runtime_ui.gd`) provides the schema for free from
  `@export`/uniforms — we barely need manual schemas.

---

## 3. Gap Analysis: What Is Missing and the Idiomatic Godot Approach

### G1 — Central Palette + Gradient Background (STYLE) ✅ DONE (S0)

Global palette as `Style` autoload, mirrored into **global shader uniforms**
(`RenderingServer.global_shader_parameter_set`). Scene shaders read
`global uniform vec4 … : source_color`; gradient via `shader_type sky` over
`EYEDIR.y`. Details in §8.

### G2 — Global Composite Post (Bloom/Tonemap/Vignette/Grain)

**Missing:** Unified post over the composited image. Currently only per-scene Glow.

**Godot approach — decision needed (see §5, D1):**
- **Option A (recommended, clean):** Render both layer rects into a **master composite
  SubViewport** that carries its own `WorldEnvironment` (Glow = Bloom,
  Adjustments = Contrast/Saturation, Tonemap ACES) **plus** a final
  `canvas_item` post shader for Vignette + Grain. Unifies post, enables
  real bloom over the mix. Medium refactor of `background_stage.gd`.
- **Option B (faster intermediate step):** Keep per-scene Glow, just add a
  global Vignette/Grain `canvas_item` shader as CanvasLayer (~layer 50) on top.
  Bloom stays per-scene.

Connection to STYLE: the post values will later form their own "post" zone in the
state model (G4); for S1 a global `Post` data object (analogous to `Style`) is enough.

### G3 — Multiple Modules / Registry / Selector

**Missing:** Extensible registry (currently 2 hardcoded, `background_stage.gd:28-31`),
a scene **selector** (not just "next"), display name table.

**Godot approach:** Extend SCENES to a table `[{path, display_name, id}]`;
`transition_to(idx)` already exists (`background_stage.gd:160`) — only a UI
selector is missing. (Aligns with improvementPlan 1.4.)

### G4 — State/Sequencer System ★ biggest piece

**Missing:** completely. No state model, no presets, no playback, no sequencer.

**Godot approach:**
- Port `BgCore` as a `RefCounted` class: `clone/resolve/diff/interpolate/
  summarize` over Dict `{gradient, module, post}`. Direct port from
  `studio-v005.html:1592-1693` — pure data logic, easily testable.
- **Param bridge (core problem):** Web params are a flat JS dict; Godot params
  live on nodes (`@export` + shader uniforms). Solution: a snapshot/apply layer
  that bundles the getter/setter callables already enumerated in `runtime_ui.gd`
  (`runtime_ui.gd:251-252`, `286-292`) under **stable keys** (`node::uniform`
  or `prop`) into a dict. `moduleId` = scene index/path. `gradient` =
  style palette (already available as dict via `Style.get_palette()` after S0). `post`
  = global post params.
- Sequencer UI: new section in `runtime_ui.gd` (or separate autoload) — states
  list, +State, Play, Hold/Dur/Transition, Reorder, Save/Load.
- Playback engine: `_process` loop (in BackgroundStage or new `Sequencer`
  autoload): hold timer → advance → same scene = param morph via `interpolate`
  per frame; different scene = `transition_to` + gradient/post interpolate.

### G5 — Parameter Morph (same scene)

**Missing:** Currently the transition only crossfades the rendered image; params jump.

**Godot approach:** Param tweening via the apply layer from G4 — numeric lerp,
Color lerp, int rounded (corresponds to `studio-v005.html:1673-1690`).

### G6 — Transition Modes

**Missing:** Only zoom transition. No crossfade mode, no per-state choice.

**Godot approach:** Add second mode `cross` (pure fade without zoom hub); the
existing zoom = `zpush`. Per-state `transition` field selects. Low effort —
extend `transition_to` with a `mode` parameter.

### G7 — Schema Comfort (Dial / Shape / curated Labels)

**Missing (nice-to-have):** Angle wheel (`dial`), shape cluster (`shape`), explicit
labels. Godot's `@export_range`/`@export_group` already covers ranges & groups.

**Godot approach:** Custom controls in `runtime_ui.gd` (dial via `_draw`/Control,
shape via button row). Optional, deferrable.

### G8 — Missing Modules as Content Track

5 of 7 modules do not exist as Godot scenes (plexus, lines, stripes, cubic,
structure). This is **content**, not framework — separate track, module by module.
The framework (G1–G7) is module-agnostic and takes priority.

---

## 4. Milestones — Order & Status

Building on the existing `improvementPlan.md` (M0–M5). v05-studio is the
studio parity extension on top.

- **S0 — Global Palette + Gradient Background (G1).** ✅ **DONE** —
  `Style` autoload + `[shader_globals]`; tunnel/wave on global uniforms; gradient
  sky per SubViewport; STYLE picker in panel. *(Editor verification in 4.6.1 still
  pending, see §8.)*
- **S1 — Global Composite Post (G2).** Master composite stage (option A) with
  unified Bloom/Tonemap/Vignette/Grain; in panel as POST zone. *Requires D1.*
- **S2 — Param Snapshot/Apply Layer (G4 part).** ✅ `param_store.gd` (ParamStore
  autoload): flat named register over the active scene; `capture/apply/
  lerp_values`. D4 decided (see §5, §8).
- **S3 — BgCore State Model + Preset I/O to `user://` (G4 part).** ✅ `bg_core.gd`
  (BgCore autoload): named presets as JSON in `user://presets/`; diff/resolve/
  summarize for S4; PRESET section in panel (SAVE/LOAD/DEL). *Folds in improvementPlan
  1.3. Details §8.*
- **S4 — Sequencer UI + Playback (G4/G5).** ✅ `sequencer.gd` (Sequencer autoload):
  preset playlist (step = `{preset, hold, trans}`), Play/Stop/Next, Reorder,
  persistence to `user://sequence.json`; param morph (same scene, `apply_lerp`) +
  zoom transition (scene change). SEQUENCE section in panel. D3 decided (see §5).
  *Folds in improvementPlan 1.2 (auto-cycle). Full keyframe timeline = later.*
- **S5 — Transition Modes + Schema Comfort + Particle Wave Fix (G6/G7).** ✅ **DONE** —
  Crossfade mode; shape picker; per-step mode dropdown; PREV button; JSON export/import;
  wire grid; Particle Wave corrected to HTML parity (point size, fragment thresholds,
  glow formula, grid centering, camera semantics).
- **S6 (separate track) — Port remaining 5 modules (G8).** One at a time.

Order is strict: S0 delivered the global uniforms (✅), without which S1/S3 would have
no color zone; S2 delivers the param map, without which S4 cannot morph anything.

---

## 5. Decision Points

- **D1 — Composite Post:** Option A (master SubViewport, real bloom, more refactoring)
  vs. Option B (Vignette/Grain overlay, Glow stays per-scene). → Recommendation: A.
  **Open — to be decided before S1.**
- **D2 — Gradient Background:** Sky shader vs. ColorRect gradient layer.
  ✅ **Decided: Sky shader** (implemented in S0).
- **D3 — Sequencer home:** ✅ **Decided: new `Sequencer` autoload** (implemented in S4;
  after `BgCore`, before `RuntimeUI`). Separates runtime playback (clock/cursor/
  is_playing) from BgCore's file I/O; RuntimeUI only calls `play/stop/next`.
- **D4 — Param identity:** ✅ **Decided: flat named schema** (implemented in S2):
  `style/<key>`, `scene/<export>`, `mat/<Node>/<uniform>`, `post/<prop>`,
  `overlay/<prop>`. Stable across reload/scene changes; `apply()` skips
  keys that cannot be resolved in the active scene (clean scene switch).

## 6. Risks / Notes

- **Global Shader Uniforms** must be declared in `project.godot` under `[shader_globals]`
  before shaders can read them as `global uniform` — otherwise silent error.
  (Done in S0.)
- **Color space:** Globals declared as `color` + shader uniforms with
  `: source_color` → exactly ONE sRGB→linear conversion at the shader boundary. `Style`
  holds & delivers sRGB; **never pre-convert**. If 4.6.1 converts twice
  (image too dark), switch to `vec4` globals + manual `srgb_to_linear()`
  in `style.gd`.
- **Two separate World3D** (`background_stage.gd:87`): a single global post
  over the mix forces combining both rects into one target (→ D1/A).
- **Do NOT replace the existing zoom transition** — it is the `zpush` equivalent and
  higher quality than the JS Z-push; just add crossfade as a second mode alongside it.
- **Param snapshot** must only capture panel-visible runtime values (no build-
  time fields like `grid_w/grid_h` from `grid_builder.gd` that require a rebuild)
  — otherwise a slider morphs that does nothing at runtime. Aligns with the
  preset scope definition from improvementPlan 1.3.
- **`particle_wave.tscn` `unique_id=` cleanup** (improvementPlan M0/0.1) is still
  open — deliberately NOT touched in S0. Should be done before S2.
- **Do not run git** (user requirement): only describe commit commands, do not
  execute them.

---

## 7. Next Step

S0–S5 are implemented (✅ framework parity + Particle Wave fix). Next up: **S6**
(content, G8): port the remaining 5 modules one by one (plexus, lines, stripes,
cubic, structure). Optional extension: **S4.5** (full keyframe timeline — per-param tracks,
scrubber, easing as extension of the sequencer). Also worth considering: unify UI + ParamStore
enumeration into ONE register. Optional first: **M0** (`particle_wave.tscn`
`unique_id=` cleanup).

---

## 8. Implementation Log

### S0 — Global STYLE Palette + Gradient Sky *(done; editor verification in 4.6.1 pending)*

**New files**
- `style.gd` — Autoload (FIRST in order). Holds 8 sRGB colors
  (`sky_zenith/sky_mid/sky_horizon/sky_ground_mid/sky_ground/fog_color/elem_a/elem_b`),
  mirrors them via `RenderingServer.global_shader_parameter_set` into global
  uniforms, `changed` signal. API: `get_color/set_color/get_palette/set_palette/keys`.
- `gradient_sky.gdshader` — `shader_type sky`; 5-stop gradient over `EYEDIR.y`
  (`t = EYEDIR.y*0.5+0.5`), stops identical to web (`studio-v005.html:255-258`).

**Changed files**
- `project.godot` — `Style` as first `[autoload]`; new `[shader_globals]` block
  with 8 `color` globals.
- `particle_wave.gdshader` — `col_valley/col_mid/col_crest` replaced by
  `global uniform vec4 fog_color/elem_a/elem_b : source_color` (c1=Fog, c2=elemA,
  c3=elemB, as `studio-v005.html:501`).
- `tunnel_sim.gd` — `@export_group("Colors")` + 3 color exports removed; reads
  `fog_color/elem_a/elem_b` per frame from `Style` (CPU vertex colors).
- `tunnel_wave.tscn`, `particle_wave.tscn` — Environment set to `background_mode = 2`
  (Sky) with gradient sky `ShaderMaterial`; dead `shader_parameter/col_*` removed.
  Glow/Tonemap/Adjustments unchanged. `unique_id=` keys deliberately left (→ M0).
- `runtime_ui.gd` — compact **STYLE** section (`_build_style_config`, 8 color
  pickers 2-column in persistent `outer` container) → `Style.set_color`.

**Verification in Godot 4.6.1 (to be done by user)**
1. Both scenes load without errors (shaders compile, no parser errors).
2. Change STYLE picker → gradient AND element colors of both backgrounds update live.
3. Expected: Tunnel & Wave now use the same palette instead of old local colors.

**`ext_resource` without `uid=`** for `gradient_sky.gdshader` in both `.tscn` — Godot
assigns the uid on first save (avoids uid mismatch); `.uid` files for
`style.gd`/`gradient_sky.gdshader` are created by the importer.

### S1 — Global Composite Post *(done; editor verification in 4.6.1 pending)*

D1 = **Option A**. `background_stage.gd`: new master SubViewport (`use_hdr_2d`,
`own_world_3d`, `UPDATE_ALWAYS`) holds the black background + both zoom/fade layer
rects; a `WorldEnvironment` inside handles **only** Glow/Bloom (`BG_CANVAS`,
additive, `glow_hdr_threshold` 0.7). A final on-screen `TextureRect` (`_final`)
samples the HDR master texture and runs **ACES tonemap → Vignette → Grain** in a
`canvas_item` OVERLAY_SHADER (tonemap deliberately NOT in the Env, since camera-less 2D
only reliably gets the Glow). Both scene `.tscn` envs reduced to gradient sky
(`tonemap_mode = 0`, no Glow/Adjustments). New: `active_texture()` → Master,
`post_environment()`/`post_overlay()` accessors. `runtime_ui.gd` POST section points
to the master env + Vignette/Grain sliders (`_add_overlay_slider`); `POST_PARAMS` reduced to
Glow. Limitation: scene SubViewports are LDR RGBA8 → emission >1 clips at the
scene→master hop; bloom triggers over `glow_hdr_threshold`; control knobs =
`glow_hdr_threshold` / `glow_strength`.

### S2 — Param Snapshot/Apply Layer *(done; editor verification in 4.6.1 pending)*

**New file**
- `param_store.gd` — Autoload **ParamStore** (after `BackgroundStage`, before `RuntimeUI`).
  Builds a flat register `{key → {key,type,getter,setter}}` on each `active_changed`
  from the 5 sources (D4 schema): `style/<key>`, `scene/<export>`, `mat/<Node>/<uniform>`,
  `post/<prop>`, `overlay/<prop>`. API: `capture() → Dictionary`, `apply(values)`
  (skips unresolvable keys), `lerp_values(a,b,t)` + `apply_lerp` (type-appropriate:
  `lerpf` / `Color.lerp` / `Vector*.lerp` / bool@0.5), `active_scene_key()`,
  `keys()`/`has_key()`. Snapshot = plain `{key: value}`.
- **In-session persistence via TRANSITION:** `_scene_cache` (scene name → scene/*+mat/*).
  On `active_changed` the scene-specific values of the leaving scene are saved
  and reapplied on return — otherwise `background_stage` resets them to `.tscn`
  defaults on re-instantiation. (style/post/overlay survive anyway, as autoload/master.)
  Runtime-only; persistent named presets on disk = S3.

**Changed file**
- `project.godot` — `ParamStore="*res://param_store.gd"` between `BackgroundStage`
  and `RuntimeUI`.

**Note (drift risk):** The enumeration logic mirrors `runtime_ui.gd` (same
5 sources, same type heuristic). S4 should consider unifying UI + store into ONE register
rather than maintaining two parallel traversals.

**Verification in Godot 4.6.1 (to be done by user)**
1. Project loads without errors (ParamStore parses, no lambda/parser errors).
2. Smoke test in any script/console:
   `var s = ParamStore.capture()` → contains `style/sky_zenith`, `post/glow_intensity`,
   `overlay/vignette` + scene-specific `scene/*` / `mat/*` keys.
3. `ParamStore.apply(s)` after adjusting sliders → values jump back.
4. After `TRANSITION` to other scene: a previously captured snapshot via `apply()`
   sets only the shared `style/*` + `post/*` + `overlay/*`, without errors.

### S3 — BgCore State Model + Preset I/O *(done; editor verification in 4.6.1 pending)*

**New file**
- `bg_core.gd` — Autoload **BgCore** (after `ParamStore`, before `RuntimeUI`). Saves
  named presets as JSON in `user://presets/<name>.json`; document =
  `{version, scene, params}`. Values JSON-encoded: `Color → {_t:"col",v:[r,g,b,a]}`,
  `Vector2/3 → {_t:"v2"/"v3",...}`, numbers/bool native; decoded on read, `apply`
  coerces them via register types (`_coerce`). API: `save_current(name)` /
  `save_snapshot(name,snap)`, `load_preset(name)` (reads **and** applies, returns
  snapshot), `read_preset` / `read_doc`, `delete_preset`, `list_presets`, `has_preset`.
  State utilities for S4: `diff(base,other)` (sparse delta = root+delta model),
  `resolve(root,delta)`, `summarize`; interpolation provided by `ParamStore.lerp_values`.
  `presets_changed` signal. Filenames sanitized via `String.validate_filename()`.

**Changed files**
- `project.godot` — `BgCore="*res://bg_core.gd"` between `ParamStore` and `RuntimeUI`.
- `runtime_ui.gd` — persistent **PRESET** section (`_build_preset_config`, in
  `outer` container, built once): `OptionButton` dropdown of presets +
  name `LineEdit` + **SAVE/LOAD/DEL** + status label. Dropdown selection fills the
  name field; `presets_changed` → rebuild list. After **LOAD**, `_after_preset_loaded()`
  syncs the UI to the changed values: `_sync_style_swatches()`
  (swatches tracked in `_style_swatches`, `set_block_signals` on re-read → no
  feedback loop) + `_populate(root)` rebuilds scene/mat/post/overlay controls.

**Deliberate limitation (→ S4):** **LOAD** applies to the CURRENT scene; scene-specific
keys of a different scene are skipped. It does NOT automatically switch to the scene
tagged in the preset — that is handled by the sequencer (S4), which coordinates scene +
parameters. The `scene` tag is already saved for that purpose.

**Verification in Godot 4.6.1 (to be done by user)**
1. Project loads without errors (BgCore parses, `user://presets/` is created).
2. Adjust controls/colors → enter name → **SAVE**: file appears in `user://presets/`,
   dropdown lists it.
3. Set different values → select preset in dropdown → **LOAD**: values AND
   sliders/swatches jump to saved state; render updates.
4. **DEL** removes the preset from list and folder.
5. Restart app → preset still in list, **LOAD** restores it.

### S4 — Sequencer UI + Playback *(done; editor verification in 4.6.1 pending)*

D3 = **new `Sequencer` autoload**. First on-air-capable stage: **preset playlist
+ crossfade** (not the full keyframe timeline — that is later expansion).

**New file**
- `sequencer.gd` — Autoload **Sequencer** (after `BgCore`, before `RuntimeUI`). Playlist =
  ordered `Array` of steps `{preset, hold (s), trans (s)}`. `play()` runs the
  list in a loop: hold each step for `hold`, then blend to the next step over `trans` —
  **same scene** → param morph (`ParamStore.apply_lerp` A→B per frame),
  **different scene** → existing zoom transition (`BackgroundStage.transition_to`),
  then `apply` preset values to the new scene. Abort/restart via
  generation counter `_gen` (each operation increments it; running coroutine aborts
  once its captured generation is stale) — `_playing` is pure UI display, so
  **NEXT** also works while stopped. API: `add_step/remove_step/move_step/
  set_step_value/clear`, `get_step/step_count/current_index/is_playing`, `play/stop/
  next`; `state_changed` signal. Playlist persisted as JSON to `user://sequence.json`
  (plain string/float values) and loaded on startup.

**Changed files**
- `project.godot` — `Sequencer="*res://sequencer.gd"` between `BgCore` and `RuntimeUI`.
- `background_stage.gd` — accessors `current_scene_index()`, `scene_key_for_index(idx)`
  (root node name via `PackedScene.get_state()` **without** instantiation — cheap) and
  `scene_index_for_key(key)`. This lets the sequencer map the `scene` tag of a preset
  (= `active_scene_key`) to a SCENES index to switch to it when needed.
- `runtime_ui.gd` — persistent **SEQUENCE** section (`_build_sequencer_config`, starts
  collapsed): preset dropdown + **ADD**, height-limited scrollable step list
  (`_refresh_seq_list`/`_build_seq_step`: marker+name+↑↓✕ and hold/trans spinboxes),
  **PLAY/STOP/NEXT** + status. `state_changed` → rebuild list (active step marked with ▶);
  `presets_changed` → rebuild dropdown.

**Deliberate limitations (→ S5 / later):** only ONE transition mode (zoom); `cross` comes in
S5. No per-param keyframes/scrubber (full timeline later). On cross-scene step,
one frame is waited after `active_changed` so ParamStore has rebuilt its register for the new
scene before the preset values take effect.

**Verification in Godot 4.6.1 (to be done by user)**
1. Project loads without errors (Sequencer parses, no lambda/parser errors).
2. Save ≥2 presets (S3), expand SEQUENCE → **ADD** per preset → steps appear.
3. **PLAY**: playlist loops; same scene morphs smoothly, different scene zooms
   across; active step is marked with ▶. **STOP** pauses, **NEXT** jumps manually.
4. Adjust hold/trans per step, change order with ↑↓, ✕ deletes — takes effect immediately.
5. Restart app → playlist (from `user://sequence.json`) is still there.

### S5 — Transition Modes + Schema Comfort + Particle Wave Fix *(done; editor verification in 4.6.1 pending)*

**Crossfade Transition (G6):**
- `background_stage.gd` — `transition_to(target_idx, mode="zoom")`: two branches: "cross" = pure fade without zoom hub (both materials at zoom=1), "zoom" = existing push-zoom
- `sequencer.gd` — `add_step(preset, hold, trans, mode="zoom")` saves `mode` field, `_go_to()` reads it and passes to `_stage.transition_to(idx, mode)`
- `runtime_ui.gd` — **SEQUENCE**: PREV button for backward navigation; per-step `mode` dropdown (Zoom/Cross) in `_build_seq_step`; JSON toggle with EXPORT/IMPORT for playlist

**Shape Picker (G7):**
- `particle_wave.gdshader` — new `shape` uniform with 5 shapes (Dot/Ring/Square/Star/Cross)
- `runtime_ui.gd` — `_add_shape_picker()` builds 5-button HBox; `_add_control_for` routes `shape` uniforms there

**Wire Mesh for Wave:**
- `wave_wire.gdshader` — NEW: shader for PRIMITIVE_LINES, same wave vertex formula, `_Sync` group (hidden from UI), only `wire_opacity` exposed
- `grid_builder.gd` — completely rewritten: `set_density()` triggers rebuild; `_build_wire()` creates sibling wire node with index buffer (horizontal+vertical lines)
- `particle_wave_root.gd` — NEW: root script with camera params (@exports) + `_sync_wire()` propagates grid uniforms to wire per frame

**Particle Wave Fix (Critical — was visually wrong):**

HTML comparison revealed fundamental errors:
- **Grid Z not centered**: HTML builds `(j/(GH-1) - 0.5)*SPAN_Z`; Godot was `j/(GH-1)*SPAN_Z` → grid started at 0 instead of centered
- **Point size linear instead of perspective**: HTML `120/vz`; Godot was depth-linear mix
- **Fragment thresholds wrong**: HTML `smoothstep(0.2,0.6)` / `smoothstep(0.55,0.9)`, Crest `smoothstep(0.45,0.85)`; Godot `(0,0.55)` / `(0.55,0.95)` / `(0.6,0.95)`
- **Glow formula wrong**: HTML two `m`-weighted terms; Godot simplified
- **Flow dependent on speed**: HTML `uFlowT` independent accumulator; Godot `speed*flow`
- **Camera height wrong**: HTML default 3.5; Godot 4.0
- **cam_pitch semantics**: HTML is Y coordinate of look target, not an angle

**Fixes in files:**
- `particle_wave.gdshader`: point size `point_size * (120.0/vz)`, fragment thresholds `(0.2,0.6)` / `(0.55,0.9)` / Crest `(0.45,0.85)`, glow two terms with `m`, flow `TIME*flow*8.0` (independent)
- `wave_wire.gdshader`: same fixes; wire fragment `mix(elem_a, elem_b, ...)`
- `grid_builder.gd`: Grid Z: `(j/(GH-1)-0.5)*span_z`, span 60×120 → **320×420**
- `particle_wave_root.gd`: cam_height 4.0 → **3.5**, cam_pitch semantics: angle → Y coordinate, `look_at(camYaw*0.3, camPitch, 60.0)`
- `particle_wave.tscn`: all defaults updated

**Verification in Godot 4.6.1 (to be done by user)**
1. Wave scene loads, grid visible (no longer z_far-clipped), perspective correct
2. Particle size changes with camera depth (near points larger)
3. Color gradients from valley (dark) to crest (bright) smooth and correct
4. Glow on crests intense (two-term formula)
5. Flow animation runs smoothly, independent of speed parameter
6. cam_pitch slider moves view vertically (Y coordinate), not tilting
