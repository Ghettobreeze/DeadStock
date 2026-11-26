extends Node2D
## Fence Fixer prototype (T-4). Loads res://data/fence_fixer_pack1.json and plays levels in a simple
## placement-then-watch mode, portrait 720x1280. The night itself is ff_sim.gd (deterministic, 15 Hz).
##
## Command line (after --):
##   --verify[=out.md]   headless: run every level's scripted solution, an empty-board baseline and
##                       single-piece ablations; print [verify] lines and write a markdown table
##   --shots=DIR         rendered screenshots (run under xvfb-run) of a few levels
##   --level=N           start on level N        --all   unlock levels 11-30 (default: 1-10 only)

const Sim := preload("res://scripts/ff_sim.gd")
const PACK := "res://data/fence_fixer_pack1.json"
const PLAYABLE := 10

enum Mode { PREP, NIGHT, RESULT }

signal exited(best: Dictionary)
var embedded := false        # opened from the farm (main.gd) as a minigame overlay
var best := {}               # level index -> best stars this session (and earlier, passed in)
var peeked := {}             # level index -> true once "Peek" showed the solution (no stars recorded after that)

var levels: Array = []
var li := 0
var max_level := PLAYABLE
var mode := Mode.PREP
var sim: Sim
var placement := {"farmer": "c", "pieces": []}
var selected := "wood"
var acc := 0.0
var speed := 1
var popups: Array = []
var cam: Camera2D
var ui: CanvasLayer
var title_label: Label
var info_label: Label
var rule_label: Label
var palette: GridContainer
var start_btn: Button
var result_panel: PanelContainer
var result_label: Label
var shots_dir := ""
var verify_out := ""
var search_mode := false
var search_ids: Array = []
const SEARCH_CAP := 200000
var sample_n := 0
var lim_override := -1


func _ready() -> void:
	var raw := FileAccess.get_file_as_string(PACK)
	var data = JSON.parse_string(raw)
	levels = data["levels"]
	var start := 1
	if embedded:
		for k in best.keys():
			if int(best[k]) > 0:
				start = max(start, min(PLAYABLE, int(k) + 2))
	var verify := false
	var try_id := 0
	var try_pl := ""
	for a in ([] if embedded else OS.get_cmdline_user_args()):
		if a.begins_with("--search"):
			search_ids = Array(a.trim_prefix("--search=").split(",")) if a.contains("=") else []
			search_mode = true
		elif a.begins_with("--sample="):
			sample_n = int(a.trim_prefix("--sample="))
		elif a.begins_with("--lim="):
			lim_override = int(a.trim_prefix("--lim="))
		elif a.begins_with("--try="):
			try_id = int(a.trim_prefix("--try="))
		elif a.begins_with("--pl="):
			try_pl = a.trim_prefix("--pl=")
		if a.begins_with("--verify"):
			verify = true
			verify_out = a.trim_prefix("--verify=") if a.contains("=") else ""
		elif a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")
		elif a.begins_with("--level="):
			start = int(a.trim_prefix("--level="))
		elif a == "--all":
			max_level = levels.size()
	if search_mode:
		_search_all()
		get_tree().quit()
		return
	if try_id > 0:
		_try(try_id, try_pl)
		get_tree().quit()
		return
	if verify:
		_verify()
		get_tree().quit()
		return
	get_tree().root.content_scale_size = Vector2i(720, 1280)
	cam = Camera2D.new()
	cam.position = Sim.C + Vector2(0, 160)
	cam.zoom = Vector2(0.86, 0.86)  # whole far-lane ring (r 330) fits the 720 px portrait width
	add_child(cam)
	cam.make_current()
	_build_ui()
	_load_level(clampi(start, 1, max_level) - 1)
	if shots_dir != "":
		_shots()


# ---------------------------------------------------------------- headless verification

func _run(lv: Dictionary, pl: Dictionary) -> Dictionary:
	var s := Sim.new()
	s.setup(lv, pl)
	return s.run_to_end()


