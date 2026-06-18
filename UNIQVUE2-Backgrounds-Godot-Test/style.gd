extends Node
## STYLE — central, cross-background color palette (phase S0).
##
## Holds 8 colors: 5-stop vertical gradient (zenith..ground) + depth fog +
## two element tints (elem_a/elem_b). This palette applies to ALL backgrounds
## together (corresponds to STYLE in the web studio, studio-v005.html:230-260).
##
## The palette is mirrored to GLOBAL shader uniforms
## (RenderingServer.global_shader_parameter_set). This lets the Gradient-Sky and
## every scene shader read the same values via `global uniform vec4 <key> : source_color;`
## — no per-scene wiring needed.
##
## Color convention: the palette holds sRGB colors (as shown by the ColorPicker).
## Shaders declare uniforms with `: source_color` -> Godot converts ONCE to
## linear at the shader boundary. GDScript consumers (e.g. tunnel_sim.gd colors
## vertex colors on the CPU) read the sRGB color directly via get_color().
##
## changed fires after every change -> the UI can update itself.

signal changed

# Key == name of the global shader uniform (see project.godot [shader_globals]).
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


# Key order (for a stable UI listing).
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


# Apply an entire palette from a dict {key: Color} (for presets/states).
func set_palette(p: Dictionary) -> void:
	for k: String in DEFAULTS:
		if p.has(k) and p[k] is Color:
			_palette[k] = p[k]
	_apply_all()


# Current palette as a copy (for snapshots/export).
func get_palette() -> Dictionary:
	return _palette.duplicate()


func _apply_all() -> void:
	for k: String in _palette:
		RenderingServer.global_shader_parameter_set(k, _palette[k])
	changed.emit()
