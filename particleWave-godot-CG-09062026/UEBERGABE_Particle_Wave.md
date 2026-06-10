# Übergabe & Arbeitsanweisung — Particle Wave (Godot-Portierung)

> **An die Claude-Instanz, die dieses Projekt übernimmt:** Du hast keinen Zugriff
> auf die Vorgeschichte. Alles Nötige steht hier. Die zugehörigen Dateien
> (Godot-Projekt als ZIP, ggf. Three.js-Referenz) sind dieser Unterhaltung
> beigefügt — bitte zuerst sichten.

---

## 1. Kontext: Was ist das Gesamtprojekt?

Wir entwickeln animierte **Hintergrund-Visuals** (Backgrounds) für Broadcast-/
Corporate-Einsatz. Es gibt vier Ansätze, die ursprünglich als einzelne
Single-File-PoCs in **Three.js / WebGL** gebaut und visuell validiert wurden:

1. **Silk-Mesh** — geschlossene Oberfläche mit Höhenfeld-Displacement + Specular.
2. **Plexus** — CPU-simuliertes dynamisches Linking zwischen Punkten (Linien).
3. **Particle Wave** — statisches Punkt-Gitter, Wellen im Vertex-Shader (GPU).
4. **Tunnel / Light-Streaks** — Partikel fliegen auf die Kamera zu, News-Look.

Alle vier teilen eine **Post-Pipeline**: HDR → Bloom/Glow → ACES-Tonemap → DOF,
plus Vignette und Filmkorn.

**Strategisches Ziel:** Weg von der Browser-/Three.js-Lösung, hin zu **Godot 4.6.1**.
Endausbau ist ein „Background Studio" zum Umschalten zwischen den Setups inkl.
Transitions. Das ist aber **später** — aktuell sind wir in der POC-Phase:
einzelne Backgrounds 1:1 nach Godot portieren und Portierbarkeit beweisen.

---

## 2. Stand: Was ist fertig?

**Particle Wave ist als erster Godot-POC portiert und läuft.** Das Projekt liegt
als ZIP bei (`particle-wave-godot.zip`). Inhalt:

- `project.godot` — Godot 4.4, **Forward+** Renderer (Glow braucht Forward+ oder Mobile).
- `particle_wave.tscn` — Hauptszene: WorldEnvironment (Post-Pipeline), Camera3D, Grid.
- `particle_wave.gdshader` — Spatial-Shader. Das Höhenfeld (`field()`) läuft im
  `vertex()`, 1:1 portiert aus dem Three.js-GLSL. Alle Parameter sind Uniforms
  mit `hint_range` (erscheinen als Regler im Inspector).
- `grid_builder.gd` — erzeugt das statische Punkt-Gitter als `ArrayMesh`
  (`PRIMITIVE_POINTS`). Das Gitter ändert sich nie; die gesamte Animation
  passiert auf der GPU. Zentraler Effizienzpunkt.
- `README.md` — Kurzanleitung.

**Verifiziert:** Shader kompiliert, Szene lädt, Gitter (48.400 Punkte) baut
fehlerfrei. Getestet auf RTX 2080 Ti, Forward+. Render entspricht weitgehend
dem Three.js-Original (Tiefenstaffelung, Glow am Horizont, blaue Färbung, DOF).

---

## 3. Offene Punkte (das ist deine Aufgabe)

In Prioritätsreihenfolge:

**A) Kamera-Defaults korrigieren.**
Der Kamera-Transform in der `.tscn` saß falsch — beim ersten Start war das Bild
schwarz, die Kamera musste manuell repositioniert werden. Übernimm die jetzt
funktionierenden Werte (Camera3D-Node → Transform im Inspector ablesen) als
neue Defaults in die Szene, damit das Projekt out-of-the-box korrekt rendert.

**B) Vertikale Linien-Artefakte entfernen.**
Im Render erscheinen ein bis zwei dunkle vertikale Streifen (Bildmitte/rechts).
Vermutete Ursache: steiler Blickwinkel, bei dem das Gitter sich selbst
überlagert, oder die DOF-Far-Kante. Über Kamerawinkel, `z_far` und
`dof_blur_far_distance/transition` justieren.

