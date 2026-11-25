extends Node2D
## The player. WASD / arrows / drag to move. The pitchfork swings automatically at the
## nearest zombie in reach, but every swing costs stamina, so you can't hold every side
## at once. Pick your fights.

var main: Node2D
var speed := 230.0
var attack_cd := 0.0
var attack_rate := 0.45
var reach := 80.0
var swing_time := 0.0
var swing_to := Vector2.ZERO
var carrying: Node2D = null
var facing := 1.0
var t := 0.0
var bot_input := Vector2.ZERO  # used by the autotest bot
var stamina := 5.0
const STAMINA_REGEN := 0.9     # swings per second recovered


func max_stamina() -> float:
	return 4.0 + main.fork_level


func damage() -> float:
	return 22.0 + 12.0 * (main.fork_level - 1)


func tick(delta: float) -> void:
	t += delta
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1
	if main.touch_dir != Vector2.ZERO:
		dir = main.touch_dir
	if bot_input != Vector2.ZERO:
		dir = bot_input
	if dir != Vector2.ZERO:
		dir = dir.limit_length(1.0) if main.touch_dir != Vector2.ZERO and bot_input == Vector2.ZERO else dir.normalized()
		if absf(dir.x) > 0.1:
			facing = signf(dir.x)
	var s := speed * (0.8 if carrying else 1.0)  # UX spec: carry at 80 % speed
	position += dir * s * delta
	position = position.clamp(main.farmer_min, main.farmer_max)

	attack_cd = max(0.0, attack_cd - delta)
	swing_time = max(0.0, swing_time - delta)
	stamina = minf(max_stamina(), stamina + STAMINA_REGEN * delta)
	if attack_cd <= 0.0 and stamina >= 1.0:
		var target: Node2D = main.nearest_enemy(position, reach)
		if target:
			target.take_damage(damage())
			swing_to = target.position - position
			swing_time = 0.15
			attack_cd = attack_rate
			stamina -= 1.0
			if target.hp <= 0.0:
				main.on_enemy_killed(target)
	queue_redraw()


func _draw() -> void:
	if main.is_night():
		draw_circle(Vector2.ZERO, 120, Color(1, 0.85, 0.45, 0.07))
		draw_circle(Vector2.ZERO, 70, Color(1, 0.85, 0.45, 0.07))
	var bounce := absf(sin(t * 10.0)) * 2.0
	draw_circle(Vector2(0, 12), 11, Color(0, 0, 0, 0.25))
	draw_circle(Vector2(0, -bounce), 12, Color(0.25, 0.4, 0.75))  # overalls
	draw_circle(Vector2(0, -12 - bounce), 8, Color(0.95, 0.78, 0.6))  # head
	draw_rect(Rect2(-12, -21 - bounce, 24, 4), Color(0.85, 0.7, 0.3))  # hat brim
	draw_rect(Rect2(-7, -27 - bounce, 14, 7), Color(0.85, 0.7, 0.3))
	if main.is_night():
		var ms := max_stamina()
		draw_rect(Rect2(-16, 16, 32, 4), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(-16, 16, 32 * stamina / ms, 4), Color(0.4, 0.8, 1.0) if stamina >= 1.0 else Color(1, 0.4, 0.3))
		if stamina < 1.0:
			draw_string(ThemeDB.fallback_font, Vector2(-18, 34), "tired!", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 0.6, 0.5))
	if swing_time > 0.0:
		var tip := swing_to.limit_length(reach)
		draw_line(Vector2.ZERO, tip, Color(0.75, 0.75, 0.8), 3.0)
		draw_arc(tip, 10, 0, TAU, 12, Color(1, 1, 1, 0.8), 2.0)
	else:
		draw_line(Vector2(10 * facing, -4), Vector2(22 * facing, -22), Color(0.55, 0.4, 0.2), 3.0)
		draw_line(Vector2(19 * facing, -26), Vector2(25 * facing, -18), Color(0.75, 0.75, 0.8), 2.0)
