# UNIQVUE2 v05 — Studio-Parität für das Godot-Projekt

**Quelle:** `T:\Godot_BGs\studio-v005.html` (Three.js, ein File, 2107 Zeilen)
**Ziel:** Die fehlende Logik & Features des Web-Studios in das Godot-Projekt
(`UNIQVUE2-Backgrounds-Godot-Test`) übertragen — adaptiert an Godots Stärken,
nicht 1:1 die RT-Pipeline nachgebaut.

**Stand:** S0–S5 implementiert (siehe §4 / §8). S6 (content, 5 weitere Module) offen.

Alle Behauptungen unten sind gegen den Quellcode geprüft; Web-Referenzen als
`studio-v005.html:Zeile`, Godot-Referenzen als `datei.gd:Zeile`.

---

## 1. Was das Web-Studio ist (Architektur)

Ein gekapseltes Modul-System mit zentraler Farb-/Post-/Sequencer-Schicht. Die
Selbstbeschreibung steht in `studio-v005.html:147-158`:

> Jedes Setup ist ein gekapseltes Modul mit eigener Scene+Camera.
> Schnittstelle: `{ id, name, schema, build(), update(dt,p), render(rt), dispose() }`

### 1.1 Sieben Module (Registry `studio-v005.html:1564-1573`)

| id | Name | Technik | Godot-Pendant? |
|----|------|---------|----------------|
| `tunnel` | Tunnel / Streaks | LineSegments + Points-Köpfe, additiv | ✅ `tunnel_wave.tscn` |
| `wave` | Particle Wave | Punkt-Grid + Wireframe + Bildraum-Spiegelung | ✅ `particle_wave.tscn` |
| `plexus` | Plexus | vernetzte Punkte/Links | ❌ fehlt |
| `lines` | Lines | diagonales Streak-Feld (2D-Shader) | ❌ fehlt |
| `stripes` | Stripes | Lamellen-Streifenfeld (2D-Shader) | ❌ fehlt |
| `cubic` | Cubic | instanzierter Würfel-Tunnel | ❌ fehlt |
| `structure` | Structure | Architektur-Flug mit Lightmaps/Texturen | ❌ fehlt |

Jedes Modul liefert ein `schema` (`studio-v005.html:394-417` für tunnel) — Gruppen
aus Items mit `{k,label,min,max,step,dec}`, plus Spezialtypen `dial:true`
(Winkelrad), `toggle:true` (An/Aus) und `shape:'shape'` (Form-Auswahl Dot/Ring/
Square/Star/Cross, `studio-v005.html:1721`).

### 1.2 Zentrales STYLE-Farbsystem (`studio-v005.html:230-260`)

**Global, background-übergreifend.** Eine Palette gilt für ALLE Module:

- 5-Stop-Vertikal-Gradient: `zenith, skyMid, horizon, groundMid, ground`
- `fog` (Depth-Fog) + 2 Element-Tints `elemA` (Tal/fern/Basis), `elemB` (Kamm/nah/Glanz)

Ein `gradientPass` (`studio-v005.html:245-260`) rendert den 5-Stop-Verlauf als
Hintergrund VOR dem Modul; die Module zeichnen additiv darüber und beziehen ihre
Farben aus STYLE statt aus lokalem c1/c2/c3 (z.B. `studio-v005.html:356`,
`studio-v005.html:501`: `U.uC1.value.copy(_SC.fog)` usw.).

### 1.3 Globale Post-Pipeline (`studio-v005.html:205-275`, Loop `2090-2099`)

Über das **komponierte** Bild:
`bright (Threshold) → 2× separabler Gauss-Blur (4 Pässe, zwei Radien) →
tonemap (ACES + Grain + Vignette)`. Geregelt über `GLOBAL = {bloom, thresh,
vignette, grain}` (`studio-v005.html:220`).

### 1.4 Transition-Pass (`studio-v005.html:179-203`)

Kombiniert rtA+rtB. Zwei Modi:
- `uMode 0` = Crossfade
- `uMode 1` = Z-Push (B wächst aus der Tiefe, radiale Front + heller Saum)

### 1.5 State-/Sequencer-System „BgCore" (`studio-v005.html:1575-1693`)

Das Herzstück, das in Godot komplett fehlt:

- **Ein Root-State** hält Vollwerte über **3 Zonen**: `gradient` (STYLE), `module`
  (`{moduleId, params}`), `post` (GLOBAL).
- **`states[]`** sind **Deltas** (Patches) gegen Root. Fehlt eine Zone im Patch →
  erbt Root. Root-Änderung propagiert in alle erbenden States (zentrale Steuerung,
  `studio-v005.html:1586-1589`).
- Operationen: `resolve(root,state)`, `diff(root,full)`, `interpolate(A,B,t)`,
  `summarize` (`studio-v005.html:1614-1692`).
