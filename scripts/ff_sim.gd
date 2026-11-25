extends RefCounted
## Fence Fixer: deterministic puzzle-night simulation (no randomness, fixed 15 Hz step).
## Pure logic, no nodes: the same code runs the headless solver (--verify) and the playable view.
## Rules are documented in ../fence_fixer_pack1.md section 3. Numbers come from 02_combat sec 3.3
## (L1 stats, 1 tile = 30 px) and the prototype (pen radius 210, farmer pitchfork 22 dmg / 0.45 s).

const DT := 1.0 / 15.0
const C := Vector2(640, 400)
const R := 210.0
const TILE := 30.0
const SPAWN_R := 430.0
const RING := {"f": 210.0, "n": 255.0, "o": 330.0, "p": 160.0, "c": 0.0}
const TURN_TIMER := 8.0           # D-14
const DART_DELAY := 1.0

# cost in planks, slot rings allowed
const PIECES := {
	"farmer": {"cost": 0, "rings": ["p", "c"], "label": "Farmer post"},
	"wood": {"cost": 1, "rings": ["f"], "hp": 300.0, "label": "Wood fence"},
	"barbed": {"cost": 2, "rings": ["f"], "hp": 300.0, "thorns": 10.0, "label": "Barbed fence"},
	"brick": {"cost": 3, "rings": ["f"], "hp": 900.0, "label": "Brick wall"},
	"electric": {"cost": 4, "rings": ["f"], "hp": 350.0, "zap": 40.0, "label": "Electric fence"},
	"spike": {"cost": 2, "rings": ["n", "o"], "label": "Spike strip"},
	"molasses": {"cost": 2, "rings": ["n", "o"], "label": "Molasses puddle"},
	"whacker": {"cost": 3, "rings": ["n", "o"], "label": "Gopher Whacker"},
	"cow_decoy": {"cost": 2, "rings": ["n", "o"], "hp": 400.0, "label": "Blow-Up Bessie"},
	"rubber_chicken": {"cost": 1, "rings": ["n", "o", "p"], "hp": 60.0, "label": "Rubber chicken"},
	"scarecrow": {"cost": 3, "rings": ["p", "c"], "label": "Scarecrow"},
	"bell": {"cost": 4, "rings": ["p", "c"], "label": "Church bell"},
	"dart": {"cost": 2, "rings": [], "label": "Vaccine dart"},
}
const FENCE_CODES := {"W": "wood", ".": "", "B": "barbed", "K": "brick", "E": "electric"}

# 02_combat sec 3.3 (level 1). speed px/s = MS tiles/s x 30
const ZTYPES := {
	"shambler": {"hp": 100.0, "dmg": 10.0, "ai": 1.5, "speed": 24.0, "arm": 0.0, "size": 12.0},
	"jogger": {"hp": 60.0, "dmg": 8.0, "ai": 1.0, "speed": 60.0, "arm": 0.0, "size": 11.0},
	"crow": {"hp": 125.0, "dmg": 15.0, "ai": 1.0, "speed": 72.0, "arm": 0.0, "size": 13.0, "flying": true},
	"bucket": {"hp": 140.0, "dmg": 12.0, "ai": 1.5, "speed": 21.0, "arm": 0.0, "size": 13.0, "bucket": 250.0},
	"digger": {"hp": 120.0, "dmg": 12.0, "ai": 1.2, "speed": 30.0, "arm": 0.0, "size": 12.0, "digger": true},
	"bloater": {"hp": 300.0, "dmg": 15.0, "ai": 2.0, "speed": 18.0, "arm": 0.0, "size": 17.0, "range": 90.0},
	"brute": {"hp": 900.0, "dmg": 60.0, "ai": 2.0, "speed": 21.0, "arm": 40.0, "size": 18.0, "fence_mult": 3.0},
}
const ANIMALS := {
	"chicken": {"size": 9.0, "rank": 0, "zhp": 30.0, "zspeed": 108.0},
	"pig": {"size": 13.0, "rank": 1, "zhp": 55.0, "zspeed": 84.0},
	"cow": {"size": 17.0, "rank": 2, "zhp": 90.0, "zspeed": 71.0},
}

