extends Node2D
## Zombies come in types that each need a different answer (that's the puzzle of the night):
##  walker  - shambles to the fence, chews through, goes for the herd.
##  brute   - big and tough, chews fences 3x faster. Spikes only do half. Barricade its lane.
##  crow    - flies straight over the fence at your animals. Scarecrows distract it.
##  bloater - slow. When it dies (or touches an animal) it BURSTS and bites everything nearby.
##            Kill it OUTSIDE the fence, or keep the herd away from it.

const TYPES := {
	"walker": {"hp": 1.0, "speed": 1.0, "chew": 1.0, "r": 12.0, "spike": 1.0},
	"brute": {"hp": 3.0, "speed": 0.65, "chew": 3.0, "r": 17.0, "spike": 0.5},
	"crow": {"hp": 0.45, "speed": 2.0, "chew": 0.0, "r": 9.0, "spike": 0.0},
	"bloater": {"hp": 1.4, "speed": 0.6, "chew": 0.5, "r": 16.0, "spike": 1.0},
}
const BURST_RADIUS := 75.0

var main: Node2D
var ztype := "walker"
var hp := 40.0
var max_hp := 40.0
var speed := 45.0
var chew_dps := 10.0
var radius := 12.0
var spike_mult := 1.0
var inside := false
var aim := Vector2.ZERO      # where it heads for outside the fence (a scarecrow can redirect it)
var bite_cd := 0.0
var t := 0.0
var flash := 0.0
var chewing := false
var hat := 0
var dead := false


func setup(m: Node2D, night: int, type := "walker") -> void:
	main = m
	ztype = type
	var d: Dictionary = TYPES[ztype]
	max_hp = (50.0 + 12.0 * (night - 1)) * float(d["hp"])
	hp = max_hp
	speed = (randf_range(38.0, 52.0) + 3.0 * night) * float(d["speed"])
	chew_dps = (12.0 + 4.0 * night) * float(d["chew"])
	radius = d["r"]
	spike_mult = d["spike"]
	t = randf() * 10.0
	hat = randi() % 4
	inside = ztype == "crow"   # crows ignore fences
	aim = main.decoy_point_for(position, ztype)


func is_enemy() -> bool:
	return not dead


func take_damage(amount: float) -> void:
	hp -= amount
	flash = 0.15


func tick(delta: float) -> void:
	if dead:
		return
	t += delta
	flash = max(0.0, flash - delta)
	bite_cd = max(0.0, bite_cd - delta)
	chewing = false
	if ztype == "crow":
		_crow_tick(delta)
		queue_redraw()
		return
	if not inside:
		var to_center: Vector2 = main.pen_center - position
		if to_center.length() <= main.pen_radius + 8.0:
			var seg: int = main.segment_at(position)
			if main.fence_hp[seg] > 0.0:
				chewing = true
				main.damage_fence(seg, chew_dps * delta)
				if main.pieces.get(seg, "") == "spikes" and spike_mult > 0.0:
					take_damage(main.SPIKE_DPS * spike_mult * delta)
					if hp <= 0.0:
						main.on_enemy_killed(self)
						return
			else:
				inside = true
				position += to_center.normalized() * 14.0
		else:
			position = position.move_toward(aim, speed * delta)
			if position.distance_to(aim) < 2.0:
				aim = main.pen_center
	else:
		var target: Node2D = main.nearest_bitable(position)
		if target == null:
			position = position.move_toward(main.farmer.position, speed * 0.7 * delta)
		else:
			position = position.move_toward(target.position, speed * delta)
			if position.distance_to(target.position) < radius + target.radius + 2.0:
				if ztype == "bloater":
					main.bloater_burst(self, true)
					return
				if bite_cd <= 0.0:
					main.bite(target, self)
					bite_cd = 1.6
	queue_redraw()


func _crow_tick(delta: float) -> void:
	var scare = main.nearest_scarecrow(position)
	if scare != null:
		var sp: Vector2 = scare["pos"]
		position = position.move_toward(sp, speed * delta)
		if position.distance_to(sp) < 16.0 and bite_cd <= 0.0:
			main.peck_scarecrow(int(scare["seg"]), 12.0)
			bite_cd = 1.0
		return
	var target: Node2D = main.nearest_bitable(position)
	if target == null:
		position = position.move_toward(main.farmer.position, speed * 0.5 * delta)
		return
	position = position.move_toward(target.position, speed * delta)
	if bite_cd <= 0.0 and position.distance_to(target.position) < radius + target.radius + 2.0:
		main.bite(target, self)
		bite_cd = 2.2


