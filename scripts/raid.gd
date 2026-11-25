extends Node2D
## Rival farm raid: the release-1 stand-in for PvP. You attack a prebuilt rival farm with the
## livestock you trained (plus chained Dead Stock undead). Opened by main.gd as an overlay.
##
## Rules (design doc, "Release 1 PvP"): deploy from outside the fence, 120 s, 1-3 stars,
## loot from destroyed buildings, units that die are gone for good. Rivals rebuild every week.

signal finished(result: Dictionary)

const C := Vector2(360, 540)
const R := 190.0
const SEG := 12
const RAID_TIME := 120.0
const DEPLOY_MARGIN := 34.0

## Unit roles from the economy/combat reports: chicken = kamikaze, pig = melee DPS,
## cow = tank, undead = chained zombie animal (hits buildings hard, no feed).
const UNIT := {
	"chicken": {"label": "Hen bomber", "hp": 26.0, "dmg": 75.0, "rate": 0.0, "speed": 95.0, "range": 16.0, "r": 8.0, "color": Color(0.98, 0.93, 0.55)},
	"pig": {"label": "Pig brawler", "hp": 95.0, "dmg": 14.0, "rate": 0.5, "speed": 70.0, "range": 18.0, "r": 12.0, "color": Color(0.96, 0.66, 0.7)},
	"cow": {"label": "Cow tank", "hp": 280.0, "dmg": 9.0, "rate": 0.6, "speed": 44.0, "range": 20.0, "r": 16.0, "color": Color(0.95, 0.95, 0.92)},
	"undead": {"label": "Dead Stock", "hp": 140.0, "dmg": 16.0, "rate": 0.5, "speed": 55.0, "range": 18.0, "r": 13.0, "color": Color(0.72, 0.66, 0.86)},
}
const UNIT_ORDER := ["chicken", "pig", "cow", "undead"]

## Prebuilt rival farms. unlock = the night you must have reached. Buildings: [name, angle deg, dist, hp, loot share]
const RIVALS := [
	{"name": "Hog Heaven Retirement Ranch", "owner": "Grandpa Hogg", "unlock": 1, "fence": 55.0, "gaps": 3, "guards": 2, "loot": 60,
		"color": Color(0.55, 0.75, 0.95), "taunt": "These hogs are retired. Mostly.",
		"buildings": [["Silo", 0, 0, 260, 0.4], ["Coop", 140, 95, 160, 0.3], ["Shed", 320, 100, 140, 0.3]]},
	{"name": "Possum Hollow Feed Lot", "owner": "the Possum Twins", "unlock": 3, "fence": 100.0, "gaps": 1, "guards": 4, "loot": 120,
		"color": Color(0.9, 0.6, 0.3), "taunt": "The twins say you smell like a cow.",
		"buildings": [["Silo", 0, 0, 340, 0.35], ["Barn", 90, 100, 300, 0.25], ["Trough", 210, 105, 150, 0.15], ["Shed", 320, 100, 170, 0.25]]},
	{"name": "GRO-GLO Feed Co. Depot", "owner": "Barron Gristle's interns", "unlock": 5, "fence": 150.0, "gaps": 1, "guards": 6, "loot": 200,
		"color": Color(0.84, 1.0, 0.25), "taunt": "Glo-Corn: now with 40% more glow.",
		"buildings": [["Silo", 0, 0, 420, 0.3], ["Warehouse", 60, 105, 380, 0.25], ["Feed Truck", 180, 110, 240, 0.2], ["Office", 300, 105, 260, 0.25]]},
	{"name": "Mort Muckridge's Rotten Acres", "owner": "Mort Muckridge", "unlock": 7, "fence": 210.0, "gaps": 0, "guards": 8, "loot": 320,
		"color": Color(0.85, 0.3, 0.35), "taunt": "Mort is still mad about the pie contest.",
		"buildings": [["Silo", 0, 0, 520, 0.3], ["Barn", 40, 110, 420, 0.2], ["Pie Stand", 130, 105, 260, 0.15], ["Coop", 220, 110, 280, 0.15], ["Outhouse", 310, 108, 200, 0.2]]},
]

