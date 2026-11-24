extends Node2D
## Dead Stock prototype: day prep -> night horde -> dawn payout, repeat.
## Everything is drawn in code so the prototype needs no art assets.

const AnimalScript := preload("res://scripts/animal.gd")
const ZombieScript := preload("res://scripts/zombie.gd")
const FarmerScript := preload("res://scripts/farmer.gd")
const FloatText := preload("res://scripts/float_text.gd")

const PEN_CENTER := Vector2(640, 400)
const PEN_RADIUS := 210.0
const SEGMENTS := 12
const BARN_RECT := Rect2(598, 362, 84, 64)
const ACTION_RANGE := 48.0

enum Phase { DAY, NIGHT, DAWN, GAME_OVER }

# exposed as vars so the entity scripts can read them through `main`
var pen_center := PEN_CENTER
var pen_radius := PEN_RADIUS

var phase := Phase.DAY
var night := 1
var coins := 40
var vaccines := 1
var parts := 0
var fork_level := 1
var fence_level := 1
var fence_max := 100.0
var fence_hp: Array[float] = []

var farmer: Node2D
var animals: Array[Node2D] = []
var zombies: Array[Node2D] = []
var entity_layer: Node2D
var fx_layer: Node2D

var night_time := 0.0
var night_length := 45.0
var to_spawn := 0
var spawn_timer := 0.0
var spawn_interval := 1.0
var stats := {}
var sky := 0.0  # 0 = day, 1 = night

# UI
var ui: CanvasLayer
var top_label: Label
var hint_label: Label
var timer_label: Label
var shop_panel: PanelContainer
var shop_buttons := {}
var dawn_panel: PanelContainer
var dawn_label: Label
var over_panel: PanelContainer
var over_label: Label

# autotest
var autotest_dir := ""
var autotest_t := 0.0
var autotest_shots := {}

const TURN_LINES := {
	"chicken": ["BAWK... BRAAAINS", "the chicken came first. then the zombie.", "cluck cluck GRRR"],
	"pig": ["oink? OINK. *chomp*", "this little piggy went undead", "bacon... has risen"],
	"cow": ["MOOOO-AAARGH", "the cow is lactating ectoplasm", "mad cow, literally"],
}
const CULL_LINES := ["rest easy, Nugget", "sorry, Brisket", "goodnight, Sir Moos-a-lot", "it was mercy. mostly.", "farewell, Porkchop"]
const SAVE_LINES := ["SAVED!", "barn sweet barn", "phew!"]


func _ready() -> void:
	randomize()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest="):
			autotest_dir = a.trim_prefix("--autotest=")
			Engine.time_scale = 3.0
	entity_layer = Node2D.new()
	add_child(entity_layer)
	fx_layer = Node2D.new()
	add_child(fx_layer)
	farmer = FarmerScript.new()
	farmer.main = self
	farmer.position = PEN_CENTER + Vector2(0, 90)
	entity_layer.add_child(farmer)
	_build_ui()
	_new_game()


func _new_game() -> void:
	for a in animals:
		a.queue_free()
	for z in zombies:
		z.queue_free()
	animals.clear()
	zombies.clear()
	night = 1
	coins = 40
	vaccines = 1
	parts = 0
	fork_level = 1
	fence_level = 1
	fence_max = 100.0
	fence_hp.clear()
	for i in SEGMENTS:
		fence_hp.append(fence_max)
	for k in ["chicken", "chicken", "chicken", "pig", "pig", "cow"]:
		_add_animal(k)
	farmer.carrying = null
	farmer.position = PEN_CENTER + Vector2(0, 90)
	_enter_day()


func _add_animal(kind: String) -> void:
	var a: Node2D = AnimalScript.new()
	a.position = random_point_in_pen()
	entity_layer.add_child(a)
	a.setup(kind, self)
	animals.append(a)


# ---------------------------------------------------------------- helpers used by entities

func is_night() -> bool:
	return phase == Phase.NIGHT


func random_point_in_pen() -> Vector2:
	for i in 20:
		var p := PEN_CENTER + Vector2.from_angle(randf() * TAU) * sqrt(randf()) * (PEN_RADIUS - 35.0)
		if not BARN_RECT.grow(14).has_point(p):
			return p
	return PEN_CENTER + Vector2(0, 120)


func segment_at(pos: Vector2) -> int:
	var ang := fposmod((pos - PEN_CENTER).angle(), TAU)
	return int(floor(ang / TAU * SEGMENTS)) % SEGMENTS