- **Playback** (`studio-v005.html:2051-2071`): Hold-Timer pro State → Auto-Advance →
  `interpolate` über alle 3 Zonen. Gleiches Modul → Param-Lerp (Live-Morph,
  `studio-v005.html:2065-2068`). Anderes Modul → Z-Push/Crossfade über den
  Transition-Pass (`studio-v005.html:2078-2088`).
- Pro State: `hold`, `transition` (zpush/cross), `dur`. Drag-Reorder
  (`studio-v005.html:1962-1966`). Export/Import JSON (`studio-v005.html:2026-2027`).

### 1.6 Schema-getriebene UI

Param-Panel, Post-Panel, Style-Panel, Setup-Selector und Sequencer bauen sich
dynamisch aus `schema` + STYLE + GLOBAL (`studio-v005.html:1748-1853`).

---

## 2. Was das Godot-Projekt heute hat (nach S0)

| Bereich | Stand | Referenz |
|---------|-------|----------|
| Autoloads | `Style → DisplaySetup → BackgroundStage → RuntimeUI` | `project.godot:19-24` |
| Szenen | exakt 2, hartkodiert, zyklischer Wechsel | `background_stage.gd:28-31` |
| Transition | EIN Typ: symmetrischer Zoom + additive Komplementär-Fade | `background_stage.gd:198-206` |
| **Farben** | ✅ **zentrale STYLE-Palette (8 Farben) über globale Shader-Uniforms; Gradient-Sky pro Szene** | `style.gd`, `gradient_sky.gdshader` |
| Post | nur pro-Szene `WorldEnvironment` Glow + Adjustments, kein globaler Composite-Post | `runtime_ui.gd:23-30` |
| UI | auto-introspektiv (Root-`@export` + Shader-Uniforms + feste POST-Params) + STYLE-Picker | `runtime_ui.gd:170-193`, `_build_style_config` |
| States/Presets/Sequencer | **nichts** | — |

Was Godot **besser** macht und behalten werden muss:
- Echte 3D-Szenen mit eigener Kamera/World/Environment je SubViewport — kein
  Render-to-RT-Gefrickel.
- Die Zoom-Transition (`background_stage.gd:198-214`) ist hochwertiger als der
  JS-Z-Push und ist faktisch schon der „zpush"-Modus.
- Die auto-introspektive UI (`runtime_ui.gd`) liefert das Schema gratis aus
  `@export`/Uniforms — wir brauchen kaum manuelle Schemas.

---

## 3. Gap-Analyse: Was fehlt, und der idiomatische Godot-Weg

### G1 — Zentrale Palette + Gradient-Hintergrund (STYLE) ✅ ERLEDIGT (S0)

Globale Palette als `Style`-Autoload, in **globale Shader-Uniforms** gespiegelt
(`RenderingServer.global_shader_parameter_set`). Szenen-Shader lesen
`global uniform vec4 … : source_color`; Gradient via `shader_type sky` über
`EYEDIR.y`. Details in §8.

### G2 — Globaler Composite-Post (Bloom/Tonemap/Vignette/Grain)

**Fehlt:** Einheitlicher Post über das KOMPONIERTE Bild. Heute nur pro-Szene-Glow.

**Godot-Weg — Entscheidung nötig (siehe §5, D1):**
- **Variante A (empfohlen, sauber):** Beide Layer-Rects in einen **Master-Composite-
  SubViewport** rendern, der ein eigenes `WorldEnvironment` trägt (Glow = Bloom,
  Adjustments = Kontrast/Sättigung, Tonemap ACES) **plus** einen finalen
  `canvas_item`-Post-Shader für Vignette + Grain. Vereinheitlicht Post, ermöglicht
  echtes Bloom über die Mischung. Mittlerer Umbau an `background_stage.gd`.
- **Variante B (schneller Zwischenschritt):** Per-Szene-Glow behalten, nur einen
  globalen Vignette/Grain-`canvas_item`-Shader als CanvasLayer (~layer 50) oben
  drauf. Bloom bleibt pro-Szene.

Anbindung an STYLE: die Post-Werte werden später eine eigene „post"-Zone im
State-Modell (G4); für S1 reicht ein globales `Post`-Datenobjekt (analog `Style`).

### G3 — Mehrere Module / Registry / Selector

