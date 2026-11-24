extends Node2D
## A shambling zombie. Walks to the pen, chews through a fence section,
## then goes after the healthiest-looking snack inside.

var main: Node2D
var hp := 40.0
var max_hp := 40.0
var speed := 45.0
var chew_dps := 10.0
var radius := 12.0
var inside := false
var bite_cd := 0.0
var t := 0.0
var flash := 0.0
var chewing := false
var hat := 0


func setup(m: Node2D, night: int) -> void:
	main = m
	max_hp = 50.0 + 12.0 * (night - 1)
	hp = max_hp
	speed = randf_range(38.0, 52.0) + 3.0 * night
	chew_dps = 12.0 + 4.0 * night
	t = randf() * 10.0
	hat = randi() % 4


func is_enemy() -> bool:
	return true


func take_damage(amount: float) -> void:
	hp -= amount
	flash = 0.15


func tick(delta: float) -> void:
	t += delta
	flash = max(0.0, flash - delta)
	bite_cd = max(0.0, bite_cd - delta)
	chewing = false
	if not inside:
		var to_center: Vector2 = main.pen_center - position
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
		var target: Node2D = main.nearest_bitable(position)
		if target == null:
			position = position.move_toward(main.farmer.position, speed * 0.7 * delta)
		else:
			position = position.move_toward(target.position, speed * delta)
			if bite_cd <= 0.0 and position.distance_to(target.position) < radius + target.radius + 2.0:
				main.bite(target, self)
				bite_cd = 1.6
	queue_redraw()


func _draw() -> void:
	var sway := sin(t * 4.0) * 2.0
	var skin := Color(0.45, 0.68, 0.36)
	if flash > 0.0:
		skin = Color(1, 1, 1)
	draw_circle(Vector2(0, radius * 0.8), radius, Color(0, 0, 0, 0.2))
	# arms reaching forward (toward pen centre)
	var dir: Vector2 = (main.pen_center - position).normalized() if not inside else Vector2.RIGHT.rotated(sin(t) * 0.5)
	var side := dir.orthogonal()
	draw_line(side * 7, side * 7 + dir * (16 + sway), skin.darkened(0.2), 4.0)
	draw_line(-side * 7, -side * 7 + dir * (16 - sway), skin.darkened(0.2), 4.0)
	draw_circle(Vector2.ZERO, radius, Color(0.35, 0.3, 0.45))  # ragged overalls
	draw_circle(Vector2(0, -4), radius * 0.75, skin)
	draw_circle(Vector2(-3, -6), 2.0, Color(1, 0.2, 0.1))
	draw_circle(Vector2(4, -5), 2.6, Color(1, 0.2, 0.1))
	match hat:
		0:
			draw_rect(Rect2(-10, -17, 20, 4), Color(0.85, 0.75, 0.4))  # straw hat
			draw_rect(Rect2(-6, -22, 12, 6), Color(0.85, 0.75, 0.4))
		1:
			draw_rect(Rect2(-8, -17, 16, 5), Color(0.8, 0.15, 0.15))  # trucker cap
	if chewing:
		draw_string(ThemeDB.fallback_font, Vector2(-14, -22), "nom", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.7 + 0.3 * sin(t * 12)))
	var w := 26.0
	draw_rect(Rect2(-w / 2, -radius - 12, w, 4), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(-w / 2, -radius - 12, w * clampf(hp / max_hp, 0, 1), 4), Color(0.9, 0.2, 0.2))
