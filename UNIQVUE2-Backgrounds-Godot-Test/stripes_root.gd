extends Node3D
## Stripes scene root — ported from studio-v005 createStripesModule()
## (studio-v005.html:877-970).
##
## Fullscreen slat shader on a ColorRect (CanvasLayer), additive over
## the Gradient-Sky (WorldEnvironment) — as in the web: gradientPass + Stripes-Quad.
## The @exports here are the tunables (captured by ParamStore as scene/*) and
## are mirrored to the ShaderMaterial each frame (equivalent to update() in HTML).
##
## Colors do NOT come from @exports: the shader reads the global STYLE uniforms
## fog_color/elem_a/elem_b directly (uC1/uC2/uC3 in the web, studio-v005.html:940).

@export_group("Stripes")
@export_range(0.0, 6.283, 0.001) var angle: float = 2.007
@export_range(0.0, 2.0, 0.02) var speed: float = 0.4
@export_range(6.0, 80.0, 1.0) var stripe_scale: float = 26.0
@export_range(0.0, 2.0, 0.02) var cross_drift: float = 0.4
@export_range(0.0, 1.0, 0.02) var layer_mix: float = 0.6

@export_group("Variation")
@export_range(0.0, 1.0, 0.02) var width_var: float = 0.6
@export_range(0.0, 1.0, 0.02) var tone_var: float = 1.0
@export_range(0.0, 1.0, 0.02) var sharp: float = 0.4

@export_group("Appearance")
@export_range(0.3, 2.5, 0.05) var contrast: float = 1.1
@export_range(0.0, 1.5, 0.05) var glow: float = 0.4
@export_range(0.0, 1.5, 0.05) var opacity: float = 0.9

@onready var _rect: ColorRect = $CanvasLayer/ColorRect


func _process(_delta: float) -> void:
	var mat := _rect.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("angle", angle)
	mat.set_shader_parameter("speed", speed)
	mat.set_shader_parameter("stripe_scale", stripe_scale)
	mat.set_shader_parameter("cross_drift", cross_drift)
	mat.set_shader_parameter("layer_mix", layer_mix)
	mat.set_shader_parameter("width_var", width_var)
	mat.set_shader_parameter("tone_var", tone_var)
	mat.set_shader_parameter("sharp", sharp)
	mat.set_shader_parameter("contrast", contrast)
	mat.set_shader_parameter("glow", glow)
	mat.set_shader_parameter("opacity", opacity)