var rival: Dictionary
var rival_idx := 0
var week := 0
var army := {}            # kind -> count still waiting to deploy
var army_start := {}
var selected := "pig"
var units: Array = []     # {kind, pos, hp, max, cd, alive}
var guards: Array = []    # {pos, home, hp, max, cd, alive}
var buildings: Array = [] # {name, pos, size, hp, max, loot, silo, alive}
var fence_hp: Array = []
var fence_max := 100.0
var t := 0.0
var done := false
var loot_got := 0
var popups: Array = []
var auto := false         # autotest bot deploys by itself
var auto_t := 0.0
var lost := {}
var rng := RandomNumberGenerator.new()

var cam: Camera2D
var ui: CanvasLayer
var top_label: Label
var unit_buttons := {}
var result_panel: PanelContainer
var result_label: Label
var result: Dictionary = {}


func setup(idx: int, the_army: Dictionary, the_week: int) -> void:
	rival_idx = idx
	rival = RIVALS[idx]
	week = the_week
	for k in UNIT_ORDER:
		army[k] = int(the_army.get(k, 0))
		lost[k] = 0
	army_start = army.duplicate()
	for k in UNIT_ORDER:
		if army[k] > 0:
			selected = k
			break
	_build_farm()


func _build_farm() -> void:
	## rivals rebuild every week: the seed changes, so gaps, building spots and guards shift
	rng.seed = hash(rival["name"]) + week * 7919
	var scale := 1.0 + 0.12 * week
	fence_max = float(rival["fence"]) * scale
	fence_hp.clear()
	for i in SEG:
		fence_hp.append(fence_max)
	var gaps: int = int(rival["gaps"])
	for g in gaps:
		fence_hp[rng.randi_range(0, SEG - 1)] = 0.0
	var spin := rng.randf_range(-25.0, 25.0)
	for b in rival["buildings"]:
		var ang := deg_to_rad(float(b[1]) + spin + rng.randf_range(-12.0, 12.0))
		var dist: float = float(b[2])
		var pos := C + Vector2.from_angle(ang) * dist
		var hp: float = float(b[3]) * scale
		buildings.append({"name": b[0], "pos": pos, "size": Vector2(64, 48) if b[0] != "Silo" else Vector2(52, 70),
			"hp": hp, "max": hp, "loot": int(round(float(rival["loot"]) * float(b[4]))), "silo": b[0] == "Silo", "alive": true})
	var n: int = int(rival["guards"]) + week / 2
	for i in n:
		var home := C + Vector2.from_angle(TAU * i / n + rng.randf()) * rng.randf_range(40.0, 140.0)
		var ghp := 70.0 * scale
		guards.append({"pos": home, "home": home, "hp": ghp, "max": ghp, "cd": 0.0, "alive": true})


func _ready() -> void:
	cam = Camera2D.new()
	cam.position = Vector2(360, 640)
	add_child(cam)
	cam.make_current()
	_build_ui()
	_popup(C + Vector2(0, -250), rival["taunt"], Color(1, 0.85, 0.5))


# ---------------------------------------------------------------- simulation

func _process(delta: float) -> void:
	if not done:
		t += delta
		if auto:
			_auto_deploy(delta)
		_step(delta)
		if t >= RAID_TIME or _destruction() >= 0.999 or (_units_alive() == 0 and _waiting() == 0 and t > 1.0):
			_finish()
	for p in popups:
		p["age"] += delta
		p["pos"] = p["pos"] + Vector2(0, -24.0 * delta)
	popups = popups.filter(func(p): return p["age"] < 1.6)
	_refresh_ui()
	queue_redraw()