func _search_all() -> void:
	## exhaustive search over "relevant" slots (wave lanes, gaps, centre) up to the level budget
	for lv in levels:
		if not search_ids.is_empty() and not str(int(lv["id"])) in search_ids:
			continue
		var hours := {}
		for w in lv["waves"]:
			hours[int(w["hour"])] = true
		var gaps := {}
		var fs: String = lv["fences"]
		for h in 12:
			if fs.substr(h, 1) == ".":
				gaps[h] = true
		var opts: Array = []
		for p in lv["pieces"].keys():
			if p in ["farmer", "dart"]:
				continue
			for ring in Sim.PIECES[p]["rings"]:
				if ring == "c":
					opts.append({"piece": p, "slot": "c"})
					continue
				var hs: Dictionary = hours.duplicate()
				if ring == "f":
					hs.merge(gaps)
				for h in hs.keys():
					opts.append({"piece": p, "slot": ring + str(h)})
		var farmers: Array = []
		if lv.get("farmer_locked", false):
			farmers = [lv.get("farmer", "c")]
		else:
			farmers = ["c"]
			for h in hours.keys():
				farmers.append("p" + str(h))
		var max_darts: int = int(lv["pieces"].get("dart", 0))
		var combos: Array = []
		var lim: int = mini(int(lv["budget"]), int(lv["three_star"].get("value", lv["budget"])))
		if lim_override >= 0:
			lim = mini(int(lv["budget"]), lim_override)
		_dfs(lv, opts, 0, [], 0, combos, lim)
		if sample_n > 0 and combos.size() > sample_n:
			seed(4242)
			combos.shuffle()
			combos = combos.slice(0, sample_n)
		var top: Array = []
		var n := 0
		var n3 := 0
		var best3 := 999
		var best3_pl := {}
		var best_keep := 999
		var best_keep_pl := {}
		var truncated := false
		for fm in farmers:
			for combo in combos:
				for d in max_darts + 1:
					var pcs: Array = combo.duplicate()
					for k in d:
						pcs.append({"piece": "dart"})
					var pl := {"farmer": fm, "pieces": pcs}
					if Sim.validate(lv, pl) != "":
						continue
					n += 1
					if n > SEARCH_CAP:
						truncated = true
						break
					var r := _run(lv, pl)
					if r["stars"] >= 2 and top.size() < 400:
						top.append([r["stars"], r["spent"], r["zombies_left"], JSON.stringify(pl)])
					if r["stars"] >= 2 and r["spent"] < best_keep:
						best_keep = r["spent"]
						best_keep_pl = pl
					if r["stars"] == 3:
						n3 += 1
						if r["spent"] < best3:
							best3 = r["spent"]
							best3_pl = pl
		var tr: Dictionary = lv["three_star"]
		var sol_cost := Sim.cost_of(lv["solution"])
		var flag := "ok"
		if tr["rule"] == "budget" and best_keep < int(tr["value"]):
			flag = "LOOSE (keep-all cheaper than 3-star budget)"
		if best3 < sol_cost:
			flag += " / cheaper 3-star than authored"
		print("[search] L%02d evaluated=%d%s three_star=%d cheapest3=%d cheapest_keep_all=%d authored=%d rule=%s:%s -> %s" % [lv["id"], n, " (capped)" if truncated else "", n3, best3, best_keep, sol_cost, tr["rule"], str(tr["value"]), flag])
		print("[search]    cheapest3 = ", JSON.stringify(best3_pl))
		print("[search]    cheapest_keep_all = ", JSON.stringify(best_keep_pl))
		top.sort_custom(func(a, b): return a[1] < b[1])
		for i in mini(8, top.size()):
			print("[search]    keep-all: stars=%d planks=%d left=%d %s" % top[i])


func _dfs(lv: Dictionary, opts: Array, start: int, cur: Array, cost: int, out: Array, lim: int) -> void:
	out.append(cur.duplicate())
	if out.size() > SEARCH_CAP:
		return
	for i in range(start, opts.size()):
		var c: int = int(Sim.PIECES[opts[i]["piece"]]["cost"])
		if cost + c > lim:
			continue
		var clash := false
		var cnt := 0
		for x in cur:
			if x["slot"] == opts[i]["slot"]:
				clash = true
			if x["piece"] == opts[i]["piece"]:
				cnt += 1
		if clash or cnt >= int(lv["pieces"][opts[i]["piece"]]):
			continue
		cur.append(opts[i])
		_dfs(lv, opts, i + 1, cur, cost + c, out, lim)
		cur.pop_back()