func _draw() -> void:
	if ztype == "crow":
		_draw_crow()
		return
	var sway := sin(t * 4.0) * 2.0
	var skin := Color(0.62, 0.6, 0.72)   # lavender-grey zombies (art direction: never green)
	if ztype == "bloater":
		skin = Color(0.7, 0.55, 0.78)
	if flash > 0.0:
		skin = Color(1, 1, 1)
	if ztype == "bloater" and position.distance_to(main.pen_center) < main.pen_radius + 60.0:
		# danger ring: everything inside this gets bitten when it bursts
		draw_arc(Vector2.ZERO, BURST_RADIUS, 0, TAU, 32, Color(0.85, 0.4, 1.0, 0.35 + 0.2 * sin(t * 6.0)), 2.0)
	draw_circle(Vector2(0, radius * 0.8), radius, Color(0, 0, 0, 0.2))
	var dir: Vector2 = (main.pen_center - position).normalized() if not inside else Vector2.RIGHT.rotated(sin(t) * 0.5)
	var side := dir.orthogonal()
	var arm := radius * 0.6
	var arm_w := 7.0 if ztype == "brute" else 4.0
	draw_line(side * arm, side * arm + dir * (radius * 1.3 + sway), skin.darkened(0.2), arm_w)
	draw_line(-side * arm, -side * arm + dir * (radius * 1.3 - sway), skin.darkened(0.2), arm_w)
	draw_circle(Vector2.ZERO, radius, Color(0.3, 0.25, 0.25) if ztype == "brute" else Color(0.35, 0.3, 0.45))
	if ztype == "bloater":
		draw_circle(Vector2(0, 2), radius * 0.95, skin)
		draw_circle(Vector2(-5, 4), 3, Color(0.9, 0.5, 1.0, 0.8))
		draw_circle(Vector2(6, 7), 2.5, Color(0.9, 0.5, 1.0, 0.8))
	draw_circle(Vector2(0, -radius * 0.33), radius * 0.75, skin)
	var eye := Color(0.85, 1.0, 0.25)   # chartreuse eyes
	var big := ztype == "brute"
	draw_circle(Vector2(-radius * 0.25, -radius * 0.5), 3.0 if big else 2.0, eye)
	draw_circle(Vector2(radius * 0.33, -radius * 0.42), 3.4 if big else 2.6, eye)
	if ztype == "walker":
		match hat:
			0:
				draw_rect(Rect2(-10, -17, 20, 4), Color(0.85, 0.75, 0.4))
				draw_rect(Rect2(-6, -22, 12, 6), Color(0.85, 0.75, 0.4))
			1:
				draw_rect(Rect2(-8, -17, 16, 5), Color(0.8, 0.15, 0.15))
	if chewing:
		draw_string(ThemeDB.fallback_font, Vector2(-14, -radius - 10), "nom", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.7 + 0.3 * sin(t * 12)))
	var w := radius * 2.2
	draw_rect(Rect2(-w / 2, -radius - 8, w, 4), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(-w / 2, -radius - 8, w * clampf(hp / max_hp, 0, 1), 4), Color(0.9, 0.2, 0.2))


func _draw_crow() -> void:
	var flap := sin(t * 14.0) * 6.0
	var c := Color(0.12, 0.1, 0.16)
	if flash > 0.0:
		c = Color.WHITE
	draw_circle(Vector2(0, 14), 6, Color(0, 0, 0, 0.15))
	draw_colored_polygon(PackedVector2Array([Vector2(-2, 0), Vector2(-16, -4 - flap), Vector2(-6, 3)]), c)
	draw_colored_polygon(PackedVector2Array([Vector2(2, 0), Vector2(16, -4 - flap), Vector2(6, 3)]), c)
	draw_circle(Vector2.ZERO, 6, c)
	draw_circle(Vector2(3, -2), 1.6, Color(0.85, 1.0, 0.25))
	draw_colored_polygon(PackedVector2Array([Vector2(5, 0), Vector2(10, 1), Vector2(5, 2)]), Color(1, 0.7, 0.2))
	var w := 16.0
	draw_rect(Rect2(-w / 2, -14, w, 3), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(-w / 2, -14, w * clampf(hp / max_hp, 0, 1), 3), Color(0.9, 0.2, 0.2))