var level: Dictionary
var t := 0.0
var night_length := 60.0
var fences: Array = []        # [{type, hp, max}]
var pieces: Array = []        # placed non-fence pieces [{piece, slot, pos, hp, cd}]
var farmer_pos := C
var farmer_home := C
var farmer_mobile := true      # false when the level locks him ("Grandpa threw his back out")
var farmer_cd := 0.0
const FARMER_SPEED := 150.0
var zombies: Array = []
var animals: Array = []
var spawns: Array = []        # [{t, type, hour}] sorted
var spawn_i := 0
var darts := 0
var darts_used := 0
var spent := 0
var done := false
var result := {}
var events: Array = []        # [{t, kind, pos, text}] for the view (popups); headless ignores
var log_events := false
var placement_error := ""


static func hour_dir(h: int) -> Vector2:
	return Vector2.from_angle(deg_to_rad(-90.0 + 30.0 * h))


static func slot_pos(slot: String) -> Vector2:
	if slot == "c":
		return C
	var ring := slot.substr(0, 1)
	var h := int(slot.substr(1))
	return C + hour_dir(h) * RING[ring]


static func hour_at(p: Vector2) -> int:
	var ang := (p - C).angle() + PI / 2.0
	return posmod(int(round(ang / (PI / 6.0))), 12)


static func cost_of(placement: Dictionary) -> int:
	var s := 0
	for pc in placement.get("pieces", []):
		s += int(PIECES[pc["piece"]]["cost"])
	return s


static func validate(lv: Dictionary, placement: Dictionary) -> String:
	## returns "" if legal, else a reason
	var avail: Dictionary = lv.get("pieces", {})
	var counts := {}
	var used_slots := {}
	for pc in placement.get("pieces", []):
		var p: String = pc["piece"]
		if not PIECES.has(p):
			return "unknown piece " + p
		counts[p] = counts.get(p, 0) + 1
		if counts[p] > int(avail.get(p, 0)):
			return "too many " + p
		if p == "dart":
			continue
		var slot: String = pc.get("slot", "")
		var ring := slot.substr(0, 1)
		if not ring in PIECES[p]["rings"]:
			return "%s cannot go on %s" % [p, slot]
		if used_slots.has(slot):
			return "slot %s used twice" % slot
		used_slots[slot] = true
	var fslot: String = placement.get("farmer", lv.get("farmer", "c"))
	if lv.get("farmer_locked", false) and fslot != lv.get("farmer", "c"):
		return "farmer is locked"
	if used_slots.has(fslot):
		return "farmer slot occupied"
	if cost_of(placement) > int(lv.get("budget", 0)):
		return "over budget"
	return ""


func setup(lv: Dictionary, placement: Dictionary) -> void:
	level = lv
	night_length = float(lv.get("night_length", 60))
	placement_error = validate(lv, placement)
	spent = cost_of(placement)
	fences.clear()
	var fs: String = lv.get("fences", "WWWWWWWWWWWW")
	for i in 12:
		var ft: String = FENCE_CODES[fs.substr(i, 1)]
		var hp: float = PIECES[ft]["hp"] if ft != "" else 0.0
		fences.append({"type": ft, "hp": hp, "max": max(hp, 1.0)})
	farmer_pos = slot_pos(placement.get("farmer", lv.get("farmer", "c")))
	farmer_home = farmer_pos
	farmer_mobile = not lv.get("farmer_locked", false)
	pieces.clear()
	darts = 0
	for pc in placement.get("pieces", []):
		var p: String = pc["piece"]
		if p == "dart":
			darts += 1
			continue
		var slot: String = pc["slot"]
		if slot.begins_with("f"):
			var h := int(slot.substr(1))
			fences[h] = {"type": p, "hp": PIECES[p]["hp"], "max": PIECES[p]["hp"]}
		else:
			pieces.append({"piece": p, "slot": slot, "pos": slot_pos(slot), "hp": PIECES[p].get("hp", 1.0), "cd": 0.0})
	animals.clear()
	for a in lv.get("animals", []):
		var pos := C + hour_dir(int(a["hour"])) * float(a["r"])
		animals.append({"kind": a["kind"], "pos": pos, "state": "ok", "timer": 0.0, "cure_at": -1.0})
	spawns.clear()
	for w in lv.get("waves", []):
		for k in int(w.get("count", 1)):
			spawns.append({"t": float(w["t"]) + k * float(w.get("gap", 1.5)), "type": w["type"], "hour": int(w["hour"])})
	spawns.sort_custom(func(a, b): return a["t"] < b["t"] or (a["t"] == b["t"] and a["hour"] < b["hour"]))
	spawn_i = 0
	zombies.clear()
	t = 0.0
	farmer_cd = 0.0
	darts_used = 0
	done = false
	result = {}


