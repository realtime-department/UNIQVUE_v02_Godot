# Fix Plan — UNIQVUE2-Backgrounds-Godot-Test

Generated from code review. Ordered by severity. Fix blockers before shipping.

---

## P0 — Crash / Hang (fix before any test run)

### 1. `runtime_ui.gd:692,701` — Vector3 string subscript crash
**Problem:** `base["x"]` / `nd[ax] = value` — GDScript 4 does not support string subscript on Vector3. Runtime error on first non-color Vec3 uniform panel.  
**Fix:** Replace `_add_vec3` string-keyed access with explicit axis branches, matching the `_add_vec2` pattern at L668:
```gdscript
var start := base.x if ax == "x" else (base.y if ax == "y" else base.z)
# ...
if ax == "x":   nd.x = value
elif ax == "y": nd.y = value
else:           nd.z = value
```

### 2. `sequencer.gd:252` — `await active_changed` deadlock
**Problem:** `transition_to` (background_stage.gd:404) returns early when `_busy`, scene count < 2, or target invalid — without emitting `active_changed`. Playlist coroutine hangs forever.  
**Fix:** Either (a) guard with a timeout race:
```gdscript
var timer := get_tree().create_timer(5.0)
await _stage.active_changed  # or timer.timeout
```
Or (b) have `transition_to` always emit `active_changed` on early-return, or return a bool the caller checks before awaiting.

### 3. `lines.gdshader:69` — `VIEWPORT_SIZE` not valid in spatial vertex shader
**Problem:** `VIEWPORT_SIZE` is not a built-in in Godot 4 spatial `vertex()`. Shader fails to compile or reads garbage.  
**Fix:** Feed aspect as a uniform from GDScript:
```gdscript
# in _update_materials or _ready:
mat.set_shader_parameter("aspect", float(get_viewport().size.x) / float(get_viewport().size.y))
```
```glsl
uniform float aspect = 1.777;
// remove VIEWPORT_SIZE usage
```

### 4. `perf_monitor.gd:273,278` — divide by zero on first draw
**Problem:** `float(_count)` denominator — `_count` is 0 before `_process` increments it. `_draw()` called first → NaN crash.  
**Fix:** Early-return at top of `_draw()`:
```gdscript
if _count == 0:
    return
```

### 5. `stripes.gdshader:71` — div-by-zero on `SCREEN_PIXEL_SIZE.x`
**Problem:** `SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x` — no guard. Degenerate or headless render → div-by-zero.  
**Fix:**
```glsl
float aspect = SCREEN_PIXEL_SIZE.y / max(SCREEN_PIXEL_SIZE.x, 1e-6);
```

---

## P1 — High Risk (fix before release)

### 6. `quantum_sim.gd:111` — missing delta clamp
**Problem:** Raw `delta` advances `_t`. Every other sim uses `minf(delta, 0.05)`. Frame hitch → visible warp/light-sweep pop.  
**Fix:**
```gdscript
_t += minf(delta, 0.05)
```

### 7. `param_store.gd:202` — freed-node crash in `active_scene_key()`
**Problem:** `root is Node` passes for freed objects; `.name` then crashes during teardown.  
**Fix:**
```gdscript
if not is_instance_valid(root):
    return ""
```

### 8. `background_stage.gd:404` — `_busy` latch on killed tween
**Problem:** `_busy` only resets in `tw.finished` callback. If tween is killed (scene reload, orphan), `finished` never fires — all future transitions silently blocked.  
**Fix:** Reset `_busy` defensively in `_finish_transition` and add a fallback reset:
```gdscript
# After create_tween(), store reference and connect to tree_exiting or add a max-duration timer:
get_tree().create_timer(dur + 1.0).timeout.connect(func(): _busy = false)
```

### 9. `background_stage.gd:309` — HDR toggle incomplete
**Problem:** `set_hdr_mode` toggles root viewport only; master/layer viewports (L141/168) stay in HDR. SDR switch leaves offscreen pipeline in HDR.  
**Fix:** Toggle all three viewports, or confirm mixed HDR/SDR is intentional and document.

### 10. `sequencer.gd:92` — arbitrary keys written to step dict, silently dropped on reload
**Problem:** `set_step_value` writes any key; only `{preset, hold, trans, mode}` re-hydrate from JSON.  
**Fix:** Validate key at entry:
```gdscript
const VALID_KEYS := ["preset", "hold", "trans", "mode"]
func set_step_value(idx: int, key: String, value) -> void:
    if key not in VALID_KEYS:
        push_warning("sequencer: unknown step key '%s'" % key)
        return
    # ...
```

### 11. `sequencer.gd:130,150` — `trans` read from current step, not target
**Problem:** `next()`/`prev()` read transition duration from `_steps[_idx]` (the step being left) but `_run` at L172 reads from the step being entered. Inconsistent — likely should read from target step.  
**Fix:** Verify intended semantics. If target-step is correct:
```gdscript
var trans: float = _steps[nxt].get("trans", 1.0)  # was _steps[_idx]
```