func _try(id: int, pl_txt: String) -> void:
	## tuning helper: --try=ID --pl='{"farmer":"p3","pieces":[{"piece":"wood","slot":"f3"}]}' (empty = solution)
	var lv: Dictionary = levels[id - 1]
	var pl: Dictionary = lv["solution"] if pl_txt == "" else JSON.parse_string(pl_txt)
	var s := Sim.new()
	s.log_events = true
	s.setup(lv, pl)
	var next_report := 5.0
	while not s.done:
		s.step()
		for e in s.events:
			if e["kind"] in ["bite", "turn", "fence", "pop", "surface", "burst", "cure", "bucket"]:
				print("  t=%5.1f %-7s h%d %s" % [e["t"], e["kind"], Sim.hour_at(e["pos"]), e["text"]])
		s.events.clear()
		if s.t >= next_report:
			next_report += 5.0
			var fh: Array = []
			for f in s.fences:
				fh.append(int(f["hp"]))
			print("  t=%5.1f zombies=%d fences=%s" % [s.t, s.zombies.size(), str(fh)])
	print("[try] L%02d %s" % [id, JSON.stringify(s.result)])


func _verify() -> void:
	var lines: Array = []
	lines.append("| # | Level | Solution: stars / kept / lost / planks (budget, 3-star) / end | Empty board | Cheapest ablation that still keeps everyone | Verdict |")
	lines.append("|---|---|---|---|---|---|")
	var all_ok := true
	for lv in levels:
		var sol: Dictionary = lv["solution"]
		var r := _run(lv, sol)
		var empty := _run(lv, {"farmer": lv.get("farmer", "c"), "pieces": []})
		var abl_txt := "none"
		var ablation_3 := false
		var best_cost := 999
		var ps: Array = sol["pieces"]
		for i in ps.size():
			var cut: Array = ps.duplicate()
			cut.remove_at(i)
			var pl := {"farmer": sol.get("farmer", "c"), "pieces": cut}
			var ra := _run(lv, pl)
			if ra["stars"] >= 2 and ra["spent"] < best_cost:
				best_cost = ra["spent"]
				abl_txt = "drop %s@%s -> %d* (%d planks)" % [ps[i]["piece"], ps[i].get("slot", "-"), ra["stars"], ra["spent"]]
				if ra["stars"] == 3:
					ablation_3 = true
		var ok: bool = r["stars"] == 3 and empty["stars"] < 3 and not ablation_3
		if int(lv["id"]) <= PLAYABLE:
			all_ok = all_ok and ok
		var verdict := "PASS" if ok else ("FAIL" if r["stars"] < 3 else "WEAK")
		print("[verify] L%02d %s sol=%s empty=%s abl=%s -> %s" % [lv["id"], lv["name"], JSON.stringify(r), JSON.stringify(empty), abl_txt, verdict])
		var tr: Dictionary = lv.get("three_star", {})
		lines.append("| %d | %s | %d* / %d / %d / %d (%d, %s %s) / %s %.0fs | %d* kept %d/%d | %s | %s |" % [
			lv["id"], lv["name"], r["stars"], r["kept"], r["lost"], r["spent"], lv["budget"], tr.get("rule", ""), str(tr.get("value", "")),
			"sunrise" if r["sunrise"] else "cleared", r["time"], empty["stars"], empty["kept"], empty["kept"] + empty["lost"], abl_txt, verdict])
	print("[verify] levels 1-%d all pass: %s" % [PLAYABLE, all_ok])
	if verify_out != "":
		var f := FileAccess.open(verify_out, FileAccess.WRITE)
		f.store_string("\n".join(lines) + "\n")
		f.close()


# ---------------------------------------------------------------- level flow