func _ev(kind: String, pos: Vector2, text: String) -> void:
	if log_events:
		events.append({"t": t, "kind": kind, "pos": pos, "text": text})


func run_to_end() -> Dictionary:
	var guard := 0
	while not done and guard < 100000:
		step()
		guard += 1
	return result


# ---------------------------------------------------------------- damage

func hurt(z: Dictionary, raw: float, blunt := false, src := "") -> void:
	if z["hp"] <= 0.0:
		return
	if z["under"] and src != "whacker":
		return
	var eff := raw
	if z["bucket"] > 0.0:
		eff = raw * (1.5 if blunt else 1.0) * 100.0 / 180.0
		z["bucket"] -= raw * (1.5 if blunt else 1.0)
		if z["bucket"] <= 0.0:
			_ev("bucket", z["pos"], "CLANG! bucket off")
	else:
		eff = raw * 100.0 / (100.0 + z["arm"])
	z["hp"] -= eff
	z["flash"] = 0.12


func _spawn(s: Dictionary) -> void:
	var ty: Dictionary = ZTYPES[s["type"]]
	var dir := hour_dir(s["hour"])
	zombies.append({
		"type": s["type"], "pos": C + dir * SPAWN_R, "hp": ty["hp"], "max": ty["hp"], "arm": ty["arm"],
		"speed": ty["speed"], "dmg": ty["dmg"], "ai": ty["ai"], "size": ty["size"],
		"flying": ty.get("flying", false), "under": ty.get("digger", false), "bucket": ty.get("bucket", 0.0),
		"state": "walk", "target": null, "cd": 0.0, "bite_cd": 0.0, "stun": 0.0, "zap": 0.0, "flash": 0.0,
		"zanimal": false, "hour": s["hour"],
	})


func _animal_turn(a: Dictionary) -> void:
	a["state"] = "turned"
	var k: Dictionary = ANIMALS[a["kind"]]
	zombies.append({
		"type": "z" + a["kind"], "pos": a["pos"], "hp": k["zhp"], "max": k["zhp"], "arm": 0.0,
		"speed": k["zspeed"], "dmg": 8.0, "ai": 1.4, "size": k["size"], "flying": false, "under": false,
		"bucket": 0.0, "state": "inside", "target": null, "cd": 0.0, "bite_cd": 1.0, "stun": 0.0, "zap": 0.0,
		"flash": 0.0, "zanimal": true, "hour": hour_at(a["pos"]),
	})
	_ev("turn", a["pos"], "it TURNED!")


func _bite(a: Dictionary) -> void:
	a["state"] = "bitten"
	a["timer"] = TURN_TIMER
	_ev("bite", a["pos"], "BITTEN!")
	if darts > 0:
		darts -= 1
		darts_used += 1
		a["cure_at"] = t + DART_DELAY


