extends Node2D
## Pop-up text that drifts up and fades: jokes, payouts, warnings.

var text := ""
var color := Color.WHITE
var life := 1.8
var age := 0.0
var size := 16


func _process(delta: float) -> void:
	age += delta
	position.y -= 28.0 * delta
	if age >= life:
		queue_free()
	queue_redraw()


func _draw() -> void:
	var a := 1.0 - clampf((age - life * 0.6) / (life * 0.4), 0.0, 1.0)
	var font := ThemeDB.fallback_font
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string_outline(font, Vector2(-w / 2, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(0, 0, 0, a * 0.8))
	draw_string(font, Vector2(-w / 2, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(color, a))
