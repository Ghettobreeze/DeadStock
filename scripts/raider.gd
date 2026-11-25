extends Node2D
## A rival gang member (a goat or hog in a bandana) raiding YOUR farm during a scheduled
## rival raid night. Raiders don't bite. They smash a fence section, run for the barn,
## steal a slice of your coins and leave. Knock them out first and they pay you a bounty.

var main: Node2D
var is_raider := true
var hp := 70.0
var max_hp := 70.0
var speed := 70.0
var chew_dps := 30.0
var radius := 12.0
var inside := false
var fleeing := false
var stolen := 0
var t := 0.0
var flash := 0.0
var chewing := false
var gang_color := Color(0.85, 0.3, 0.35)
var goat := true


func setup(m: Node2D, night: int, tier: int, color: Color) -> void:
	main = m
	max_hp = 60.0 + 10.0 * night + 25.0 * tier
	hp = max_hp
	speed = randf_range(62.0, 78.0)
	chew_dps = 26.0 + 8.0 * tier
	gang_color = color
	goat = randf() < 0.5
	t = randf() * 10.0


func is_enemy() -> bool:
	return true


func take_damage(amount: float) -> void:
	hp -= amount
	flash = 0.15


func tick(delta: float) -> void:
	t += delta
	flash = max(0.0, flash - delta)
	chewing = false
	var to_center: Vector2 = main.pen_center - position
	if fleeing:
		position -= to_center.normalized() * speed * 1.2 * delta
		if to_center.length() > main.pen_radius + 260.0:
			main.on_raider_escaped(self)
		queue_redraw()
		return
	if not inside:
		if to_center.length() <= main.pen_radius + 8.0:
			var seg: int = main.segment_at(position)
			if main.fence_hp[seg] > 0.0:
				chewing = true
				main.damage_fence(seg, chew_dps * delta)
			else:
				inside = true
				position += to_center.normalized() * 14.0
		else:
			position += to_center.normalized() * speed * delta
	else:
		var barn: Vector2 = main.barn_rect.get_center()
		position = position.move_toward(barn, speed * delta)
		if position.distance_to(barn) < 40.0:
			stolen = main.raider_steal(self)
			fleeing = true
	queue_redraw()


func _draw() -> void:
	var body := Color(0.62, 0.55, 0.45) if goat else Color(0.8, 0.55, 0.55)
	if flash > 0.0:
		body = Color.WHITE
	draw_circle(Vector2(0, radius * 0.8), radius, Color(0, 0, 0, 0.2))
	draw_circle(Vector2.ZERO, radius, body)
	if goat:
		draw_line(Vector2(-5, -10), Vector2(-9, -18), Color(0.9, 0.85, 0.7), 2.5)  # horns
		draw_line(Vector2(5, -10), Vector2(9, -18), Color(0.9, 0.85, 0.7), 2.5)
	draw_rect(Rect2(-10, -7, 20, 5), gang_color)  # gang bandana
	draw_circle(Vector2(4, -2), 2.0, Color.BLACK)
	if fleeing and stolen > 0:
		draw_circle(Vector2(0, 10), 6, Color(1, 0.85, 0.2))  # sack of your coins
		draw_string(ThemeDB.fallback_font, Vector2(-6, 14), "$", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.3, 0.2, 0))
	if chewing:
		draw_string(ThemeDB.fallback_font, Vector2(-16, -22), "SMASH", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.7 + 0.3 * sin(t * 12)))
	var w := 26.0
	draw_rect(Rect2(-w / 2, -radius - 12, w, 4), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(-w / 2, -radius - 12, w * clampf(hp / max_hp, 0, 1), 4), Color(0.95, 0.6, 0.2))