func damage_fence(seg: int, amount: float) -> void:
	var before := fence_hp[seg]
	fence_hp[seg] = max(0.0, fence_hp[seg] - amount)
	if before > 0.0 and fence_hp[seg] <= 0.0:
		var mid := (seg + 0.5) / SEGMENTS * TAU
		popup(PEN_CENTER + Vector2.from_angle(mid) * PEN_RADIUS, "FENCE DOWN!", Color(1, 0.4, 0.3))


func nearest_bitable(pos: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for a in animals:
		if a.is_bitable():
			var d := pos.distance_squared_to(a.position)
			if d < best_d:
				best_d = d
				best = a
	return best


func nearest_enemy(pos: Vector2, max_dist: float) -> Node2D:
	var best: Node2D = null
	var best_d := max_dist * max_dist
	for z in zombies:
		var d := pos.distance_squared_to(z.position)
		if d < best_d:
			best_d = d
			best = z
	for a in animals:
		if a.is_enemy():
			var d := pos.distance_squared_to(a.position)
			if d < best_d:
				best_d = d
				best = a
	return best


func bite(target: Node2D, _by: Node2D) -> void:
	if target.is_bitable():
		target.infect()
		stats["bitten"] += 1
		popup(target.position + Vector2(0, -24), "BITTEN!", Color(0.85, 0.5, 1.0))


func on_animal_turned(a: Node2D) -> void:
	if farmer.carrying == a:
		farmer.carrying = null
		a.position = farmer.position + Vector2(20, 0)
	a.turn()
	stats["turned"] += 1
	var lines: Array = TURN_LINES[a.kind]
	popup(a.position + Vector2(0, -30), lines.pick_random(), Color(0.6, 1.0, 0.4), 18)


func on_enemy_killed(e: Node2D) -> void:
	if e in zombies:
		zombies.erase(e)
		stats["kills"] += 1
		e.queue_free()
	elif e in animals:
		animals.erase(e)
		parts += 1
		stats["zombie_animals_killed"] += 1
		popup(e.position, "+1 zombie parts", Color(0.6, 1, 0.5))
		e.queue_free()


func popup(pos: Vector2, text: String, color := Color.WHITE, size := 16) -> void:
	var f: Node2D = FloatText.new()
	f.text = text
	f.color = color
	f.size = size
	f.position = pos
	fx_layer.add_child(f)


func healthy_count() -> int:
	var n := 0
	for a in animals:
		if not a.is_enemy():
			n += 1
	return n


# ---------------------------------------------------------------- phases

func _enter_day() -> void:
	phase = Phase.DAY
	shop_panel.visible = true
	dawn_panel.visible = false
	over_panel.visible = false
	_refresh_ui()


func start_night() -> void:
	if phase != Phase.DAY:
		return
	phase = Phase.NIGHT
	shop_panel.visible = false
	night_time = 0.0
	night_length = 40.0 + 5.0 * night
	to_spawn = 8 + 5 * night
	var waves: int = 3 + night
	spawn_interval = night_length * 0.7 / waves
	spawn_timer = 2.0
	stats = {"bitten": 0, "turned": 0, "saved": 0, "cured": 0, "culled": 0, "kills": 0, "zombie_animals_killed": 0}
	popup(Vector2(640, 200), "NIGHT %d: THE DEAD ARE HUNGRY" % night, Color(1, 0.5, 0.4), 26)
	_refresh_ui()


func _end_night() -> void:
	phase = Phase.DAWN
	autotest_t = 0.0
	# the sun handles the leftovers
	for z in zombies:
		z.queue_free()
	zombies.clear()
	var burned := 0
	var lost_infected := 0
	for a in animals.duplicate():
		if a.state == AnimalScript.State.INFECTED or a.state == AnimalScript.State.CARRIED:
			lost_infected += 1
			animals.erase(a)
			a.queue_free()
		elif a.is_enemy():
			burned += 1
			animals.erase(a)
			a.queue_free()
	farmer.carrying = null
	parts += burned
	var produce := 0
	for a in animals:
		produce += a.payout()
	var bonus: int = 5 + int(stats["kills"])
	var total: int = produce + bonus
	coins += total
	if animals.is_empty():
		_game_over()
		return
	var txt := "Night %d survived.\n\n" % night
	txt += "Bitten: %d    Saved: %d    Cured: %d    Culled: %d    Turned: %d\n" % [stats["bitten"], stats["saved"], stats["cured"], stats["culled"], stats["turned"]]
	txt += "Zombies killed: %d    Zombie animals put down: %d\n" % [stats["kills"], stats["zombie_animals_killed"]]
	if lost_infected > 0:
		txt += "%d infected animal(s) didn't make it to sunrise.\n" % lost_infected
	if burned > 0:
		txt += "%d zombie animal(s) burned in the sun (+%d parts).\n" % [burned, burned]
	txt += "\nProduce from %d animals: +%d coins\nSurvival bonus: +%d coins\nTotal: +%d coins" % [animals.size(), produce, bonus, total]
	dawn_label.text = txt
	dawn_panel.visible = true
	night += 1
	_refresh_ui()


func _next_day() -> void:
	_enter_day()


func _game_over() -> void:
	phase = Phase.GAME_OVER
	over_label.text = "THE FARM IS LOST\n\nYou made it to night %d.\nThe zombies have eaten every last animal.\nGrandpa would be... well, he's a zombie too now." % night
	over_panel.visible = true
	shop_panel.visible = false
	_refresh_ui()


# ---------------------------------------------------------------- shop

func _cost(item: String) -> int:
	match item:
		"repair": return 10
		"vaccine": return 15
		"fork": return 25 * fork_level
		"fence": return 30 * fence_level
		"chicken": return 10
		"pig": return 20
		"cow": return 35
	return 0


func buy(item: String) -> void:
	if phase != Phase.DAY:
		return
	var c := _cost(item)
	if coins < c:
		popup(farmer.position + Vector2(0, -40), "not enough coins", Color(1, 0.6, 0.5))
		return
	match item:
		"repair":
			var damaged := false
			for i in SEGMENTS:
				if fence_hp[i] < fence_max:
					damaged = true
			if not damaged:
				popup(farmer.position + Vector2(0, -40), "fences are fine", Color(0.8, 0.8, 0.8))
				return
			for i in SEGMENTS:
				fence_hp[i] = fence_max
		"vaccine":
			vaccines += 1
		"fork":
			fork_level += 1
		"fence":
			fence_level += 1
			fence_max = 100.0 + 50.0 * (fence_level - 1)
			for i in SEGMENTS:
				fence_hp[i] = fence_max
		"chicken", "pig", "cow":
			_add_animal(item)
	coins -= c
	_refresh_ui()


# ---------------------------------------------------------------- player actions

func _nearest_animal(states: Array) -> Node2D:
	var best: Node2D = null
	var best_d := ACTION_RANGE * ACTION_RANGE
	for a in animals:
		if a.state in states:
			var d := farmer.position.distance_squared_to(a.position)
			if d < best_d:
				best_d = d
				best = a
	return best


func action_carry() -> void:
	if farmer.carrying:
		var a: Node2D = farmer.carrying
		farmer.carrying = null
		if BARN_RECT.grow(16).has_point(farmer.position):
			a.cure()
			a.position = BARN_RECT.get_center() + Vector2(0, 50)
			stats["saved"] += 1
			popup(a.position + Vector2(0, -30), SAVE_LINES.pick_random(), Color(0.5, 1, 0.6), 18)
		else:
			a.state = AnimalScript.State.INFECTED
			a.position = farmer.position + Vector2(18, 6)
		return
	var target := _nearest_animal([0, 1])
	if target and target.state == AnimalScript.State.INFECTED:
		target.state = AnimalScript.State.CARRIED
		farmer.carrying = target
	elif target:
		popup(farmer.position + Vector2(0, -40), "it's fine, leave it", Color(0.8, 0.8, 0.8))


func action_cure() -> void:
	var target: Node2D = farmer.carrying if farmer.carrying else _nearest_animal([1])
	if target == null:
		return
	if vaccines <= 0:
		popup(farmer.position + Vector2(0, -40), "no vaccine!", Color(1, 0.6, 0.5))
		return
	vaccines -= 1
	if farmer.carrying == target:
		farmer.carrying = null
		target.position = farmer.position + Vector2(18, 6)
	target.cure()
	stats["cured"] += 1
	popup(target.position + Vector2(0, -30), "CURED!", Color(0.5, 0.9, 1.0), 18)
	_refresh_ui()


func action_cull() -> void:
	var target: Node2D = farmer.carrying if farmer.carrying else _nearest_animal([1, 3])
	if target == null:
		return
	if farmer.carrying == target:
		farmer.carrying = null
	animals.erase(target)
	stats["culled"] += 1
	popup(target.position + Vector2(0, -30), CULL_LINES.pick_random(), Color(0.85, 0.85, 0.85))
	target.queue_free()
	_refresh_ui()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_E:
				if phase == Phase.NIGHT:
					action_carry()
			KEY_Q:
				if phase == Phase.NIGHT:
					action_cure()
			KEY_X:
				if phase == Phase.NIGHT:
					action_cull()
			KEY_SPACE, KEY_ENTER:
				if phase == Phase.DAY:
					start_night()
				elif phase == Phase.DAWN:
					_next_day()


# ---------------------------------------------------------------- main loop

func _process(delta: float) -> void:
	var target_sky := 1.0 if phase == Phase.NIGHT else 0.0
	sky = move_toward(sky, target_sky, delta * 0.8)
	if phase != Phase.GAME_OVER:
		farmer.tick(delta)
	if phase == Phase.NIGHT:
		night_time += delta
		if to_spawn > 0:
			spawn_timer -= delta
			if spawn_timer <= 0.0:
				_spawn_wave()
				spawn_timer = spawn_interval
		for z in zombies.duplicate():
			z.tick(delta)
		for a in animals.duplicate():
			a.tick(delta)
		var enemies := zombies.size()
		for a in animals:
			if a.is_enemy():
				enemies += 1
		if healthy_count() == 0 and enemies == 0:
			pass
		if night_time >= night_length or (to_spawn == 0 and enemies == 0 and night_time > 12.0):
			_end_night()
		elif animals.is_empty():
			_game_over()
		timer_label.text = "Sunrise in %ds" % int(ceil(max(0.0, night_length - night_time)))
	else:
		for a in animals:
			a.tick(delta)
	_update_hint()
	top_label.text = "Day %d   |   Coins %d   |   Vaccines %d   |   Parts %d   |   Animals %d" % [night, coins, vaccines, parts, healthy_count()]
	timer_label.visible = phase == Phase.NIGHT
	queue_redraw()
	if autotest_dir != "":
		_autotest(delta)


func _spawn_wave() -> void:
	# a horde arrives together from one side, so you can't guard everything
	var side := randi() % 4
	var waves_left: int = max(1, int(ceil((night_length * 0.7 - night_time) / spawn_interval)))
	var count: int = clampi(int(ceil(float(to_spawn) / waves_left)), 1, to_spawn)
	var names := ["NORTH", "SOUTH", "WEST", "EAST"]
	popup(PEN_CENTER + Vector2(0, -250), "Horde from the %s!" % names[side], Color(1, 0.55, 0.4), 20)
	for i in count:
		_spawn_zombie(side)
		to_spawn -= 1


func _spawn_zombie(side: int) -> void:
	var z: Node2D = ZombieScript.new()
	var jitter := randf_range(-160, 160)
	match side:
		0: z.position = Vector2(640 + jitter, 30 - randf() * 60)
		1: z.position = Vector2(640 + jitter, 750 + randf() * 60)
		2: z.position = Vector2(-20 - randf() * 60, 400 + jitter)
		_: z.position = Vector2(1300 + randf() * 60, 400 + jitter)
	entity_layer.add_child(z)
	z.setup(self, night)
	zombies.append(z)


func _update_hint() -> void:
	match phase:
		Phase.DAY:
			hint_label.text = "DAY: spend coins on the right, then press SPACE (or Start Night).   Move: WASD"
		Phase.NIGHT:
			if farmer.carrying:
				hint_label.text = "Carrying an infected animal: get to the BARN and press E to SAVE it.  Q = cure  X = cull"
			else:
				hint_label.text = "WASD move, pitchfork auto-swings.   Near a bitten animal:  E carry to barn (save)   Q vaccine (cure)   X cull"
		Phase.DAWN:
			hint_label.text = "DAWN: press SPACE for the next day"
		Phase.GAME_OVER:
			hint_label.text = ""


func _draw() -> void:
	var day_grass := Color(0.47, 0.66, 0.3)
	var night_grass := Color(0.11, 0.17, 0.2)
	var grass := day_grass.lerp(night_grass, sky)
	draw_rect(Rect2(0, 0, 1280, 720), grass)
	# crop rows outside the pen
	var crop := Color(0.36, 0.52, 0.22).lerp(Color(0.08, 0.13, 0.14), sky)
	for row in 6:
		draw_rect(Rect2(40, 90 + row * 34, 300, 14), crop)
		draw_rect(Rect2(940, 90 + row * 34, 300, 14), crop)
	# pen dirt
	draw_circle(PEN_CENTER, PEN_RADIUS, Color(0.62, 0.5, 0.33).lerp(Color(0.18, 0.17, 0.17), sky))
	# fence segments
	for i in SEGMENTS:
		var a0 := float(i) / SEGMENTS * TAU
		var a1 := float(i + 1) / SEGMENTS * TAU
		var r := fence_hp[i] / fence_max
		if fence_hp[i] <= 0.0:
			draw_arc(PEN_CENTER, PEN_RADIUS, a0 + 0.08, a1 - 0.08, 6, Color(0.9, 0.3, 0.2, 0.35), 2.0)
		else:
			var col := Color(0.85, 0.25, 0.2).lerp(Color(0.6, 0.42, 0.22), r)
			draw_arc(PEN_CENTER, PEN_RADIUS, a0 + 0.02, a1 - 0.02, 10, col, 3.0 + 5.0 * r)
			for k in 3:
				var ak := lerpf(a0, a1, (k + 0.5) / 3.0)
				draw_circle(PEN_CENTER + Vector2.from_angle(ak) * PEN_RADIUS, 4.0, col.darkened(0.3))
	# barn
	var b := BARN_RECT
	draw_rect(b, Color(0.7, 0.18, 0.15))
	draw_colored_polygon(PackedVector2Array([b.position, b.position + Vector2(b.size.x, 0), b.position + Vector2(b.size.x / 2, -26)]), Color(0.45, 0.12, 0.1))
	draw_rect(Rect2(b.position + Vector2(30, 28), Vector2(24, 36)), Color(0.95, 0.92, 0.85))
	draw_line(b.position + Vector2(30, 28), b.position + Vector2(54, 64), Color(0.7, 0.18, 0.15), 2.0)
	draw_line(b.position + Vector2(54, 28), b.position + Vector2(30, 64), Color(0.7, 0.18, 0.15), 2.0)
	draw_string(ThemeDB.fallback_font, b.position + Vector2(18, 20), "BARN", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 0.95, 0.85))
	if farmer.carrying:
		draw_rect(b.grow(16), Color(0.5, 1, 0.6, 0.35 + 0.25 * sin(Time.get_ticks_msec() / 150.0)), false, 3.0)
	# moon / sun
	draw_circle(Vector2(1180, 60).lerp(Vector2(1180, 120), sky), 26, Color(1, 0.85, 0.3).lerp(Color(0.85, 0.9, 1.0), sky))