func _load_level(i: int) -> void:
	li = i
	var lv: Dictionary = levels[li]
	placement = {"farmer": lv.get("farmer", "c"), "pieces": []}
	mode = Mode.PREP
	sim = Sim.new()
	sim.log_events = true
	sim.setup(lv, placement)
	popups.clear()
	result_panel.visible = false
	var keys: Array = lv["pieces"].keys()
	selected = keys[0] if not keys.is_empty() else ""
	_rebuild_palette()
	_refresh()


func _restart_prep() -> void:
	mode = Mode.PREP
	sim = Sim.new()
	sim.log_events = true
	sim.setup(levels[li], placement)
	result_panel.visible = false
	popups.clear()
	_refresh()


func _start_night() -> void:
	if mode != Mode.PREP:
		return
	var err := Sim.validate(levels[li], placement)
	if err != "":
		info_label.text = "Can't start: " + err
		return
	sim = Sim.new()
	sim.log_events = true
	sim.setup(levels[li], placement)
	mode = Mode.NIGHT
	acc = 0.0
	_refresh()


func _peek() -> void:
	## "Blueprint Peek" (01 sec 3.2 C): load the developer's solution
	var sol: Dictionary = levels[li]["solution"]
	peeked[li] = true
	placement = {"farmer": sol.get("farmer", "c"), "pieces": sol["pieces"].duplicate(true)}
	_restart_prep()


func _clear() -> void:
	placement = {"farmer": levels[li].get("farmer", "c"), "pieces": []}
	_restart_prep()


func _process(delta: float) -> void:
	if mode == Mode.NIGHT:
		acc += delta * speed
		while acc >= Sim.DT and not sim.done:
			acc -= Sim.DT
			sim.step()
		for e in sim.events:
			if e["text"] != "":
				popups.append({"pos": e["pos"], "text": e["text"], "age": 0.0})
		sim.events.clear()
		if sim.done:
			mode = Mode.RESULT
			_show_result()
		_refresh_info()
	for p in popups:
		p["age"] += delta
	popups = popups.filter(func(p): return p["age"] < 1.4)
	queue_redraw()


func _show_result() -> void:
	var r := sim.result
	var lv: Dictionary = levels[li]
	if not peeked.get(li, false):
		best[li] = max(int(best.get(li, 0)), int(r["stars"]))
	var stars := "*".repeat(r["stars"]) + "-".repeat(3 - r["stars"])
	var head := "SUNRISE!" if r["stars"] > 0 else "The herd got snacked on."
	if peeked.get(li, false):
		head += " (peeked: no stars recorded)"
	result_label.text = "%s   [%s]\nKept %d / %d   Planks %d / %d\n1* keep %d   2* keep all   3* %s\n%s" % [
		head, stars, r["kept"], r["kept"] + r["lost"], r["spent"], lv["budget"], lv["min_keep"],
		lv["three_star"]["text"], lv.get("outro", "")]
	result_panel.visible = true


# ---------------------------------------------------------------- input (placement)

func _unhandled_input(event: InputEvent) -> void:
	if mode != Mode.PREP:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var world: Vector2 = get_canvas_transform().affine_inverse() * event.position
		var slot := _slot_at(world)
		if slot != "":
			_tap_slot(slot)


func _slot_at(p: Vector2) -> String:
	var best := ""
	var best_d := 26.0
	for ring in ["f", "n", "o", "p"]:
		for h in 12:
			var s: String = ring + str(h)
			var d := p.distance_to(Sim.slot_pos(s))
			if d < best_d:
				best_d = d
				best = s
	if p.distance_to(Sim.C) < 26.0:
		best = "c"
	return best


func _tap_slot(slot: String) -> void:
	var lv: Dictionary = levels[li]
	var pcs: Array = placement["pieces"]
	# tap an occupied slot = remove what's there
	for i in pcs.size():
		if pcs[i].get("slot", "") == slot:
			pcs.remove_at(i)
			_restart_prep()
			return
	if selected == "":
		return
	if selected == "farmer":
		if lv.get("farmer_locked", false):
			info_label.text = "The farmer is stuck there this level."
			return
		if slot.substr(0, 1) in ["p", "c"]:
			placement["farmer"] = slot
			_restart_prep()
		return
	if not slot.substr(0, 1) in Sim.PIECES[selected]["rings"] or slot == placement["farmer"]:
		info_label.text = "%s can't go there." % Sim.PIECES[selected]["label"]
		return
	var trial := {"farmer": placement["farmer"], "pieces": pcs.duplicate()}
	trial["pieces"].append({"piece": selected, "slot": slot})
	var err := Sim.validate(lv, trial)
	if err != "":
		info_label.text = err
		return
	pcs.append({"piece": selected, "slot": slot})
	_restart_prep()