func _healthy_target(from: Vector2, flying: bool) -> Variant:
	var best = null
	var best_d := INF
	if flying:
		for p in pieces:
			if p["piece"] == "rubber_chicken" and p["hp"] > 0.0:
				var d := from.distance_to(p["pos"])
				if d < best_d:
					best_d = d
					best = p
		if best != null:
			return best
		var min_rank := 99
		for a in animals:
			if a["state"] == "ok":
				min_rank = min(min_rank, ANIMALS[a["kind"]]["rank"])
		for a in animals:
			if a["state"] == "ok" and ANIMALS[a["kind"]]["rank"] == min_rank:
				var d := from.distance_to(a["pos"])
				if d < best_d:
					best_d = d
					best = a
		return best
	for a in animals:
		if a["state"] == "ok":
			var d := from.distance_to(a["pos"])
			if d < best_d:
				best_d = d
				best = a
	return best


func _decoy_for(z: Dictionary) -> Variant:
	if z["flying"] or z["under"] or z["type"] == "brute" or z["zanimal"]:
		return null
	var best = null
	var best_d := 150.0
	for p in pieces:
		if p["piece"] == "cow_decoy" and p["hp"] > 0.0:
			var d: float = z["pos"].distance_to(p["pos"])
			if d < best_d:
				best_d = d
				best = p
	return best


# ---------------------------------------------------------------- step

func step() -> void:
	if done:
		return
	t += DT
	while spawn_i < spawns.size() and spawns[spawn_i]["t"] <= t:
		_spawn(spawns[spawn_i])
		spawn_i += 1
	_defenders()
	for z in zombies:
		if z["hp"] > 0.0:
			_zombie(z)
	# deaths (Bloater burst) and cleanup
	var alive: Array = []
	for z in zombies:
		if z["hp"] <= 0.0:
			if z.get("gone", false):
				continue
			_ev("kill", z["pos"], "tucked in!")
			if z["type"] == "bloater":
				_burst(z["pos"])
		else:
			alive.append(z)
	zombies = alive
	for a in animals:
		if a["state"] == "bitten":
			if a["cure_at"] >= 0.0 and t >= a["cure_at"]:
				a["state"] = "ok"
				a["cure_at"] = -1.0
				_ev("cure", a["pos"], "CURED (dart)")
			else:
				a["timer"] -= DT
				if a["timer"] <= 0.0:
					_animal_turn(a)
	for p in pieces:
		if p["piece"] in ["cow_decoy", "rubber_chicken"] and p["hp"] <= 0.0 and p.get("popped", false) == false:
			p["popped"] = true
			_ev("pop", p["pos"], "POP!")
	var pending := false
	for a in animals:
		if a["state"] == "bitten":
			pending = true
	if t >= night_length or (spawn_i >= spawns.size() and zombies.is_empty() and not pending):
		_finish()


func _burst(pos: Vector2) -> void:
	_ev("burst", pos, "SPLORT! (glitter goo)")
	for h in 12:
		if fences[h]["hp"] > 0.0 and pos.distance_to(C + hour_dir(h) * R) <= 70.0:
			fences[h]["hp"] = max(0.0, fences[h]["hp"] - 60.0)
	for p in pieces:
		if p.has("hp") and p["piece"] in ["cow_decoy", "rubber_chicken"] and pos.distance_to(p["pos"]) <= 70.0:
			p["hp"] -= 60.0
	for a in animals:
		if a["state"] == "ok" and pos.distance_to(a["pos"]) <= 70.0:
			_bite(a)


func _nearest_enemy(from: Vector2, rng: float, prefer_flying := false) -> Variant:
	var best = null
	var best_d := rng
	if prefer_flying:
		for z in zombies:
			if z["hp"] > 0.0 and z["flying"]:
				var d: float = from.distance_to(z["pos"])
				if d <= best_d:
					best_d = d
					best = z
		if best != null:
			return best
		best_d = rng
	for z in zombies:
		if z["hp"] > 0.0 and not z["under"]:
			var d: float = from.distance_to(z["pos"])
			if d <= best_d:
				best_d = d
				best = z
	return best