# ---------------------------------------------------------------- UI

func _panel(pos: Vector2, size: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	p.position = pos
	p.size = size
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.07, 0.06, 0.88)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(14)
	sb.border_color = Color(0.85, 0.7, 0.3)
	sb.set_border_width_all(2)
	p.add_theme_stylebox_override("panel", sb)
	ui.add_child(p)
	return p


func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	top_label = Label.new()
	top_label.position = Vector2(16, 10)
	top_label.add_theme_font_size_override("font_size", 20)
	top_label.add_theme_color_override("font_outline_color", Color.BLACK)
	top_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(top_label)

	var title := Label.new()
	title.text = "DEAD STOCK"
	title.position = Vector2(16, 36)
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.75, 1.0, 0.5))
	ui.add_child(title)

	timer_label = Label.new()
	timer_label.position = Vector2(560, 60)
	timer_label.add_theme_font_size_override("font_size", 22)
	timer_label.add_theme_color_override("font_outline_color", Color.BLACK)
	timer_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(timer_label)

	hint_label = Label.new()
	hint_label.position = Vector2(16, 690)
	hint_label.add_theme_font_size_override("font_size", 15)
	hint_label.add_theme_color_override("font_outline_color", Color.BLACK)
	hint_label.add_theme_constant_override("outline_size", 5)
	ui.add_child(hint_label)

	shop_panel = _panel(Vector2(1000, 150), Vector2(260, 0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	shop_panel.add_child(v)
	var head := Label.new()
	head.text = "FARM STORE"
	head.add_theme_font_size_override("font_size", 18)
	head.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	v.add_child(head)
	for item in ["repair", "vaccine", "fork", "fence", "chicken", "pig", "cow"]:
		var btn := Button.new()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(buy.bind(item))
		btn.focus_mode = Control.FOCUS_NONE
		v.add_child(btn)
		shop_buttons[item] = btn
	var start := Button.new()
	start.text = "START NIGHT  (Space)"
	start.focus_mode = Control.FOCUS_NONE
	start.add_theme_font_size_override("font_size", 18)
	start.pressed.connect(start_night)
	v.add_child(start)

	dawn_panel = _panel(Vector2(340, 170), Vector2(600, 0))
	var dv := VBoxContainer.new()
	dawn_panel.add_child(dv)
	var dh := Label.new()
	dh.text = "SUNRISE"
	dh.add_theme_font_size_override("font_size", 26)
	dh.add_theme_color_override("font_color", Color(1, 0.8, 0.3))
	dv.add_child(dh)
	dawn_label = Label.new()
	dawn_label.add_theme_font_size_override("font_size", 16)
	dv.add_child(dawn_label)
	var nb := Button.new()
	nb.text = "NEXT DAY  (Space)"
	nb.focus_mode = Control.FOCUS_NONE
	nb.pressed.connect(_next_day)
	dv.add_child(nb)
	dawn_panel.visible = false

	over_panel = _panel(Vector2(340, 220), Vector2(600, 0))
	var ov := VBoxContainer.new()
	over_panel.add_child(ov)
	over_label = Label.new()
	over_label.add_theme_font_size_override("font_size", 20)
	ov.add_child(over_label)
	var rb := Button.new()
	rb.text = "START A NEW FARM"
	rb.focus_mode = Control.FOCUS_NONE
	rb.pressed.connect(_new_game)
	ov.add_child(rb)
	over_panel.visible = false


func _refresh_ui() -> void:
	if shop_buttons.is_empty():
		return
	var names := {
		"repair": "Repair all fences",
		"vaccine": "Vaccine dart (have %d)" % vaccines,
		"fork": "Sharper pitchfork (Lv %d)" % fork_level,
		"fence": "Stronger fences (Lv %d)" % fence_level,
		"chicken": "Buy a chicken (+3/day)",
		"pig": "Buy a pig (+6/day)",
		"cow": "Buy a cow (+10/day)",
	}
	for item in shop_buttons:
		var btn: Button = shop_buttons[item]
		btn.text = "%s  -  %d" % [names[item], _cost(item)]
		btn.disabled = coins < _cost(item)


# ---------------------------------------------------------------- autotest bot (headless checks only)

func _shot(name: String) -> void:
	if autotest_shots.has(name):
		return
	autotest_shots[name] = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(autotest_dir.path_join(name + ".png"))
	print("[autotest] shot ", name, " night=", night, " coins=", coins, " animals=", animals.size(), " zombies=", zombies.size())


func _autotest(delta: float) -> void:
	autotest_t += delta
	match phase:
		Phase.DAY:
			if autotest_t > 1.0:
				_shot("day%d" % night)
			if autotest_t > 1.5:
				if coins >= _cost("vaccine"):
					buy("vaccine")
				autotest_t = 0.0
				start_night()
		Phase.NIGHT:
			if night_time > 18.0:
				_shot("night%d" % night)
			# deal with the bitten first, then fight
			var bitten := _nearest_any_infected()
			if farmer.carrying:
				farmer.bot_input = (BARN_RECT.get_center() - farmer.position).normalized()
				if BARN_RECT.has_point(farmer.position):
					action_carry()
			elif bitten:
				if farmer.position.distance_to(bitten.position) < ACTION_RANGE - 4:
					if vaccines > 0:
						action_cure()
					elif randf() < 0.5:
						action_carry()
					else:
						action_cull()
				else:
					farmer.bot_input = (bitten.position - farmer.position).normalized()
			else:
				var e := nearest_enemy(farmer.position, 2000.0)
				if e and farmer.position.distance_to(e.position) > 50.0:
					farmer.bot_input = (e.position - farmer.position).normalized()
				else:
					farmer.bot_input = Vector2.ZERO
		Phase.DAWN:
			farmer.bot_input = Vector2.ZERO
			_shot("dawn%d" % (night - 1))
			if autotest_t > 2.0:
				autotest_t = 0.0
				if night > 3:
					print("[autotest] done")
					get_tree().quit()
				else:
					_next_day()
		Phase.GAME_OVER:
			_shot("gameover")
			if autotest_t > 2.0:
				print("[autotest] game over at night ", night)
				get_tree().quit()


func _nearest_any_infected() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for a in animals:
		if a.state == AnimalScript.State.INFECTED:
			var d := farmer.position.distance_squared_to(a.position)
			if d < best_d:
				best_d = d
				best = a
	return best
