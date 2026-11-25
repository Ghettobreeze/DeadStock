extends Node2D
## A farm animal. Healthy animals wander the pen and pay out at dawn.
## A bitten animal is INFECTED and turns into a ZOMBIE when its timer runs out,
## unless the player saves it (carry to the barn), cures it (vaccine) or culls it.

enum State { HEALTHY, INFECTED, CARRIED, ZOMBIE, SAFE }  # SAFE = saved, inside the barn until dawn

## Turn timer now comes from main.turn_timer (captain test build: default 8 s, cycle with T).
var infect_total := 12.0
var bitten_at := 0.0
var contact_time := 0.0  # auto-carry: seconds the farmer has been touching this animal

const KINDS := {
	"chicken": {"radius": 9.0, "color": Color(0.98, 0.93, 0.55), "speed": 55.0, "payout": 3, "zhp": 30.0},
	"pig": {"radius": 13.0, "color": Color(0.96, 0.66, 0.7), "speed": 40.0, "payout": 6, "zhp": 55.0},
	"cow": {"radius": 17.0, "color": Color(0.95, 0.95, 0.92), "speed": 32.0, "payout": 10, "zhp": 90.0},
}

var kind := "chicken"
var state := State.HEALTHY
var infect_time := 0.0
var hp := 1.0
var max_hp := 1.0
var radius := 10.0
var base_color := Color.WHITE
var speed := 40.0
var main: Node2D
var wander_target := Vector2.ZERO
var wander_timer := 0.0
var bite_cd := 0.0
var t := 0.0
var flash := 0.0


func setup(k: String, m: Node2D) -> void:
	kind = k
	main = m
	var d: Dictionary = KINDS[kind]
	radius = d["radius"]
	base_color = d["color"]
	speed = d["speed"]
	t = randf() * 10.0
	_pick_wander()


func payout() -> int:
	return KINDS[kind]["payout"]


func is_enemy() -> bool:
	return state == State.ZOMBIE


func is_bitable() -> bool:
	return state == State.HEALTHY


func infect() -> void:
	if state != State.HEALTHY:
		return
	state = State.INFECTED
	infect_total = main.turn_timer
	infect_time = infect_total
	bitten_at = main.night_time
	contact_time = 0.0


func cure() -> void:
	visible = true
	state = State.HEALTHY
	infect_time = 0.0
	flash = 0.5
	_pick_wander()


func turn() -> void:
	state = State.ZOMBIE
	max_hp = KINDS[kind]["zhp"] + 6.0 * main.night
	hp = max_hp
	speed = KINDS[kind]["speed"] * 1.6 + 20.0


func take_damage(amount: float) -> void:
	hp -= amount
	flash = 0.15


func _pick_wander() -> void:
	wander_target = main.random_point_in_pen() if main else position
	wander_timer = randf_range(1.5, 4.0)


func tick(delta: float) -> void:
	t += delta
	flash = max(0.0, flash - delta)
	bite_cd = max(0.0, bite_cd - delta)
	match state:
		State.HEALTHY:
			var s := speed * (1.5 if main.is_night() else 1.0)
			_wander(delta, s)
		State.INFECTED:
			infect_time -= delta
			_wander(delta, speed * 0.5)
			if infect_time <= 0.0:
				main.on_animal_turned(self)
		State.CARRIED:
			infect_time -= delta
			position = main.farmer.position + Vector2(0, -26)
			if infect_time <= 0.0:
				main.on_animal_turned(self)
		State.ZOMBIE:
			_zombie_tick(delta)
		State.SAFE:
			visible = false
	queue_redraw()


func _wander(delta: float, s: float) -> void:
	wander_timer -= delta
	if wander_timer <= 0.0 or position.distance_to(wander_target) < 6.0:
		_pick_wander()
	position = position.move_toward(wander_target, s * delta)


func _zombie_tick(delta: float) -> void:
	var target: Node2D = main.nearest_bitable(position)
	if target == null:
		_wander(delta, speed * 0.6)
		return
	position = position.move_toward(target.position, speed * delta)
	if bite_cd <= 0.0 and position.distance_to(target.position) < radius + target.radius + 2.0:
		main.bite(target, self)
		bite_cd = 1.4


func _draw() -> void:
	var col := base_color
	var eye := Color(0.1, 0.1, 0.1)
	var wobble := Vector2.ZERO
	if state == State.ZOMBIE:
		col = base_color.lerp(Color(0.45, 0.75, 0.35), 0.6)
		eye = Color(1, 0.15, 0.1)
		wobble = Vector2(sin(t * 9.0) * 1.5, 0)
	elif state == State.INFECTED or state == State.CARRIED:
		col = base_color.lerp(Color(0.6, 0.4, 0.8), 0.35 + 0.25 * sin(t * 10.0))
		wobble = Vector2(sin(t * 30.0) * 1.5, 0)
	if flash > 0.0:
		col = col.lerp(Color.WHITE, 0.6)
	# shadow
	draw_circle(Vector2(0, radius * 0.7), radius * 0.9, Color(0, 0, 0, 0.18))
	# body
	draw_circle(wobble, radius, col)
	if kind == "cow":
		draw_circle(wobble + Vector2(-5, -3), 5, Color(0.15, 0.15, 0.15))
		draw_circle(wobble + Vector2(6, 4), 4, Color(0.15, 0.15, 0.15))
	elif kind == "chicken":
		draw_circle(wobble + Vector2(0, -radius - 1), 3, Color(0.9, 0.2, 0.2))
		draw_colored_polygon(PackedVector2Array([wobble + Vector2(radius - 1, -2), wobble + Vector2(radius + 6, 0), wobble + Vector2(radius - 1, 2)]), Color(1, 0.6, 0.1))
	elif kind == "pig":
		draw_circle(wobble + Vector2(radius - 3, 1), 4.5, col.darkened(0.15))
	# eyes
	draw_circle(wobble + Vector2(radius * 0.35, -radius * 0.3), 2.2, eye)
	draw_circle(wobble + Vector2(-radius * 0.05, -radius * 0.3), 2.2, eye)
	var font := ThemeDB.fallback_font
	if state == State.INFECTED or state == State.CARRIED:
		draw_arc(Vector2.ZERO, radius + 6, -PI / 2, -PI / 2 + TAU * (infect_time / infect_total), 24, Color(0.75, 0.3, 1.0), 3.0)
		draw_string(font, Vector2(-6, -radius - 10), str(ceil(infect_time)), HORIZONTAL_ALIGNMENT_CENTER, -1, 14, Color(1, 0.85, 1))
	if state == State.ZOMBIE:
		var w := radius * 2.2
		draw_rect(Rect2(-w / 2, -radius - 9, w, 4), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(-w / 2, -radius - 9, w * clampf(hp / max_hp, 0, 1), 4), Color(0.9, 0.2, 0.2))