func _add_dart(delta: int) -> void:
	var pcs: Array = placement["pieces"]
	if delta < 0:
		for i in range(pcs.size() - 1, -1, -1):
			if pcs[i]["piece"] == "dart":
				pcs.remove_at(i)
				break
	else:
		var trial := {"farmer": placement["farmer"], "pieces": pcs.duplicate()}
		trial["pieces"].append({"piece": "dart"})
		if Sim.validate(levels[li], trial) != "":
			return
		pcs.append({"piece": "dart"})
	_restart_prep()


# ---------------------------------------------------------------- UI

func _label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	ui.add_child(l)
	return l


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(cb)
	return b


func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	title_label = _label(Vector2(16, 10), 24)
	rule_label = _label(Vector2(16, 44), 16)
	info_label = _label(Vector2(16, 112), 16)
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	info_label.size = Vector2(690, 80)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 905)
	panel.size = Vector2(696, 360)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.07, 0.06, 0.9)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(10)
	sb.border_color = Color(0.85, 0.7, 0.3)
	sb.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", sb)
	ui.add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	palette = GridContainer.new()
	palette.columns = 3
	v.add_child(palette)
	var row := HBoxContainer.new()
	v.add_child(row)
	row.add_child(_button("< Prev", func(): _load_level(max(0, li - 1))))
	row.add_child(_button("Clear", _clear))
	row.add_child(_button("Peek", _peek))
	row.add_child(_button("Next >", func(): _load_level(min(max_level - 1, li + 1))))
	var row2 := HBoxContainer.new()
	v.add_child(row2)
	start_btn = _button("START NIGHT", _start_night)
	start_btn.custom_minimum_size = Vector2(0, 66)
	row2.add_child(start_btn)
	row2.add_child(_button("x1/x4", func(): speed = 4 if speed == 1 else 1))
	row2.add_child(_button("Retry", _restart_prep))
	if embedded:
		var row3 := HBoxContainer.new()
		v.add_child(row3)
		row3.add_child(_button("BACK TO THE FARM (new stars pay coins)", func(): exited.emit(best)))
	result_panel = PanelContainer.new()
	result_panel.position = Vector2(60, 330)
	result_panel.size = Vector2(600, 220)
	result_panel.add_theme_stylebox_override("panel", sb)
	ui.add_child(result_panel)
	result_label = Label.new()
	result_label.add_theme_font_size_override("font_size", 22)
	result_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	result_label.custom_minimum_size = Vector2(580, 0)
	result_panel.add_child(result_label)
	result_panel.visible = false


func _rebuild_palette() -> void:
	for c in palette.get_children():
		c.queue_free()
	var lv: Dictionary = levels[li]
	for p in lv["pieces"].keys():
		if p == "dart":
			palette.add_child(_button("+ dart (2)", _add_dart.bind(1)))
			palette.add_child(_button("- dart", _add_dart.bind(-1)))
			continue
		var b := _button("%s (%d)" % [Sim.PIECES[p]["label"], Sim.PIECES[p]["cost"]], func(): selected = p; _refresh())
		b.set_meta("piece", p)
		palette.add_child(b)


func _refresh() -> void:
	var lv: Dictionary = levels[li]
	title_label.text = "Fence Fixer %d: %s" % [lv["id"], lv["name"]]
	rule_label.text = "Keep %d  |  2* keep all  |  3* %s\n%s" % [lv["min_keep"], lv["three_star"]["text"], lv.get("intro", "")]
	for b in palette.get_children():
		if b.has_meta("piece"):
			b.modulate = Color(1, 0.9, 0.4) if b.get_meta("piece") == selected else Color.WHITE
	start_btn.disabled = mode != Mode.PREP
	_refresh_info()