func _farmer_move() -> void:
	## Holds his post; leaves it only to chase a zombie that is already inside the pen.
	if not farmer_mobile:
		return
	var best = null
	var best_d := INF
	for z in zombies:
		if z["hp"] > 0.0 and not z["under"] and z["pos"].distance_to(C) < R - 8.0:
			var d: float = farmer_pos.distance_to(z["pos"])
			if d < best_d:
				best_d = d
				best = z
	var goal: Vector2 = farmer_home if best == null else best["pos"]
	if farmer_pos.distance_to(goal) > 40.0 or best == null:
		farmer_pos = farmer_pos.move_toward(goal, FARMER_SPEED * DT)


func _defenders() -> void:
	_farmer_move()
	farmer_cd = max(0.0, farmer_cd - DT)
	if farmer_cd <= 0.0:
		var z = _nearest_enemy(farmer_pos, 80.0)
		if z != null:
			hurt(z, 22.0)
			farmer_cd = 0.45
			_ev("fork", z["pos"], "")
	for p in pieces:
		p["cd"] = max(0.0, p["cd"] - DT)
		match p["piece"]:
			"scarecrow":
				if p["cd"] <= 0.0:
					var z = _nearest_enemy(p["pos"], 170.0, true)
					if z != null:
						hurt(z, 40.0 if z["flying"] else 20.0)  # Sally is a crow specialist (x2 vs flyers)
						p["cd"] = 1.0
						p["shot"] = z["pos"]
			"bell":
				if p["cd"] <= 0.0 and _nearest_enemy(p["pos"], 160.0) != null:
					p["cd"] = 6.0
					_ev("bell", p["pos"], "DONG!")
					for z in zombies:
						if not z["under"] and z["pos"].distance_to(p["pos"]) <= 160.0:
							z["stun"] = 1.5
							hurt(z, 30.0)
			"spike":
				for z in zombies:
					if not z["flying"] and not z["under"] and z["pos"].distance_to(p["pos"]) <= 36.0:
						hurt(z, 30.0 * DT)
			"whacker":
				if p["cd"] <= 0.0:
					for z in zombies:
						if z["hp"] > 0.0 and not z["flying"] and z["pos"].distance_to(p["pos"]) <= 45.0:
							hurt(z, 60.0, true, "whacker")
							p["cd"] = 2.0
							_ev("whack", z["pos"], "WHACK!")
							break


func _slow_at(z: Dictionary) -> float:
	## Molasses: 35 % move speed and half chew speed inside radius 45
	if z["flying"] or z["under"]:
		return 1.0
	for p in pieces:
		if p["piece"] == "molasses" and z["pos"].distance_to(p["pos"]) <= 45.0:
			return 0.35
	return 1.0


func _attack_tick(z: Dictionary) -> bool:
	## discrete hits: returns true on the frame a hit lands (molasses halves the rate)
	z["cd"] -= DT * (0.5 if _slow_at(z) < 1.0 else 1.0)
	if z["cd"] <= 0.0:
		z["cd"] += z["ai"]
		return true
	return false