**Fehlt:** Erweiterbare Registry (heute 2 hartkodiert, `background_stage.gd:28-31`),
ein Szenen-**Selector** (nicht nur „nächste"), Anzeige-Namen-Tabelle.

**Godot-Weg:** SCENES zu einer Tabelle `[{path, display_name, id}]` erweitern;
`transition_to(idx)` existiert bereits (`background_stage.gd:160`) — nur ein UI-
Selector fehlt. (Deckt sich mit improvementPlan 1.4.)

### G4 — State-/Sequencer-System ★ größter Brocken

**Fehlt:** komplett. Kein State-Modell, keine Presets, kein Playback, kein Sequencer.

**Godot-Weg:**
- `BgCore` als `RefCounted`-Klasse portieren: `clone/resolve/diff/interpolate/
  summarize` über Dict `{gradient, module, post}`. Direkte Portierung von
  `studio-v005.html:1592-1693` — reine Datenlogik, gut testbar.
- **Param-Brücke (Kernproblem):** Web-Params sind ein flaches JS-Dict; Godot-Params
  leben auf Nodes (`@export` + Shader-Uniforms). Lösung: eine Snapshot/Apply-Schicht,
  die die in `runtime_ui.gd` bereits enumerierten getter/setter-Callables
  (`runtime_ui.gd:251-252`, `286-292`) unter **stabilen Schlüsseln** (`node::uniform`
  bzw. `prop`) zu einem Dict bündelt. `moduleId` = Szenen-Index/Pfad. `gradient` =
  Style-Palette (liegt nach S0 schon als Dict via `Style.get_palette()` vor). `post`
  = globale Post-Params.
- Sequencer-UI: neuer Bereich in `runtime_ui.gd` (oder eigenes Autoload) — States-
  Liste, +State, Play, Hold/Dur/Transition, Reorder, Save/Load.
- Playback-Engine: `_process`-Loop (in BackgroundStage oder neuem `Sequencer`-
  Autoload): Hold-Timer → Advance → gleiche Szene = Param-Morph via `interpolate`
  je Frame; andere Szene = `transition_to` + gradient/post interpolieren.

### G5 — Parameter-Morph (gleiche Szene)

**Fehlt:** Heute crossfaded die Transition nur das gerenderte Bild; Params springen.

**Godot-Weg:** Param-Tweening über die Apply-Schicht aus G4 — numerisch lerp,
Color lerp, int gerundet (entspricht `studio-v005.html:1673-1690`).

### G6 — Transition-Modi

**Fehlt:** Nur Zoom-Transition. Kein Crossfade-Modus, keine pro-State-Wahl.

**Godot-Weg:** Zweiten Modus `cross` (reine Fade ohne Zoom-Hub) ergänzen; der
bestehende Zoom = `zpush`. Pro-State `transition`-Feld wählt. Geringer Aufwand —
`transition_to` um einen `mode`-Parameter erweitern.

### G7 — Schema-Komfort (Dial / Shape / kuratierte Labels)

**Fehlt (nice-to-have):** Winkelrad (`dial`), Form-Cluster (`shape`), explizite
Labels. Godots `@export_range`/`@export_group` deckt Ranges & Gruppen schon ab.

**Godot-Weg:** Custom-Controls in `runtime_ui.gd` (Dial via `_draw`/Control,
Shape via Button-Reihe). Optional, aufschiebbar.

### G8 — Fehlende Module als Content-Track

5 von 7 Modulen existieren nicht als Godot-Szene (plexus, lines, stripes, cubic,
structure). Das ist **Content**, kein Framework — separater Track, Modul für Modul.
Das Framework (G1–G7) ist modul-agnostisch und hat Vorrang.

---

## 4. Milestones — Reihenfolge & Status

Aufbauend auf dem bestehenden `improvementPlan.md` (M0–M5). v05-studio ist die
Studio-Parität-Erweiterung darüber.

- **S0 — Globale Palette + Gradient-Hintergrund (G1).** ✅ **ERLEDIGT** —
  `Style`-Autoload + `[shader_globals]`; tunnel/wave auf globale Uniforms; Gradient-
  Sky pro SubViewport; STYLE-Picker im Panel. *(Editor-Verifikation in 4.6.1 noch
  ausstehend, s. §8.)*
- **S1 — Globaler Composite-Post (G2).** Master-Composite-Stage (Variante A) mit
  einheitlichem Bloom/Tonemap/Vignette/Grain; im Panel als POST-Zone. *Braucht D1.*
- **S2 — Param-Snapshot/Apply-Schicht (G4-Teil).** ✅ `param_store.gd` (ParamStore-
  Autoload): flaches benanntes Register über die aktive Szene; `capture/apply/
  lerp_values`. D4 entschieden (s. §5, §8).
- **S3 — BgCore-Statemodell + Preset-I/O nach `user://` (G4-Teil).** ✅ `bg_core.gd`
  (BgCore-Autoload): benannte Presets als JSON in `user://presets/`; diff/resolve/
  summarize für S4; PRESET-Sektion im Panel (SAVE/LOAD/DEL). *Faltet improvementPlan
  1.3 ein. Details §8.*
- **S4 — Sequencer-UI + Playback (G4/G5).** ✅ `sequencer.gd` (Sequencer-Autoload):
  Preset-Playlist (Schritt = `{preset, hold, trans}`), Play/Stop/Next, Reorder,
  Persistenz nach `user://sequence.json`; Param-Morph (gleiche Szene, `apply_lerp`) +
  Zoom-Transition (Szenenwechsel). SEQUENCE-Sektion im Panel. D3 entschieden (s. §5).
  *Faltet improvementPlan 1.2 (Auto-Cycle) ein. Volles Keyframe-Timeline = später.*
- **S5 — Transition-Modi + Schema-Komfort + Particle Wave Korrektur (G6/G7).** ✅ **ERLEDIGT** —
  Crossfade-Modus; Shape-Picker; per-Step-Mode-Dropdown; PREV-Button; JSON Export/Import;
  Wire-Grid; Particle Wave zu HTML-Parität korrigiert (Punkt-Größe, Fragment-Thresholds,
  Glow-Formel, Grid-Zentrierung, Kamera-Semantik).
- **S6 (separater Track) — Restliche 5 Module portieren (G8).** Eins nach dem anderen.

Reihenfolge ist hart: S0 lieferte die globalen Uniforms (✅), ohne die S1/S3 keinew
Farb-Zone hätten; S2 liefert die Param-Map, ohne die S4 nichts morphen kann.

---

## 5. Entscheidungspunkte

- **D1 — Composite-Post:** Variante A (Master-SubViewport, echtes Bloom, mehr Umbau)
  vs. Variante B (Vignette/Grain-Overlay, Glow bleibt pro-Szene). → Empfehlung A.
  **Offen — vor S1 zu klären.**
- **D2 — Gradient-Hintergrund:** Sky-Shader vs. ColorRect-Gradient-Layer.
  ✅ **Entschieden: Sky-Shader** (in S0 umgesetzt).
- **D3 — Sequencer-Heimat:** ✅ **Entschieden: neues `Sequencer`-Autoload** (in S4
  umgesetzt; nach `BgCore`, vor `RuntimeUI`). Trennt Laufzeit-Playback (Uhr/Cursor/
  is_playing) von BgCores Datei-I/O; RuntimeUI ruft nur `play/stop/next`.
- **D4 — Param-Identität:** ✅ **Entschieden: flaches benanntes Schema** (in S2
  umgesetzt): `style/<key>`, `scene/<export>`, `mat/<Node>/<uniform>`, `post/<prop>`,
  `overlay/<prop>`. Stabil über Reload/Szenenwechsel; `apply()` überspringt
  Schlüssel, die in der aktiven Szene nicht aufgelöst werden (sauberer Szenenwechsel).

## 6. Risiken / Hinweise

- **Global Shader Uniforms** müssen in `project.godot` unter `[shader_globals]`
  deklariert sein, bevor Shader sie als `global uniform` lesen — sonst stiller Fehler.
  (In S0 erledigt.) 
- **Farbraum:** Globals sind als `color` deklariert + Shader-Uniforms mit
  `: source_color` → genau EINE sRGB→linear-Wandlung an der Shader-Grenze. `Style`
  hält & liefert sRGB; **nie vorab konvertieren**. Sollte das in 4.6.1 doppelt
  konvertieren (Bild zu dunkel), auf `vec4`-Globals + manuelles `srgb_to_linear()`
  in `style.gd` umstellen.
- **Zwei getrennte World3D** (`background_stage.gd:87`): ein einzelner globaler Post
  über die Mischung erzwingt das Zusammenführen beider Rects in ein Ziel (→ D1/A).
- **Bestehende Zoom-Transition NICHT ersetzen** — sie ist das `zpush`-Äquivalent und
  hochwertiger als der JS-Z-Push; nur Crossfade als zweiten Modus daneben.
- **Param-Snapshot** darf nur Panel-sichtbare Laufzeitwerte erfassen (keine Build-
  Time-Felder wie `grid_w/grid_h` aus `grid_builder.gd`, die einen Rebuild brauchen)
  — sonst morpht ein Slider, der zur Laufzeit nichts tut. Deckt sich mit der
  Preset-Scope-Festlegung aus improvementPlan 1.3.
- **`particle_wave.tscn` `unique_id=`-Sanierung** (improvementPlan M0/0.1) ist noch
  offen — in S0 bewusst NICHT angefasst. Sollte vor S2 erledigt sein.
- **Kein git ausführen** (Nutzer-Vorgabe): Commit-Befehle nur beschreiben, nicht
  selbst absetzen.

---

## 7. Nächster Schritt

S0–S5 sind umgesetzt (✅ Framework-Parität + Particle Wave Korrektur). Als Nächstes **S6**
(Content, G8): die restlichen 5 Module nacheinander portieren (plexus, lines, stripes,
cubic, structure). Optional-Ausbau: **S4.5** (volle Keyframe-Timeline — per-Param-Tracks,
Scrubber, Easing als Ausbau des Sequencers). Weiterhin erwägenswert: UI + ParamStore-
Enumeration auf EIN Register vereinen. Optional vorab **M0** (`particle_wave.tscn`
`unique_id=`-Sanierung).

---

## 8. Implementierungs-Log

### S0 — Globale STYLE-Palette + Gradient-Sky *(erledigt; Editor-Verifikation in 4.6.1 offen)*

**Neue Dateien**
- `style.gd` — Autoload (ERSTER in der Reihenfolge). Hält 8 sRGB-Farben
  (`sky_zenith/sky_mid/sky_horizon/sky_ground_mid/sky_ground/fog_color/elem_a/elem_b`),
  spiegelt sie via `RenderingServer.global_shader_parameter_set` in die globalen
  Uniforms, `changed`-Signal. API: `get_color/set_color/get_palette/set_palette/keys`.
- `gradient_sky.gdshader` — `shader_type sky`; 5-Stop-Verlauf über `EYEDIR.y`
  (`t = EYEDIR.y*0.5+0.5`), Stops identisch zum Web (`studio-v005.html:255-258`).

**Geänderte Dateien**
- `project.godot` — `Style` als erster `[autoload]`; neuer `[shader_globals]`-Block
  mit 8 `color`-Globals.
- `particle_wave.gdshader` — `col_valley/col_mid/col_crest` ersetzt durch
  `global uniform vec4 fog_color/elem_a/elem_b : source_color` (c1=Fog, c2=elemA,
  c3=elemB, wie `studio-v005.html:501`).
- `tunnel_sim.gd` — `@export_group("Colors")` + 3 Farb-Exports entfernt; liest
  `fog_color/elem_a/elem_b` je Frame aus `Style` (CPU-Vertex-Farben).
- `tunnel_wave.tscn`, `particle_wave.tscn` — Environment auf `background_mode = 2`
  (Sky) mit Gradient-Sky-`ShaderMaterial`; tote `shader_parameter/col_*` entfernt.
  Glow/Tonemap/Adjustments unverändert. `unique_id=`-Keys bewusst belassen (→ M0).
- `runtime_ui.gd` — kompakter **STYLE**-Bereich (`_build_style_config`, 8 Color-
  Picker 2-spaltig im persistenten `outer`-Container) → `Style.set_color`.

**Verifikation in Godot 4.6.1 (vom Nutzer durchzuführen)**
1. Beide Szenen laden fehlerfrei (Shader kompilieren, keine Parser-Fehler).
2. STYLE-Picker ändern → Gradient UND Element-Farben beider Hintergründe live.
3. Erwartet: Tunnel & Wave nutzen jetzt dieselbe Palette statt alter Lokalfarben.

**ext_resource ohne `uid=`** für `gradient_sky.gdshader` in beiden `.tscn` — Godot
vergibt die uid beim ersten Speichern (vermeidet uid-Mismatch); `.uid`-Dateien für
`style.gd`/`gradient_sky.gdshader` legt der Import an.

### S1 — Globaler Composite-Post *(erledigt; Editor-Verifikation in 4.6.1 offen)*

D1 = **Variante A**. `background_stage.gd`: neuer Master-SubViewport (`use_hdr_2d`,
`own_world_3d`, `UPDATE_ALWAYS`) hält den schwarzen Fond + beide Zoom/Fade-Layer-
Rects; ein darin liegendes `WorldEnvironment` macht **nur** Glow/Bloom (`BG_CANVAS`,
additiv, `glow_hdr_threshold` 0.7). Ein finaler On-Screen-`TextureRect` (`_final`)
sampelt die HDR-Master-Textur und fährt **ACES-Tonemap → Vignette → Grain** in einem
`canvas_item`-OVERLAY_SHADER (Tonemap bewusst NICHT in der Env, da kamera-loses 2D
nur das Glow zuverlässig bekommt). Beide Szenen-`.tscn`-Envs auf Gradient-Sky reduziert
(`tonemap_mode = 0`, kein Glow/Adjustments). Neu: `active_texture()` → Master,
`post_environment()`/`post_overlay()`-Accessoren. `runtime_ui.gd` POST-Sektion zeigt
auf die Master-Env + Vignette/Grain-Slider (`_add_overlay_slider`); `POST_PARAMS` auf
Glow reduziert. Grenze: Szenen-SubViewports sind LDR RGBA8 → Emission >1 klemmt beim
Szene→Master-Hop; Bloom triggert über `glow_hdr_threshold`; Stellschrauben =
`glow_hdr_threshold` / `glow_strength`.

### S2 — Param-Snapshot/Apply-Schicht *(erledigt; Editor-Verifikation in 4.6.1 offen)*

**Neue Datei**
- `param_store.gd` — Autoload **ParamStore** (nach `BackgroundStage`, vor `RuntimeUI`).
  Baut bei jedem `active_changed` ein flaches Register `{key → {key,type,getter,setter}}`
  aus den 5 Quellen (D4-Schema): `style/<key>`, `scene/<export>`, `mat/<Node>/<uniform>`,
  `post/<prop>`, `overlay/<prop>`. API: `capture() → Dictionary`, `apply(values)`
  (überspringt nicht auflösbare Keys), `lerp_values(a,b,t)` + `apply_lerp` (typgerecht:
  `lerpf` / `Color.lerp` / `Vector*.lerp` / bool@0.5), `active_scene_key()`,
  `keys()`/`has_key()`. Snapshot = reines `{key: value}`.
- **In-Session-Persistenz über TRANSITION:** `_scene_cache` (Szenenname → scene/*+mat/*).
  Bei `active_changed` werden die szenenspezifischen Werte der verlassenen Szene
  gesichert und beim Wiederbetreten erneut angewandt — sonst setzt `background_stage`
  sie beim Neu-Instanziieren auf die `.tscn`-Defaults zurück. (style/post/overlay
  überleben ohnehin, da Autoload/Master.) Hält nur zur Laufzeit; persistente
  benannte Presets auf Platte = S3.

**Geänderte Datei**
- `project.godot` — `ParamStore="*res://param_store.gd"` zwischen `BackgroundStage`
  und `RuntimeUI`.

**Hinweis (Drift-Risiko):** Die Enumerations-Logik spiegelt `runtime_ui.gd` (gleiche
5 Quellen, gleiche Typ-Heuristik). S4 sollte erwägen, UI + Store auf EIN Register zu
vereinen, statt zwei parallele Traversierungen zu pflegen.

**Verifikation in Godot 4.6.1 (vom Nutzer durchzuführen)**
1. Projekt lädt fehlerfrei (ParamStore parst, keine Lambda-/Parser-Fehler).
2. Smoke-Test in einem beliebigen Skript/Console:
   `var s = ParamStore.capture()` → enthält `style/sky_zenith`, `post/glow_intensity`,
   `overlay/vignette` + szenenspezifische `scene/*` / `mat/*`-Keys.
3. `ParamStore.apply(s)` nach Slider-Verstellung → Werte springen zurück.
4. Nach `TRANSITION` zur anderen Szene: ein vorher gefangener Snapshot via `apply()`
   setzt nur die geteilten `style/*` + `post/*` + `overlay/*`, ohne Fehler.

### S3 — BgCore-Statemodell + Preset-I/O *(erledigt; Editor-Verifikation in 4.6.1 offen)*

**Neue Datei**
- `bg_core.gd` — Autoload **BgCore** (nach `ParamStore`, vor `RuntimeUI`). Speichert
  benannte Presets als JSON in `user://presets/<name>.json`; Dokument =
  `{version, scene, params}`. Werte JSON-sicher kodiert: `Color → {_t:"col",v:[r,g,b,a]}`,
  `Vector2/3 → {_t:"v2"/"v3",...}`, Zahlen/Bool nativ; beim Lesen dekodiert, `apply`
  zieht sie über die Register-Typen zurecht (`_coerce`). API: `save_current(name)` /
  `save_snapshot(name,snap)`, `load_preset(name)` (liest **und** wendet an, gibt
  Snapshot), `read_preset` / `read_doc`, `delete_preset`, `list_presets`, `has_preset`.
  Zustands-Utilities für S4: `diff(base,other)` (sparse Delta = Root+Delta-Modell),
  `resolve(root,delta)`, `summarize`; Interpolation liefert `ParamStore.lerp_values`.
  `presets_changed`-Signal. Dateinamen via `String.validate_filename()` gesäubert.

**Geänderte Dateien**
- `project.godot` — `BgCore="*res://bg_core.gd"` zwischen `ParamStore` und `RuntimeUI`.
- `runtime_ui.gd` — persistente **PRESET**-Sektion (`_build_preset_config`, im
  `outer`-Container, einmalig gebaut): `OptionButton`-Dropdown der Presets +
  Namens-`LineEdit` + **SAVE/LOAD/DEL** + Status-Label. Dropdown-Auswahl füllt das
  Namensfeld; `presets_changed` → Liste neu aufbauen. Nach **LOAD** gleicht
  `_after_preset_loaded()` die UI an die geänderten Werte an: `_sync_style_swatches()`
  (Swatches in `_style_swatches` gemerkt, `set_block_signals` beim Reread → keine
  Rückkopplung) + `_populate(root)` baut scene/mat/post/overlay-Regler neu.

**Bewusste Grenze (→ S4):** **LOAD** wendet auf die AKTUELLE Szene an; szenenspezifische
Keys einer anderen Szene werden übersprungen. Es wird (noch) NICHT automatisch zur im
Preset getaggten Szene gewechselt — das übernimmt der Sequencer (S4), der Szene +
Parameter koordiniert. Der `scene`-Tag wird dafür bereits mitgespeichert.

**Verifikation in Godot 4.6.1 (vom Nutzer durchzuführen)**
1. Projekt lädt fehlerfrei (BgCore parst, `user://presets/` wird angelegt).
2. Regler/Farben verstellen → Name eintippen → **SAVE**: Datei in `user://presets/`
   erscheint, Dropdown listet sie.
3. Andere Werte einstellen → Preset im Dropdown wählen → **LOAD**: Werte UND
   Slider/Swatches springen auf den gespeicherten Stand; Render aktualisiert.
4. **DEL** entfernt das Preset aus Liste und Ordner.
5. App neu starten → Preset weiterhin in der Liste, **LOAD** stellt es wieder her.

### S4 — Sequencer-UI + Playback *(erledigt; Editor-Verifikation in 4.6.1 offen)*

D3 = **neues `Sequencer`-Autoload**. Erste, on-air-taugliche Stufe: **Preset-Playlist
+ Crossfade** (nicht die volle Keyframe-Timeline — die ist späterer Ausbau).

**Neue Datei**
- `sequencer.gd` — Autoload **Sequencer** (nach `BgCore`, vor `RuntimeUI`). Playlist =
  geordnete `Array` von Schritten `{preset, hold (s), trans (s)}`. `play()` läuft die
  Liste in Schleife: pro Schritt `hold` halten, dann über `trans` zum nächsten Schritt
  überblenden — **gleiche Szene** → Param-Morph (`ParamStore.apply_lerp` A→B je Frame),
  **andere Szene** → bestehende Zoom-Transition (`BackgroundStage.transition_to`),
  danach `apply` der Preset-Werte auf die neue Szene. Abbruch/Neustart über
  Generationszähler `_gen` (jede Operation erhöht ihn; laufende Coroutine bricht ab,
  sobald die gefangene Generation veraltet) — `_playing` ist reine UI-Anzeige, daher
  funktioniert **NEXT** auch im Stillstand. API: `add_step/remove_step/move_step/
  set_step_value/clear`, `get_step/step_count/current_index/is_playing`, `play/stop/
  next`; `state_changed`-Signal. Playlist wird als JSON nach `user://sequence.json`
  persistiert (reine String/Float-Werte) und beim Start geladen.

**Geänderte Dateien**
- `project.godot` — `Sequencer="*res://sequencer.gd"` zwischen `BgCore` und `RuntimeUI`.
- `background_stage.gd` — Accessoren `current_scene_index()`, `scene_key_for_index(idx)`
  (Wurzel-Knotenname via `PackedScene.get_state()` **ohne** Instanziierung — billig) und
  `scene_index_for_key(key)`. Damit bildet der Sequencer den `scene`-Tag eines Presets
  (= `active_scene_key`) auf einen SCENES-Index ab, um bei Bedarf dorthin zu wechseln.
- `runtime_ui.gd` — persistente **SEQUENCE**-Sektion (`_build_sequencer_config`, startet
  eingeklappt): Preset-Dropdown + **ADD**, höhenbegrenzte scrollbare Schrittliste
  (`_refresh_seq_list`/`_build_seq_step`: Marker+Name+↑↓✕ und hold/trans-Spinboxen),
  **PLAY/STOP/NEXT** + Status. `state_changed` → Liste neu (aktiver Schritt mit ▶
  markiert); `presets_changed` → Dropdown neu.

**Bewusste Grenzen (→ S5 / später):** nur EIN Transition-Modus (Zoom); `cross` kommt in
S5. Keine per-Param-Keyframes/Scrubber (volle Timeline später). Beim Cross-Scene-Schritt
wird nach `active_changed` ein Frame gewartet, damit ParamStore sein Register für die neue
Szene neu gebaut hat, bevor die Preset-Werte greifen.

**Verifikation in Godot 4.6.1 (vom Nutzer durchzuführen)**
1. Projekt lädt fehlerfrei (Sequencer parst, keine Lambda-/Parser-Fehler).
2. ≥2 Presets speichern (S3), SEQUENCE aufklappen → je Preset **ADD** → Schritte erscheinen.
3. **PLAY**: Playlist läuft in Schleife; gleiche Szene morpht weich, andere Szene zoomt
   um; aktiver Schritt ist mit ▶ markiert. **STOP** hält an, **NEXT** springt manuell weiter.
4. hold/trans je Schritt verstellen, Reihenfolge mit ↑↓ ändern, ✕ löscht — wirkt sofort.
5. App neu starten → Playlist (aus `user://sequence.json`) ist noch da.

### S5 — Transition-Modi + Schema-Komfort + Particle Wave Korrektur *(erledigt; Editor-Verifikation in 4.6.1 offen)*

**Crossfade-Transition (G6):**
- `background_stage.gd` — `transition_to(target_idx, mode="zoom")`: zwei Branches: "cross" = reine Fade ohne Zoom-Hub (beide Materials bei zoom=1), "zoom" = bestehender Push-Zoom
- `sequencer.gd` — `add_step(preset, hold, trans, mode="zoom")` speichert `mode`-Feld, `_go_to()` liest es und übergibt an `_stage.transition_to(idx, mode)`
- `runtime_ui.gd` — **SEQUENCE**: PREV-Button für Rückwärts-Navigation; pro Schritt `mode`-Dropdown (Zoom/Cross) in `_build_seq_step`; JSON-Toggle mit EXPORT/IMPORT für Playlist

**Shape-Picker (G7):**
- `particle_wave.gdshader` — neue `shape`-Uniform mit 5 Formen (Dot/Ring/Square/Star/Cross)
- `runtime_ui.gd` — `_add_shape_picker()` baut 5-Button-HBox; `_add_control_for` routet `shape`-Uniforms dorthin

**Wire-Mesh für Wave:**
- `wave_wire.gdshader` — NEU: Shader für PRIMITIVE_LINES, gleiche Wave-Vertex-Formel, `_Sync`-Gruppe (hidden von UI), nur `wire_opacity` exposed
- `grid_builder.gd` — vollständig rewritten: `set_density()` triggert Rebuild; `_build_wire()` erstellt Sibling-Wire-Node mit IndexBuffer (horizontal+vertical Linien)
- `particle_wave_root.gd` — NEU: Root-Script mit camera params (@exports) + `_sync_wire()` propagiert Grid-Uniforms zu Wire je Frame

**Particle Wave Korrektur (Kritisch — war visuell falsch):**

HTML-Vergleich zeigte fundamentale Fehler:
- **Grid Z nicht zentriert**: HTML baut `(j/(GH-1) - 0.5)*SPAN_Z`; Godot war `j/(GH-1)*SPAN_Z` → Gitter begann bei 0 statt zentriert
- **Punkt-Größe linear statt perspektivisch**: HTML `120/vz`; Godot war Tiefenliner-Mix
- **Fragment-Schwellwerte falsch**: HTML `smoothstep(0.2,0.6)` / `smoothstep(0.55,0.9)`, Crest `smoothstep(0.45,0.85)`; Godot `(0,0.55)` / `(0.55,0.95)` / `(0.6,0.95)`
- **Glow-Formel falsch**: HTML zwei `m`-gewichtete Terme; Godot vereinfacht
- **Flow abhängig von Speed**: HTML `uFlowT` unabhängiger Accumulator; Godot `speed*flow`
- **Kamera Height falsch**: HTML default 3.5; Godot 4.0
- **cam_pitch Semantik**: HTML ist Y-Koordinate des Look-Target, nicht ein Winkel

**Fixes in Dateien:**
- `particle_wave.gdshader`: Punkt-Größe `point_size * (120.0/vz)`, Fragment Thresholds `(0.2,0.6)` / `(0.55,0.9)` / Crest `(0.45,0.85)`, Glow zwei Terme mit `m`, Flow `TIME*flow*8.0` (unabhängig)
- `wave_wire.gdshader`: gleiche Fixes; Wire-Fragment `mix(elem_a, elem_b, ...)`
- `grid_builder.gd`: Grid Z: `(j/(GH-1)-0.5)*span_z`, span 60×120 → **320×420**
- `particle_wave_root.gd`: cam_height 4.0 → **3.5**, cam_pitch Semantik: angle → Y-Koordinate, `look_at(camYaw*0.3, camPitch, 60.0)`
- `particle_wave.tscn`: alle Defaults aktualisiert

**Verifikation in Godot 4.6.1 (vom Nutzer durchzuführen)**
1. Wave-Szene lädt, Gitter sichtbar (nicht mehr z_far-geklemmt), perspektivisch korrekt
2. Partikel-Größe ändert sich mit Kamera-Tiefe (nahe Punkte größer)
3. Farb-Gradienten von Tal (dunkel) zu Kamm (hell) weich und korrekt
4. Glow auf Kämmen intensiv (zwei-Term-Formel)
5. Flow-Animation läuft flüssig, unabhängig von Speed-Parameter
6. cam_pitch-Slider bewegt Blick vertikal (Y-Koordinate), nicht Kippen