func _step(dt: float) -> void:
	for u in units:
		if not u["alive"]:
			continue
		var spec: Dictionary = UNIT[u["kind"]]
		u["cd"] = max(0.0, float(u["cd"]) - dt)
		# 1) a guard close by? fight it
		var g = _nearest(guards, u["pos"], 70.0)
		if g != null:
			_attack_or_move(u, spec, g, dt, "guard")
			continue
		# 2) otherwise go for the nearest building
		var b = _nearest(buildings, u["pos"], 9999.0)
		if b == null:
			continue
		_attack_or_move(u, spec, b, dt, "building")
	for g in guards:
		if not g["alive"]:
			continue
		g["cd"] = max(0.0, float(g["cd"]) - dt)
		var u = _nearest(units, g["pos"], 130.0)
		if u != null and u["pos"].distance_to(C) < R + 60.0:
			var d: float = g["pos"].distance_to(u["pos"])
			if d > 20.0:
				g["pos"] = g["pos"].move_toward(u["pos"], 62.0 * dt)
			elif g["cd"] <= 0.0:
				_hurt_unit(u, 10.0)
				g["cd"] = 0.6
		else:
			g["pos"] = g["pos"].move_toward(g["home"], 40.0 * dt)


func _attack_or_move(u: Dictionary, spec: Dictionary, target: Dictionary, dt: float, kind: String) -> void:
	var tpos: Vector2 = target["pos"]
	var reach: float = float(spec["range"]) + (float(target["size"].x) * 0.5 if kind == "building" else 10.0)
	var d: float = u["pos"].distance_to(tpos)
	if d <= reach:
		_hit(u, spec, target, kind)
		return
	var next: Vector2 = u["pos"].move_toward(tpos, float(spec["speed"]) * dt)
	# crossing into the farm? an intact fence section stops you until you break it
	var r_now: float = u["pos"].distance_to(C)
	var r_next := next.distance_to(C)
	if r_now >= R and r_next < R:
		var seg := _segment_at(u["pos"])
		if fence_hp[seg] > 0.0:
			_hit(u, spec, {"fence": seg}, "fence")
			return
	u["pos"] = next


func _hit(u: Dictionary, spec: Dictionary, target: Dictionary, kind: String) -> void:
	if float(spec["rate"]) <= 0.0:
		# kamikaze hen: one big boom, area damage, the hen goes to a farm upstate
		_boom(u["pos"], float(spec["dmg"]))
		u["alive"] = false
		lost[u["kind"]] += 1
		_popup(u["pos"], "BAWK-BOOM!", Color(1, 0.8, 0.3))
		return
	if u["cd"] > 0.0:
		return
	u["cd"] = float(spec["rate"])
	var dmg: float = float(spec["dmg"]) * float(spec["rate"]) * 2.0
	if u["kind"] == "undead" and kind == "building":
		dmg *= 1.5
	match kind:
		"guard":
			_hurt_guard(target, dmg)
		"building":
			_hurt_building(target, dmg)
		"fence":
			_hurt_fence(int(target["fence"]), dmg)


func _boom(pos: Vector2, dmg: float) -> void:
	for b in buildings:
		if b["alive"] and b["pos"].distance_to(pos) < 70.0:
			_hurt_building(b, dmg)
	for g in guards:
		if g["alive"] and g["pos"].distance_to(pos) < 60.0:
			_hurt_guard(g, dmg)
	if absf(pos.distance_to(C) - R) < 40.0:
		_hurt_fence(_segment_at(pos), dmg * 1.5)


func _hurt_unit(u: Dictionary, dmg: float) -> void:
	u["hp"] -= dmg
	if u["hp"] <= 0.0 and u["alive"]:
		u["alive"] = false
		lost[u["kind"]] += 1
		_popup(u["pos"], "sent upstate", Color(0.85, 0.85, 0.85))