func _zombie(z: Dictionary) -> void:
	z["flash"] = max(0.0, z["flash"] - DT)
	z["bite_cd"] = max(0.0, z["bite_cd"] - DT)
	if z["stun"] > 0.0:
		z["stun"] -= DT
		return
	var spd: float = z["speed"] * _slow_at(z)
	var pos: Vector2 = z["pos"]
	var r := pos.distance_to(C)
	if z["flying"]:
		if z["state"] == "leaving":
			z["pos"] = z["pos"] + (z["pos"] - C).normalized() * spd * DT
			if z["pos"].distance_to(C) > SPAWN_R:
				z["hp"] = 0.0
				z["gone"] = true
			return
		_go_inside(z, spd)
		return
	if z["under"]:
		z["pos"] = pos.move_toward(C, 45.0 * DT)
		if z["pos"].distance_to(C) <= R - 25.0:
			z["under"] = false
			z["state"] = "inside"
			_ev("surface", z["pos"], "pop-up gopher!")
		return
	if z["state"] == "inside":
		_go_inside(z, spd)
		return
	# outside the pen
	var decoy = _decoy_for(z)
	if decoy != null:
		var rng: float = 90.0 if z["type"] == "bloater" else (z["size"] + 10.0)
		if pos.distance_to(decoy["pos"]) > rng:
			z["pos"] = pos.move_toward(decoy["pos"], spd * DT)
			z["state"] = "walk"
		else:
			z["state"] = "chew_decoy"
			if _attack_tick(z):
				decoy["hp"] -= z["dmg"]
		return
	var h := hour_at(pos)
	var f: Dictionary = fences[h]
	var stop_r: float = R + (90.0 if z["type"] == "bloater" else 6.0)
	if r > stop_r:
		z["pos"] = pos.move_toward(C, spd * DT)
		z["state"] = "walk"
		return
	if f["hp"] > 0.0:
		z["state"] = "chew"
		if _attack_tick(z):
			f["hp"] = max(0.0, f["hp"] - z["dmg"] * ZTYPES[z["type"]].get("fence_mult", 1.0))
			if f["hp"] <= 0.0:
				_ev("fence", C + hour_dir(h) * R, "FENCE DOWN!")
		if z["type"] != "bloater":
			if f["type"] == "barbed":
				hurt(z, PIECES["barbed"]["thorns"] * DT)
			elif f["type"] == "electric":
				z["zap"] -= DT
				if z["zap"] <= 0.0:
					z["zap"] = 1.0
					hurt(z, PIECES["electric"]["zap"])
					_ev("zap", pos, "ZAP!")
	else:
		if r > R - 12.0:
			z["pos"] = pos.move_toward(C, spd * DT)
		else:
			z["state"] = "inside"


func _go_inside(z: Dictionary, spd: float) -> void:
	var tgt = _healthy_target(z["pos"], z["flying"])
	if tgt == null:
		z["pos"] = z["pos"].move_toward(farmer_pos, spd * DT)
		return
	var reach: float = z["size"] + (tgt.get("size", 10.0) if tgt.has("kind") == false else ANIMALS[tgt["kind"]]["size"]) + 2.0
	if z["pos"].distance_to(tgt["pos"]) > reach:
		z["pos"] = z["pos"].move_toward(tgt["pos"], spd * DT)
		return
	if tgt.has("piece"):  # rubber chicken
		if _attack_tick(z):
			tgt["hp"] -= z["dmg"]
		return
	if z["bite_cd"] <= 0.0:
		_bite(tgt)
		z["bite_cd"] = 1.6
		if z["flying"]:
			z["state"] = "leaving"  # a crow flock pecks once and flies off with a feather


func _finish() -> void:
	done = true
	var kept := 0
	var lost := 0
	for a in animals:
		if a["state"] == "ok":
			kept += 1
		else:
			lost += 1
	var broken := 0
	for f in fences:
		if f["type"] != "" and f["hp"] <= 0.0:
			broken += 1
	var gaps := 0
	for f in fences:
		if f["hp"] <= 0.0:
			gaps += 1
	var left := zombies.size() + (spawns.size() - spawn_i)
	var s1: bool = placement_error == "" and kept >= int(level.get("min_keep", animals.size()))
	var s2: bool = s1 and lost == 0
	var rule: Dictionary = level.get("three_star", {"rule": "budget", "value": level.get("star_budget", 0)})
	var s3 := false
	match rule.get("rule", "budget"):
		"budget":
			s3 = spent <= int(rule["value"])
		"no_darts":
			s3 = darts_used == 0 and spent <= int(rule.get("value", 999))
		"fences_standing":
			s3 = broken == 0 and spent <= int(rule.get("value", 999))
		"cleared":
			s3 = left == 0 and spent <= int(rule.get("value", 999))
	s3 = s2 and s3
	var stars := 3 if s3 else (2 if s2 else (1 if s1 else 0))
	result = {"stars": stars, "kept": kept, "lost": lost, "spent": spent, "time": snappedf(t, 0.1),
		"darts_used": darts_used, "fences_broken": broken, "zombies_left": left,
		"sunrise": t >= night_length, "error": placement_error}
