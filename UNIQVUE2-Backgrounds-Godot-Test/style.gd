extends Node
## STYLE — zentrale, background-uebergreifende Farbpalette (Phase S0).
##
## Haelt 8 Farben: 5-Stop-Vertikal-Gradient (zenith..ground) + Depth-Fog +
## zwei Element-Tints (elem_a/elem_b). Diese Palette gilt fuer ALLE Hintergruende
## gemeinsam (entspricht STYLE im Web-Studio, studio-v005.html:230-260).
##
## Die Palette wird in GLOBALE Shader-Uniforms gespiegelt
## (RenderingServer.global_shader_parameter_set). Dadurch lesen Gradient-Sky und
## jeder Szenen-Shader dieselben Werte ueber `global uniform vec4 <key> : source_color;`
## — keine per-Szene-Verkabelung noetig.
##
## Farb-Konvention: die Palette haelt sRGB-Farben (so wie der ColorPicker sie zeigt).
## Shader deklarieren die Uniforms mit `: source_color` -> Godot wandelt EINMAL nach
## linear an der Shader-Grenze. GDScript-Verbraucher (z.B. tunnel_sim.gd faerbt
## CPU-seitig die Vertex-Farben) lesen die sRGB-Farbe direkt via get_color().
##
## changed feuert nach jeder Aenderung -> die UI kann sich aktualisieren.

signal changed

# Schluessel == Name des globalen Shader-Uniforms (siehe project.godot [shader_globals]).
const DEFAULTS := {
	"sky_zenith":     Color("02060d"),
	"sky_mid":        Color("06121f"),
	"sky_horizon":    Color("0a2a4a"),
	"sky_ground_mid": Color("05131f"),
	"sky_ground":     Color("01040a"),
	"fog_color":      Color("06121f"),
	"elem_a":         Color("1f6dff"),
	"elem_b":         Color("bfe8ff"),
}

var _palette: Dictionary = {}


func _ready() -> void:
	for k: String in DEFAULTS:
		_palette[k] = DEFAULTS[k]
	_apply_all()


# Reihenfolge der Schluessel (fuer eine stabile UI-Auflistung).
func keys() -> Array:
	return DEFAULTS.keys()


func get_color(key: String) -> Color:
	return _palette.get(key, Color.MAGENTA)


func set_color(key: String, c: Color) -> void:
	if not _palette.has(key):
		return
	_palette[key] = c
	RenderingServer.global_shader_parameter_set(key, c)
	changed.emit()


# Ganze Palette aus einem Dict {key: Color} uebernehmen (fuer spaetere Presets/States).
func set_palette(p: Dictionary) -> void:
	for k: String in DEFAULTS:
		if p.has(k) and p[k] is Color:
			_palette[k] = p[k]
	_apply_all()


# Aktuelle Palette als Kopie (fuer Snapshots/Export).
func get_palette() -> Dictionary:
	return _palette.duplicate()


func _apply_all() -> void:
	for k: String in _palette:
		RenderingServer.global_shader_parameter_set(k, _palette[k])
	changed.emit()