func _hurt_guard(g: Dictionary, dmg: float) -> void:
	g["hp"] -= dmg
	if g["hp"] <= 0.0 and g["alive"]:
		g["alive"] = false
		_popup(g["pos"], "BONK", Color(1, 1, 0.6))


func _hurt_building(b: Dictionary, dmg: float) -> void:
	if not b["alive"]:
		return
	b["hp"] -= dmg
	if b["hp"] <= 0.0:
		b["alive"] = false
		loot_got += int(b["loot"])
		_popup(b["pos"], "%s flattened! +%d" % [b["name"], b["loot"]], Color(1, 0.85, 0.3))


func _hurt_fence(seg: int, dmg: float) -> void:
	if fence_hp[seg] <= 0.0:
		return
	fence_hp[seg] = max(0.0, fence_hp[seg] - dmg)
	if fence_hp[seg] <= 0.0:
		_popup(C + Vector2.from_angle((seg + 0.5) / SEG * TAU) * R, "fence down", Color(1, 0.6, 0.4))


func _nearest(list: Array, pos: Vector2, max_d: float):
	var best = null
	var best_d := max_d
	for e in list:
		if not e["alive"]:
			continue
		var d: float = pos.distance_to(e["pos"])
		if d < best_d:
			best_d = d
			best = e
	return best


func _segment_at(pos: Vector2) -> int:
	var ang := fposmod((pos - C).angle(), TAU)
	return int(floor(ang / TAU * SEG)) % SEG


func _destruction() -> float:
	var total := 0.0
	var gone := 0.0
	for b in buildings:
		total += float(b["max"])
		if not b["alive"]:
			gone += float(b["max"])
	return gone / total if total > 0.0 else 0.0


func _stars() -> int:
	var s := 0
	var pct := _destruction()
	if pct >= 0.5:
		s += 1
	for b in buildings:
		if b["silo"] and not b["alive"]:
			s += 1
	if pct >= 0.999:
		s += 1
	return s


func _units_alive() -> int:
	var n := 0
	for u in units:
		if u["alive"]:
			n += 1
	return n


func _waiting() -> int:
	var n := 0
	for k in UNIT_ORDER:
		n += int(army[k])
	return n


# ---------------------------------------------------------------- deploy

func can_deploy_at(world: Vector2) -> bool:
	return world.distance_to(C) > R + DEPLOY_MARGIN and world.y > 120.0 and world.y < 1000.0


func deploy(kind: String, world: Vector2) -> bool:
	if done or int(army.get(kind, 0)) <= 0 or not can_deploy_at(world):
		return false
	army[kind] -= 1
	var spec: Dictionary = UNIT[kind]
	units.append({"kind": kind, "pos": world, "hp": float(spec["hp"]), "max": float(spec["hp"]), "cd": 0.0, "alive": true})
	return true


func _auto_deploy(delta: float) -> void:
	auto_t -= delta
	if auto_t > 0.0:
		return
	auto_t = 0.35
	for k in ["cow", "undead", "pig", "chicken"]:
		if army[k] > 0:
			var ang := deg_to_rad(90.0 + randf_range(-35.0, 35.0))
			deploy(k, C + Vector2.from_angle(ang) * (R + 70.0))
			return


func _unhandled_input(event: InputEvent) -> void:
	if done:
		return
	if event is InputEventScreenTouch and event.pressed:
		var world: Vector2 = get_canvas_transform().affine_inverse() * event.position
		if not deploy(selected, world):
			if int(army.get(selected, 0)) <= 0:
				_popup(world, "none left", Color(1, 0.6, 0.5))
			elif not can_deploy_at(world):
				_popup(world, "deploy outside the fence", Color(1, 0.6, 0.5))


func retreat() -> void:
	_finish()