func _refresh_info() -> void:
	var lv: Dictionary = levels[li]
	var spent := Sim.cost_of(placement)
	var counts := {}
	for p in placement["pieces"]:
		counts[p["piece"]] = counts.get(p["piece"], 0) + 1
	var inv: Array = []
	for p in lv["pieces"].keys():
		if p != "farmer":
			inv.append("%s %d/%d" % [Sim.PIECES[p]["label"], counts.get(p, 0), lv["pieces"][p]])
	if mode == Mode.PREP:
		info_label.text = "Planks %d / %d   Tap a slot to place, tap again to remove\n%s" % [spent, lv["budget"], ", ".join(inv)]
	elif sim.done:
		info_label.text = "Dawn. %d zombies went home to sleep it off." % sim.zombies.size()
	else:
		var waiting := sim.spawns.size() - sim.spawn_i
		info_label.text = "Sunrise in %ds   zombies %d (+%d coming)   darts left %d" % [int(ceil(max(0.0, sim.night_length - sim.t))), sim.zombies.size(), waiting, sim.darts]


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if sim == null:
		return
	var night := mode != Mode.PREP
	draw_rect(Rect2(-200, -400, 1700, 2200), Color(0.16, 0.24, 0.32) if night else Color(0.45, 0.62, 0.3))
	draw_circle(Sim.C, Sim.R, Color(0.24, 0.23, 0.28) if night else Color(0.62, 0.5, 0.33))
	var font := ThemeDB.fallback_font
	# lanes with incoming waves (forecast arrows)
	var lanes := {}
	for w in levels[li]["waves"]:
		lanes[int(w["hour"])] = lanes.get(int(w["hour"]), 0) + int(w.get("count", 1))
	for h in lanes:
		var d := Sim.hour_dir(h)
		draw_line(Sim.C + d * 345.0, Sim.C + d * 420.0, Color(1, 0.5, 0.4, 0.5), 6.0)
		draw_string(font, Sim.C + d * 395.0 + Vector2(-10, -10), "x%d" % lanes[h], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 0.7, 0.6))
	# empty slots in prep
	if mode == Mode.PREP:
		for ring in ["n", "o", "p"]:
			for h in 12:
				draw_arc(Sim.slot_pos(ring + str(h)), 14, 0, TAU, 16, Color(1, 1, 1, 0.22), 2.0)
		draw_arc(Sim.C, 14, 0, TAU, 16, Color(1, 1, 1, 0.22), 2.0)
	# fences
	for h in 12:
		var f: Dictionary = sim.fences[h]
		var a0 := deg_to_rad(-90.0 + 30.0 * h - 15.0)
		var a1 := a0 + deg_to_rad(30.0)
		if f["hp"] <= 0.0:
			draw_arc(Sim.C, Sim.R, a0 + 0.08, a1 - 0.08, 6, Color(0.9, 0.3, 0.2, 0.45), 2.0)
			continue
		var cols := {"wood": Color(0.6, 0.42, 0.22), "barbed": Color(0.55, 0.55, 0.6), "brick": Color(0.72, 0.3, 0.22), "electric": Color(0.84, 1.0, 0.25)}
		var r: float = f["hp"] / f["max"]
		var col: Color = Color(0.85, 0.25, 0.2).lerp(cols[f["type"]], r)
		var wdt := {"wood": 6.0, "barbed": 6.0, "brick": 11.0, "electric": 7.0}
		draw_arc(Sim.C, Sim.R, a0 + 0.02, a1 - 0.02, 10, col, wdt[f["type"]] * (0.5 + 0.5 * r))
		if f["type"] == "barbed":
			for k in 5:
				var ak := lerpf(a0, a1, (k + 0.5) / 5.0)
				var pp := Sim.C + Vector2.from_angle(ak) * (Sim.R + 6)
				draw_line(pp - Vector2(4, 4), pp + Vector2(4, 4), Color(0.85, 0.85, 0.9), 2.0)
	# clock labels
	for h in 12:
		var lbl := str(12 if h == 0 else h)
		draw_string(font, Sim.C + Sim.hour_dir(h) * 188.0 + Vector2(-8, 6), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.35))
	# pieces
	for p in sim.pieces:
		_draw_piece(p)
	# farmer
	var fp := sim.farmer_pos
	draw_arc(fp, 80, 0, TAU, 32, Color(1, 0.85, 0.45, 0.25), 2.0)
	draw_circle(fp, 12, Color(0.25, 0.4, 0.75))
	draw_circle(fp + Vector2(0, -12), 8, Color(0.95, 0.78, 0.6))
	draw_rect(Rect2(fp + Vector2(-12, -21), Vector2(24, 4)), Color(0.85, 0.7, 0.3))
	# animals
	for a in sim.animals:
		if a["state"] == "turned":
			continue
		var sz: float = Sim.ANIMALS[a["kind"]]["size"]
		var base := {"chicken": Color(0.98, 0.93, 0.55), "pig": Color(0.96, 0.66, 0.7), "cow": Color(0.95, 0.95, 0.92)}
		var c: Color = base[a["kind"]]
		if a["state"] == "bitten":
			c = c.lerp(Color(0.6, 0.35, 0.85), 0.6)  # infection is purple (D-23)
		draw_circle(a["pos"], sz, c)
		draw_circle(a["pos"] + Vector2(sz * 0.35, -sz * 0.3), 2.0, Color.BLACK)
		if a["state"] == "bitten":
			draw_arc(a["pos"], sz + 5, -PI / 2, -PI / 2 + TAU * a["timer"] / Sim.TURN_TIMER, 20, Color(0.75, 0.3, 1.0), 3.0)
	# zombies: lavender-grey bodies, chartreuse eyes (D-23)
	for z in sim.zombies:
		var col := Color(0.66, 0.62, 0.74)
		if z["zanimal"]:
			col = Color(0.55, 0.45, 0.7)
		if z["flash"] > 0.0:
			col = Color.WHITE
		var p: Vector2 = z["pos"]
		if z["under"]:
			draw_circle(p, z["size"], Color(0.35, 0.25, 0.15, 0.8))  # dirt mound
			continue
		if z["flying"]:
			for k in 5:
				var o := Vector2.from_angle(k * TAU / 5.0 + sim.t * 3.0) * 9.0
				draw_circle(p + o, 5, Color(0.15, 0.13, 0.2))
		else:
			draw_circle(p, z["size"], col)
		draw_circle(p + Vector2(-3, -4), 2.2, Color(0.84, 1.0, 0.25))
		draw_circle(p + Vector2(4, -4), 2.2, Color(0.84, 1.0, 0.25))
		if z["bucket"] > 0.0:
			draw_rect(Rect2(p + Vector2(-8, -z["size"] - 6), Vector2(16, 9)), Color(0.7, 0.72, 0.78))
		if z["type"] == "brute":
			draw_string(font, p + Vector2(-26, -24), "Big Tiny", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		if z["type"] == "bloater":
			draw_string(font, p + Vector2(-34, -22), "Buffet Barry", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		if z["stun"] > 0.0:
			draw_string(font, p + Vector2(-6, -z["size"] - 8), "zz", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 0.6))
		var w := 24.0
		draw_rect(Rect2(p + Vector2(-w / 2, z["size"] + 4), Vector2(w, 3)), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(p + Vector2(-w / 2, z["size"] + 4), Vector2(w * clampf(z["hp"] / z["max"], 0, 1), 3)), Color(0.9, 0.3, 0.3))
	for pu in popups:
		var a: float = 1.0 - pu["age"] / 1.4
		draw_string_outline(font, pu["pos"] + Vector2(-30, -20 - 25 * pu["age"]), pu["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color(0, 0, 0, a))
		draw_string(font, pu["pos"] + Vector2(-30, -20 - 25 * pu["age"]), pu["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 0.95, 0.8, a))


func _draw_piece(p: Dictionary) -> void:
	var pos: Vector2 = p["pos"]
	var font := ThemeDB.fallback_font
	match p["piece"]:
		"spike":
			for k in 4:
				var o := Vector2(-15 + k * 10, 0)
				draw_colored_polygon(PackedVector2Array([pos + o + Vector2(-5, 6), pos + o + Vector2(5, 6), pos + o + Vector2(0, -8)]), Color(0.8, 0.8, 0.85))
		"molasses":
			draw_circle(pos, 30, Color(0.35, 0.2, 0.08, 0.85))
		"whacker":
			draw_rect(Rect2(pos + Vector2(-4, -20), Vector2(8, 22)), Color(0.55, 0.4, 0.2))
			draw_rect(Rect2(pos + Vector2(-14, -28), Vector2(28, 12)), Color(0.7, 0.7, 0.75))
		"cow_decoy":
			if p["hp"] > 0.0:
				draw_circle(pos, 16, Color(1, 0.75, 0.85))
				draw_circle(pos + Vector2(-5, -3), 4, Color(0.2, 0.2, 0.2))
				draw_string(font, pos + Vector2(-16, -20), "%d" % int(p["hp"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		"rubber_chicken":
			if p["hp"] > 0.0:
				draw_circle(pos, 9, Color(1, 0.85, 0.1))
				draw_circle(pos + Vector2(0, -10), 3, Color(1, 0.3, 0.2))
		"scarecrow":
			draw_line(pos + Vector2(0, 14), pos + Vector2(0, -16), Color(0.55, 0.4, 0.2), 3.0)
			draw_line(pos + Vector2(-14, -6), pos + Vector2(14, -6), Color(0.55, 0.4, 0.2), 3.0)
			draw_circle(pos + Vector2(0, -18), 6, Color(0.9, 0.8, 0.4))
			draw_arc(pos, 170, 0, TAU, 40, Color(0.9, 0.8, 0.4, 0.12), 1.5)
			if p.has("shot") and p["cd"] > 0.85:
				draw_line(pos, p["shot"], Color(1, 0.9, 0.4, 0.8), 2.0)
		"bell":
			draw_colored_polygon(PackedVector2Array([pos + Vector2(-12, 10), pos + Vector2(12, 10), pos + Vector2(7, -12), pos + Vector2(-7, -12)]), Color(0.95, 0.8, 0.3))
			if p["cd"] > 5.4:
				draw_arc(pos, 160 * (6.0 - p["cd"]) / 0.6, 0, TAU, 40, Color(1, 0.9, 0.5, 0.5), 3.0)


# ---------------------------------------------------------------- screenshots (xvfb-run)

func _shots() -> void:
	DirAccess.make_dir_recursive_absolute(shots_dir)
	for n in [1, 6, 10]:
		_load_level(n - 1)
		await _frames(3)
		_save("L%02d_prep_empty" % n)
		if n == 1:
			# exercise the real touch path: tap the 3 o'clock fence gap with the wood fence selected
			selected = "wood"
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = true
			ev.position = get_canvas_transform() * Sim.slot_pos("f3")
			_unhandled_input(ev)
			print("[shots] tap test: placement after tapping f3 = ", JSON.stringify(placement))
		else:
			_peek()
		await _frames(3)
		_save("L%02d_prep_solution" % n)
		_start_night()
		var target: float = float(levels[li].get("shot_t", 20.0))
		speed = 1
		while sim.t < target and not sim.done:
			for k in 10:
				sim.step()
			for e in sim.events:
				if e["text"] != "":
					popups.append({"pos": e["pos"], "text": e["text"], "age": 0.0})
			sim.events.clear()
			for p in popups:
				p["age"] += 10 * Sim.DT
			popups = popups.filter(func(p): return p["age"] < 1.4)
		mode = Mode.NIGHT
		_refresh_info()
		queue_redraw()
		await _frames(3)
		_save("L%02d_night" % n)
		sim.run_to_end()
		mode = Mode.RESULT
		_show_result()
		_refresh_info()
		queue_redraw()
		await _frames(3)
		_save("L%02d_result" % n)
	print("[shots] done")
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw


func _save(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(shots_dir.path_join(name + ".png"))
	print("[shots] ", name)