### 12. `cubic_sim.gd:262` — stale outline buffer flash on toggle
**Problem:** `_line_buf` only written `if outlines`. Re-enabling outlines uploads stale transforms → one-frame edge flash.  
**Fix:** Always write `_line_buf`, gate only the `multimesh_set_buffer` upload on `outlines`, or write + upload unconditionally.

### 13. `perf_monitor.gd:112` — thread join blocks on slow OS.execute at exit
**Problem:** `_exit_tree` calls `_thread.wait_to_finish()` while thread may be mid `nvidia-smi` / PowerShell (seconds). Editor/app close stalls.  
**Fix:** Set a cancel flag the poll loop checks, or use `_thread.wait_to_finish()` with a timeout if available, or detach and accept the leak.

### 14. `particle_wave.gdshader:64` — `POINT_SIZE` / `POINT_COORD` require PRIMITIVE_POINTS mesh
**Problem:** These built-ins only work with a PRIMITIVE_POINTS mesh. Per project memory, `use_point_size` is 4.5-flagged. If mesh is wrong primitive, fragments never render.  
**Fix:** Confirm mesh primitive is `PRIMITIVE_POINTS` in the `.tscn`. If not, switch to a quad/billboard approach.

---

## P2 — Precision (critical for long-running wall installs)

### 15. Unbounded float accumulators → `fmod`/`sin` precision loss
**Files:** `structure_sim.gd:293` (`_travel`), `cubic_sim.gd:53,296` (`_t`, `_scroll`)  
**Problem:** Accumulators grow unbounded. After hours of runtime, `fmod`/`sin` of large floats loses precision → visible jitter/shimmer.  
**Fix:** Wrap each accumulator back into its natural period each frame:
```gdscript
# structure_sim.gd
_travel = fmod(_travel + advance, span)

# cubic_sim.gd
_t = fmod(_t + delta_advance, TAU * 1000.0)
```

### 16. `fract(sin(...))` hash banding — `quantum.gdshader:45`, `stripes.gdshader:42`
**Problem:** On mediump GPUs (and with large/growing inputs) this hash bands and repeats. `lines.gdshader` explicitly switched to an integer hash to fix this; the other two didn't follow.  
**Fix:** Port the integer hash from `lines.gdshader` to both shaders.

---

## P3 — Nits / Minor (address if time permits)

| Location | Issue | Fix |
|---|---|---|
| `runtime_ui.gd:636` | `getter.call()` called twice | `var g := getter.call(); var cur := int(g) if g != null else 0` |
| `runtime_ui.gd:848` | `SCENES` / `SCENE_LABELS` length not asserted | Add `assert(SCENES.size() == SCENE_LABELS.size())` in `_ready` |
| `perf_monitor.gd:264–276` | Ring-buffer index uses `+HISTORY`, `+HISTORY*2`, `+HISTORY*100` inconsistently | Unify on `posmod()`-based helper |
| `perf_monitor.gd:143` | `nvidia-smi` `"[N/A]"` → `to_float()` = 0.0, displayed as real value | Check `v.is_valid_float()` before assigning |
| `perf_monitor.gd:96` | Per-frame string alloc + two loop redraws every frame | Throttle `_draw()` to `POLL_INTERVAL` rate |
| `structure_sim.gd:362` | `Style.get_color("fog_color")` every frame | Cache; recompute on style-changed signal |
| `structure_sim.gd:109` | `$Ground` shader params written every frame — confirm `.mesh` assigned | Check `.tscn`; remove dead work if mesh absent |
| `smoothwave.gdshader:64` | Normal ignores z-derivative → wrong Fresnel for z-axis waves | Include `dw/dz` partial or add comment |
| `lines.gdshader:114` + 4 other shaders | Unclamped `ALBEDO`/`EMISSION` into `blend_add` | Decide HDR vs LDR; if LDR add `clamp(col, vec3(0.0), vec3(1.0))` |
| `tunnel_sim.gd:148` | `var len` shadows built-in `len()` | Rename to `streak_len` |
| `plexus_sim.gd:410` | `_pf_links / _pf_frames` integer division | `float(_pf_links) / float(_pf_frames)` |

---

## Decision Required (not bugs, but need intent confirmation)

- **HDR vs LDR render target** — gates all unclamped-shader nits. If HDR + bloom pipeline: no clamp needed; document. If LDR: add `clamp()` to all 5 shaders.
- **`sequencer.gd:210` cross-mode same-scene** — `mode = "cross"` on same-scene step skips `_ensure_scene`; cross-fade never fires. Intended?
- **`background_stage.gd:507` multi-camera** — `_find_camera` activates first Camera3D found depth-first. Confirm single-camera assumption per scene.