func _finish() -> void:
	if done:
		return
	done = true
	var stars := _stars()
	var pct := _destruction()
	var bonus := stars * 10
	var survivors := {}
	for k in UNIT_ORDER:
		survivors[k] = int(army[k])  # never deployed
	for u in units:
		if u["alive"]:
			survivors[u["kind"]] += 1
	result = {"rival": rival_idx, "stars": stars, "pct": pct, "loot": loot_got + bonus, "survivors": survivors, "lost": lost.duplicate()}
	var lost_txt: Array = []
	for k in UNIT_ORDER:
		if lost[k] > 0:
			lost_txt.append("%d %s" % [lost[k], UNIT[k]["label"]])
	result_label.text = "%s\n%s   %d%% flattened\n\nLoot +%d coins (stars +%d)\nRibbons +%d\nLost for good: %s" % [
		"RAID OVER" if stars > 0 else "REPELLED", "*".repeat(stars) + "-".repeat(3 - stars), int(round(pct * 100.0)),
		loot_got + bonus, bonus, stars * 10, ", ".join(lost_txt) if not lost_txt.is_empty() else "nobody"]
	result_panel.visible = true


func _back() -> void:
	finished.emit(result)


# ---------------------------------------------------------------- UI and drawing

func _popup(pos: Vector2, text: String, color: Color) -> void:
	popups.append({"pos": pos, "text": text, "color": color, "age": 0.0})


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 58)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 16)
	b.pressed.connect(cb)
	return b


func _style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.07, 0.06, 0.9)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(10)
	sb.border_color = Color(0.85, 0.7, 0.3)
	sb.set_border_width_all(2)
	return sb


func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	top_label = Label.new()
	top_label.position = Vector2(16, 12)
	top_label.add_theme_font_size_override("font_size", 18)
	top_label.add_theme_color_override("font_outline_color", Color.BLACK)
	top_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(top_label)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 1040)
	panel.size = Vector2(696, 228)
	panel.add_theme_stylebox_override("panel", _style())
	ui.add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	var hint := Label.new()
	hint.text = "Pick a unit, then tap outside the fence to drop it in. Units that die are gone for good."
	hint.add_theme_font_size_override("font_size", 14)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.custom_minimum_size = Vector2(670, 0)
	v.add_child(hint)
	var grid := GridContainer.new()
	grid.columns = 4
	v.add_child(grid)
	for k in UNIT_ORDER:
		var b := _button("", func(): selected = k)
		grid.add_child(b)
		unit_buttons[k] = b
	v.add_child(_button("RETREAT (keep what you've looted)", retreat))
	result_panel = PanelContainer.new()
	result_panel.position = Vector2(60, 330)
	result_panel.size = Vector2(600, 0)
	result_panel.add_theme_stylebox_override("panel", _style())
	ui.add_child(result_panel)
	var rv := VBoxContainer.new()
	result_panel.add_child(rv)
	result_label = Label.new()
	result_label.add_theme_font_size_override("font_size", 22)
	result_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	result_label.custom_minimum_size = Vector2(570, 0)
	rv.add_child(result_label)
	rv.add_child(_button("BACK TO THE FARM", _back))
	result_panel.visible = false


func _refresh_ui() -> void:
	top_label.text = "RAID: %s (week %d)\nOwner: %s   Time %ds   Flattened %d%%   Stars %d" % [
		rival["name"], week + 1, rival["owner"], int(ceil(max(0.0, RAID_TIME - t))), int(round(_destruction() * 100.0)), _stars()]
	for k in UNIT_ORDER:
		var b: Button = unit_buttons[k]
		b.text = "%s\nx%d" % [UNIT[k]["label"], army[k]]
		b.disabled = army[k] <= 0 or done
		b.modulate = Color(1, 0.9, 0.4) if k == selected else Color.WHITE


