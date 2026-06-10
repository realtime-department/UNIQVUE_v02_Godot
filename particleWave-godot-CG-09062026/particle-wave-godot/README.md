# Particle Wave — Godot POC

Portierung des Three.js Particle-Wave-Backgrounds nach Godot 4.4.
Statisches Punkt-Gitter, Wellenbewegung komplett im Vertex-Shader (GPU).

## Starten
1. Godot 4.4 (Forward+) oeffnen, dieses Verzeichnis als Projekt importieren.
2. F5 druecken. `particle_wave.tscn` ist die Hauptszene.

## Anpassen
Grid-Node auswaehlen -> Inspector -> Material -> Shader-Parameter.
Alle Regler aus dem Three.js-PoC sind vorhanden:
amp, freq, wavelength, speed, flow, warp, dir, y_off, mirror,
point_size, glow_boost, Farben (Tal/Mid/Kamm), z_near/z_far.

Post-Pipeline (Glow/ACES/DOF) liegt in der WorldEnvironment-Node,
nicht mehr im Shader — eine zentrale Stelle fuer alle Setups.

## Export zur fertigen App
Projekt -> Export -> Plattform-Template installieren -> Export Project.
(Muss lokal gemacht werden, siehe Begleittext.)

## Bekannte Grenze
Punkte nutzen Hardware-Point-Sprites. Diese werden auf vielen GPUs
auf ~64px geclamped. Fuer sehr grosse Punkte oder echte Shapes
(Ring/Star/Cross) spaeter auf MultiMesh mit QuadMesh umstellen.