**C) Parameter-Bedienung verstehen & dokumentieren.**
Es gibt **bewusst kein** In-Game-Slider-Panel (das wäre erst das „Studio").
Parameter werden im **Editor-Inspector** justiert: Grid-Node wählen →
Material → Shader-Parameter. Falls der Kollege Live-Regler in der laufenden
App braucht, ist das ein neues Feature (siehe D).

**D) (Optional, Richtung Studio) Minimales In-Game-Control-Panel.**
Ein Godot-`Control`-Overlay mit Slidern, die `set_shader_parameter()` auf dem
Material aufrufen. Erst bauen, wenn A–C sitzen.

---

## 4. Technische Leitplanken (wichtig für saubere Arbeit)

- **Godot-Version:** 4.6.1, Forward+ Renderer. Nicht auf Compatibility wechseln —
  dort funktioniert Glow nicht.
- **Höhenfeld-Logik nicht „verbessern" wollen.** Die `field()`-Funktion ist
  bewusst eine exakte Portierung des validierten Three.js-Codes (Sinus-Oktaven,
  Domain-Warp, Wellenlängen-Skalierung, gerichtete Fließbewegung). Optische
  Abweichungen zuerst über Kamera/Post lösen, nicht durch Umschreiben des Felds.
- **Post-Pipeline lebt in der WorldEnvironment-Node**, nicht im Shader. Das ist
  Absicht und löst ein Altproblem (Grain/Vignette waren in den vier Three.js-
  Setups als kopierter Shader-Code uneinheitlich). Eine zentrale Stelle.
- **Bekannte Grenze — Punkt-Shapes:** Die Punkte nutzen Hardware-Point-Sprites
  (`POINT_SIZE`/`POINT_COORD`). Diese werden auf vielen GPUs (NVIDIA, Apple M-Serie)
  auf ~64px geclamped. Solange die Punkte klein sind, unkritisch. Die fünf Shapes
  aus dem Three.js-PoC (Dot/Ring/Square/Star/Cross) sind **nicht** portiert — sie
  bräuchten ein MultiMesh mit QuadMesh statt Point-Sprites. Erst bei Bedarf angehen.
- **Verifikation:** Du kannst ein Godot-Projekt headless prüfen
  (`godot --headless --import` und ein kurzes `SceneTree`-Skript zum Laden von
  Shader/Szene), aber das visuelle Ergebnis muss der Mensch am Bildschirm abnehmen,
  weil Shading erst auf echter GPU sichtbar wird.

---

## 5. Nächster POC nach Particle Wave

**Silk-Mesh** ist der logische nächste Schritt: fast derselbe Vertex-Shader wie
Particle Wave, aber als geschlossene Fläche (`PlaneMesh` mit hoher Subdivision)
statt Punkten, mit echtem Lighting/Specular über Godots Standard-Material-Modell
und im Shader neu berechneten Normalen.

**Plexus** ist der schwierigste Port (kein Godot-Built-in für Punkt-zu-Punkt-
Linien; entweder `ImmediateMesh` pro Frame aus GDScript oder Compute-Shader) —
nicht als nächstes, sondern wenn die einfacheren sitzen.

---

## 6. Erste Schritte für dich (konkret)

1. ZIP entpacken, in Godot 4.6.1 (Forward+) als Projekt öffnen, F5.
2. Falls schwarz: Camera3D selektieren, Transform prüfen/anpassen, bis das
   Gitter sichtbar ist. Funktionierende Werte als Default zurückschreiben (Punkt A).
3. Render mit dem Menschen abgleichen; Artefakte (Punkt B) gemeinsam justieren.
4. Vor jeder Shader-/Szenen-Änderung den aktuellen Stand sichern (Versionierung).

Frag den Menschen nach den funktionierenden Kamera-Werten, bevor du rätst —
er hat sie gerade live ermittelt.