func _draw() -> void:
	draw_rect(Rect2(0, 0, 720, 1280), Color(0.45, 0.62, 0.3))
	for row in 5:
		draw_rect(Rect2(30, 150 + row * 30, 160, 12), Color(0.36, 0.52, 0.22))
		draw_rect(Rect2(530, 150 + row * 30, 160, 12), Color(0.36, 0.52, 0.22))
	# deploy zone hint
	draw_arc(C, R + DEPLOY_MARGIN, 0, TAU, 64, Color(1, 1, 1, 0.25), 2.0)
	draw_circle(C, R, Color(0.6, 0.48, 0.32))
	var col: Color = rival["color"]
	for i in SEG:
		var a0 := float(i) / SEG * TAU
		var a1 := float(i + 1) / SEG * TAU
		if fence_hp[i] <= 0.0:
			draw_arc(C, R, a0 + 0.08, a1 - 0.08, 6, Color(0.9, 0.3, 0.2, 0.3), 2.0)
		else:
			var r: float = fence_hp[i] / fence_max
			draw_arc(C, R, a0 + 0.02, a1 - 0.02, 10, Color(0.85, 0.25, 0.2).lerp(Color(0.5, 0.36, 0.2), r), 3.0 + 5.0 * r)
	var font := ThemeDB.fallback_font
	for b in buildings:
		var sz: Vector2 = b["size"]
		var rect := Rect2(b["pos"] - sz / 2.0, sz)
		if b["alive"]:
			draw_rect(rect, Color(0.62, 0.2, 0.17) if not b["silo"] else Color(0.75, 0.75, 0.7))
			draw_rect(Rect2(rect.position + Vector2(0, -6), Vector2(sz.x, 6)), col)
			draw_rect(Rect2(rect.position + Vector2(0, sz.y + 4), Vector2(sz.x, 5)), Color(0, 0, 0, 0.5))
			draw_rect(Rect2(rect.position + Vector2(0, sz.y + 4), Vector2(sz.x * float(b["hp"]) / float(b["max"]), 5)), Color(0.95, 0.75, 0.2))
		else:
			draw_rect(rect, Color(0.3, 0.25, 0.2, 0.6))
		draw_string(font, rect.position + Vector2(2, sz.y / 2 + 5), b["name"], HORIZONTAL_ALIGNMENT_LEFT, sz.x + 30, 12, Color(1, 1, 1, 0.9))
	for g in guards:
		if not g["alive"]:
			continue
		draw_circle(g["pos"] + Vector2(0, 8), 10, Color(0, 0, 0, 0.2))
		draw_circle(g["pos"], 12, Color(0.62, 0.55, 0.45))
		draw_rect(Rect2(g["pos"] + Vector2(-9, -8), Vector2(18, 4)), col)  # rival bandana
		draw_circle(g["pos"] + Vector2(5, -3), 2, Color.BLACK)
	for u in units:
		if not u["alive"]:
			continue
		var spec: Dictionary = UNIT[u["kind"]]
		var r: float = spec["r"]
		draw_circle(u["pos"] + Vector2(0, r * 0.7), r * 0.9, Color(0, 0, 0, 0.2))
		draw_circle(u["pos"], r, spec["color"])
		var eye := Color(1, 0.2, 0.15) if u["kind"] == "undead" else Color(0.1, 0.1, 0.1)
		draw_circle(u["pos"] + Vector2(r * 0.35, -r * 0.3), 2.2, eye)
		draw_rect(Rect2(u["pos"] + Vector2(-r, -r - 7), Vector2(2 * r, 3)), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(u["pos"] + Vector2(-r, -r - 7), Vector2(2 * r * float(u["hp"]) / float(u["max"]), 3)), Color(0.4, 0.9, 0.4))
	for p in popups:
		var a := 1.0 - clampf((p["age"] - 1.0) / 0.6, 0.0, 1.0)
		var w := font.get_string_size(p["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		draw_string_outline(font, p["pos"] - Vector2(w / 2, 0), p["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color(0, 0, 0, a))
		draw_string(font, p["pos"] - Vector2(w / 2, 0), p["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(p["color"], a))
