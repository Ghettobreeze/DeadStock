extends Node2D
## Dead Stock prototype, CAPTAIN TEST BUILD (followups/godot_proto).
## Day prep -> night horde -> dawn payout, repeat. Everything is drawn in code.
##
## What this build adds to the original prototype (see README.md):
##   * configurable bitten/turn timer (default 8 s; T cycles 6/8/12/16/20; --turn=N)
##   * portrait 720x1280 layout by default (--landscape restores 1280x720)
##   * touch: floating joystick + "Action Fan" (lift thumb near a bitten animal), hold-to-cull,
##     auto-carry on contact, auto-save on entering the barn glow (keyboard E/Q/X/C still work)
##   * CHAIN verb (C / fan): keep a zombie-bound animal as Dead Stock (no payout), 2 chain posts per night
##   * no-wipe guard: at most 35 % of the night's starting herd can turn; later bites only spook
##   * per-night telemetry (bite->action latency, choice mix, near-miss saves, fan use) printed as JSON
##   * --sweep: headless bot with human-like reaction delay that measures outcomes per timer value

const AnimalScript := preload("res://scripts/animal.gd")
const ZombieScript := preload("res://scripts/zombie.gd")
const FarmerScript := preload("res://scripts/farmer.gd")
const FloatText := preload("res://scripts/float_text.gd")
const RaidScript := preload("res://scripts/raid.gd")
const RaiderScript := preload("res://scripts/raider.gd")
const FF_SCENE := preload("res://ff.tscn")

const PEN_CENTER := Vector2(640, 400)
const PEN_RADIUS := 210.0
const SEGMENTS := 12
const BARN_RECT := Rect2(598, 362, 84, 64)
const ACTION_RANGE := 48.0
const FAN_RANGE := 70.0          # thumb-lift search radius (world px) for the Action Fan
const TIMER_STEPS := [6.0, 8.0, 12.0, 16.0, 20.0]
const NO_WIPE_SHARE := 0.35      # 02_combat: at most 35 % of the herd can turn per night
const STRICT_GUARD := true       # D-46: timers that expire after the guard is full only spook
const CHAIN_POSTS_PER_NIGHT := 2
var BARN_SLOTS := 3             # 02_combat: barn slots = 2 + barn tier (tier 2 here)

enum Phase { DAY, DUSK, NIGHT, DAWN, GAME_OVER }

# exposed as vars so the entity scripts can read them through `main`
var pen_center := PEN_CENTER
var barn_release := BARN_RELEASE
var CHEWERS_PER_SECTION := 2   # only 2 zombies chew a section at once; the rest queue (SLIDE_RATE 0)
var FENCE_PER_NIGHT := 25.0    # fences are dug in a bit deeper each night (bonus HP, gone at dawn)
var chew_claims := {}
var horde_scale := 1.0
var barn_rect := BARN_RECT

# ---- release-1 simulated PvP (rival farms + random rival raids) and minigames
const TRAIN_COST := {"chicken": 6, "pig": 9, "cow": 14}
const FEED_PER_SOLDIER := {"chicken": 1, "pig": 2, "cow": 3}   # coins per active day (upkeep)
const SOLDIER_LABEL := {"chicken": "hen bomber", "pig": "pig brawler", "cow": "cow tank"}
const RAIDS_PER_DAY := 2
var overlay: Node = null          # a raid or Fence Fixer currently open on top of the farm
var army := {"chicken": 0, "pig": 0, "cow": 0}
var ribbons := 0
var rival_best := {}
var raid_counts := {}            # "rival:week" -> raids this week (repeat loot decay)
var rival_week := {}              # rival index -> week() in which we last flattened it (1+ star); it rebuilds next week
var raids_today := 0
var pending_raid := -1            # rival index whose gang raids us on the coming night
var raid_rival := -1
var raid_spawn_at := -1.0
var raid_stats := {}
var last_raid_night := -99
var last_raided_rival := -1
var ff_best := {}
var county_panel: PanelContainer
var county_label: Label
var rival_buttons: Array = []
var at := {}                      # autotest flags

# ---- dusk planning: read the forecast, spend planks on fence sections
var SPIKE_DPS := 30.0          # + SPIKE_DPS_PER_NIGHT x night (spikes keep pace with zombie HP)
var SPIKE_DPS_PER_NIGHT := 7.0
const PEN_BASE := 8               # pen holds PEN_BASE + PEN_PER_FENCE x fence level animals
const PEN_PER_FENCE := 2
const DEAD_STOCK_CAP := 6
const LOOT_REPEAT := 0.5         # each repeat raid on the same rival in the same week pays x0.5
const PIECE_COST := {"barricade": 1, "spikes": 2, "scarecrow": 2}
const PIECE_INFO := {
	"barricade": "Barricade (1 plank): that fence section is twice as strong tonight",
	"spikes": "Spikes (2): hurt anything chewing that section. Brutes only take half",
	"scarecrow": "Scarecrow (2): crows go for it first, and nearby hordes head for its section",
}
const SIDE_NAMES := ["NORTH", "SOUTH", "WEST", "EAST"]
const LANE_SHIFT := PI / 12.0     # lanes aim at the MIDDLE of one fence section (12 sections), not the seam between two
var SIDE_DIRS := [Vector2(0, -1).rotated(LANE_SHIFT), Vector2(0, 1).rotated(LANE_SHIFT), Vector2(-1, 0).rotated(LANE_SHIFT), Vector2(1, 0).rotated(LANE_SHIFT)]
const BARN_RELEASE := 15.0       # saved animals are cured in the barn and walk back out after this (no panic room)
const TYPE_TIPS := {
	"walker": "Walkers: chew a fence section, then go for the herd.",
	"brute": "BRUTE: chews fences 3x faster, takes 3x the hits. Spikes only do half. Barricade its side.",
	"crow": "CROWS: fly OVER fences straight at your animals. Scarecrows distract them.",
	"bloater": "BLOATER: bursts when it dies or touches an animal and bites everything nearby. Kill it OUTSIDE the fence!",
}
var pieces := {}                  # segment -> piece name (tonight only)
var scarecrow_hp := {}
var barricade_base := {}          # segment -> fence hp before tonight's barricade
var seg_max: Array[float] = []
var plan: Array = []              # [{t, side, units:{type:n}}] sorted by t
var plan_i := 0
var planks := 0
var bonus_planks := 0
var selected_piece := "spikes"
var seen_types := {}
var dusk_panel: PanelContainer
var forecast_label: Label
var planks_label: Label
var piece_buttons := {}
var pen_radius := PEN_RADIUS
var farmer_min := Vector2(20, 70)
var farmer_max := Vector2(1260, 700)

var portrait := true
# ---- UX eval v2 (eval copy only): bigger type, contextual copy, forecast card, slots, banner tips
var ux2 := true   # new-player UI (eval round): bigger text/buttons, dusk slots, banners, tips
var banner_panel: PanelContainer
var banner_label: Label
var banner_t := 0.0
var keys_label: Label
var goal_label: Label
var auto_btn: Button
var shown_tips := {}
const TIPS_V2 := {
	"walker": "WALKERS chew through a fence section, then go for your animals.\nCounter: SPIKES or a BARRICADE on that section.",
	"brute": "NEW: BRUTE. Big, slow, chews fences 3x faster and takes 3 fork hits.\nCounter: BARRICADE its section. Spikes only do half.",
	"crow": "NEW: CROWS. They fly OVER fences straight at your animals.\nCounter: a SCARECROW. Crows peck it first.",
	"bloater": "NEW: BLOATER. It pops when it dies or touches an animal and bites everything in its purple ring.\nCounter: kill it OUTSIDE the fence. Never let it reach the herd.",
	"stamina": "OUT OF BREATH! Each fork swing costs stamina (blue bar). Let it refill, or fight one side at a time.",
	"bitten": "BITTEN! It turns in 8 seconds. Walk into it to pick it up, then carry it into the BARN glow.",
	"raid": "RIVAL RAIDERS! They don't bite. They smash a fence, run for the barn and steal coins. Bonk them for a bounty.",
}
const PIECE_V2 := {
	"barricade": ["BARRICADE  1", "Fence 2x tough"],
	"spikes": ["SPIKES  2", "Hurts chewers"],
	"scarecrow": ["SCARECROW  2", "Lures crows + hordes"],
}
var screen := Vector2(720, 1280)
var cam: Camera2D

var phase := Phase.DAY
var night := 1
var coins := 40
var vaccines := 1
var parts := 0
var fork_level := 1
var fence_level := 1
var fence_max := 100.0
var fence_hp: Array[float] = []
var dead_stock := 0             # chained undead units (PvP army) kept across nights
var chain_posts := CHAIN_POSTS_PER_NIGHT

var turn_timer := 8.0
var auto_carry := true

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
var herd_at_dusk := 0

# touch
var touch_dir := Vector2.ZERO
var joy_index := -1
var joy_origin := Vector2.ZERO
var joy_pos := Vector2.ZERO
const JOY_RADIUS := 70.0
var fan_open := false
var fan_pos := Vector2.ZERO
var fan_target: Node2D = null
var fan_age := 0.0
var fan_hold_index := -1
var fan_hold_btn := ""
var fan_hold_t := 0.0
const FAN_BTN_R := 46.0
const FAN_LAYOUT := {"carry": Vector2(-120, -60), "cure": Vector2(-48, -150), "chain": Vector2(48, -150), "cull": Vector2(120, -60)}
const CULL_HOLD := 0.5
var touch_overlay: Node2D

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
var panel_opened_ms := -100000     # when the shop / dusk panel last appeared (ghost double-tap guard)
const GHOST_TAP_MS := 350

# autotest / sweep
var autotest_dir := ""
var autotest_t := 0.0
var autotest_shots := {}
var sweep_values: Array = []
var sweep_idx := 0
var sweep_nights := 5
var sweep_runs := 3
var sweep_run := 0
var bot_react := 1.2
var bot_focus: Node2D = null
var bot_focus_ready_at := 0.0
var sweep_rows := []
var sweep_acc := {}
var session_log := []
var sweep_start_night := 1
var sweep_herd := 6
var eval_seed := 1000
var bot_planner := "auto"   # sweep: auto (shipped) | none | random | spikes_lane | barricade | funnel | smart
var bot_triage := "human"   # sweep: human (react ~2 s, one thing at a time) | perfect | none
var bot_fight := "chase"    # sweep: chase | idle | guard
var bot_shop := "campaign"     # sweep: basic | campaign
var bot_busy_until := 0.0
var SCARECROW_HP := 120.0
var SLIDE_RATE := 0.0      # rad/s a crowded zombie shuffles along the fence (0 = waits its turn)
var STAMINA_REGEN := 1.25  # pitchfork swings recovered per second
var BURST_RADIUS := 75.0   # bloater burst radius
var AUTO_CARRY_T := 1.0   # contact time before an auto-carry pick-up (was 0.25: saves happened by accident)
var CHEW_BASE := 9.0
var CHEW_PER_NIGHT := 1.0
var NIGHT_TAIL := 16.0     # seconds of night after the last wave lands
var PLANKS_BASE := 2
var PLANKS_PER_LANE := 1.5
var carry_mult := 0.45       # farmer speed while carrying (was 0.8: the barn is 1 s from anywhere)
var bot_notice := {}
var bot_stick := 0.85       # humans rarely hold the virtual stick at full deflection
var sweep_noplan := false  # bot that triages well but skips dusk planning (tests whether the plan matters)
var sweep_lazy := false   # bot that skips dusk planning and just chases zombies (the "drag and auto-fight" player)

const TURN_LINES := {
	"chicken": ["BAWK... BRAAAINS", "the chicken came first. then the zombie.", "cluck cluck GRRR"],
	"pig": ["oink? OINK. *chomp*", "this little piggy went undead", "bacon... has risen"],
	"cow": ["MOOOO-AAARGH", "I'm not a zombie. I'm a mood.", "mad cow, literally"],
}
const CULL_LINES := ["sent upstate to Uncle Gary's", "Nugget's off to a farm upstate", "Gary's station wagon has A/C now", "farewell, Porkchop. Gary has a pool."]
const SAVE_LINES := ["SAVED!", "barn sweet barn", "phew!"]
const CHAIN_LINES := ["enlisted! (Dead Stock)", "hup! one undead recruit", "chained. it salutes. badly."]


func _ready() -> void:
	randomize()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest="):
			autotest_dir = a.trim_prefix("--autotest=")
			Engine.time_scale = 3.0
		elif a.begins_with("--uxtour="):
			var tour = load("res://scripts/ux_tour.gd").new()
			tour.m = self
			tour.dir = a.trim_prefix("--uxtour=")
			for a2 in OS.get_cmdline_user_args():
				if a2.begins_with("--uxtag="):
					tour.tag = a2.trim_prefix("--uxtag=")
			call_deferred("add_child", tour)
		elif a.begins_with("--uxpassive="):
			var pt = load("res://scripts/ux_passive.gd").new()
			pt.m = self
			pt.runs = int(a.trim_prefix("--uxpassive="))
			call_deferred("add_child", pt)
		elif a == "--uxv2":
			ux2 = true
		elif a == "--landscape":
			portrait = false
		elif a.begins_with("--turn="):
			turn_timer = float(a.trim_prefix("--turn="))
		elif a.begins_with("--sweep="):
			for v in a.trim_prefix("--sweep=").split(","):
				sweep_values.append(float(v))
		elif a.begins_with("--nights="):
			sweep_nights = int(a.trim_prefix("--nights="))
		elif a.begins_with("--runs="):
			sweep_runs = int(a.trim_prefix("--runs="))
		elif a.begins_with("--start-night="):
			sweep_start_night = int(a.trim_prefix("--start-night="))
		elif a.begins_with("--herd="):
			sweep_herd = int(a.trim_prefix("--herd="))
		elif a == "--lazy":
			sweep_lazy = true
		elif a.begins_with("--horde="):
			horde_scale = float(a.trim_prefix("--horde="))
		elif a == "--noplan":
			sweep_noplan = true
		elif a.begins_with("--planner="):
			bot_planner = a.trim_prefix("--planner=")
		elif a.begins_with("--triage="):
			bot_triage = a.trim_prefix("--triage=")
		elif a.begins_with("--fight="):
			bot_fight = a.trim_prefix("--fight=")
		elif a.begins_with("--shop="):
			bot_shop = a.trim_prefix("--shop=")
		elif a.begins_with("--seed="):
			eval_seed = int(a.trim_prefix("--seed="))
		elif a.begins_with("--set="):
			# --set=name=value : override any numeric tuning var on main (eval sweeps)
			var kv := a.trim_prefix("--set=").split("=")
			set(kv[0], float(kv[1]) if typeof(get(kv[0])) == TYPE_FLOAT else int(kv[1]))
		elif a.begins_with("--react="):
			bot_react = float(a.trim_prefix("--react="))
	_setup_view()
	entity_layer = Node2D.new()
	add_child(entity_layer)
	fx_layer = Node2D.new()
	add_child(fx_layer)
	farmer = FarmerScript.new()
	farmer.main = self
	farmer.position = PEN_CENTER + Vector2(0, 90)
	entity_layer.add_child(farmer)
	_build_ui()
	if not sweep_values.is_empty():
		turn_timer = sweep_values[0]
		seed(eval_seed)
		if sweep_noplan:
			bot_planner = "none"
		if sweep_lazy:
			bot_triage = "lazy"
	_new_game()


func _setup_view() -> void:
	screen = Vector2(720, 1280) if portrait else Vector2(1280, 720)
	get_tree().root.content_scale_size = Vector2i(int(screen.x), int(screen.y))
	if DisplayServer.get_name() != "headless" and not OS.has_feature("web"):
		DisplayServer.window_set_size(Vector2i(int(screen.x * (0.6 if portrait else 1.0)), int(screen.y * (0.6 if portrait else 1.0))))
	cam = Camera2D.new()
	cam.position = PEN_CENTER + (Vector2(0, 40) if portrait else Vector2.ZERO)
	cam.zoom = Vector2(1.5, 1.5) if portrait else Vector2(1, 1)
	add_child(cam)
	cam.make_current()
	var half := screen / cam.zoom / 2.0
	farmer_min = cam.position - half + Vector2(20, 60)
	farmer_max = cam.position + half - Vector2(20, 20)


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
	dead_stock = 0
	army = {"chicken": 0, "pig": 0, "cow": 0}
	ribbons = 0
	rival_best = {}
	rival_week = {}
	raid_counts = {}
	raids_today = 0
	pending_raid = -1
	raid_spawn_at = -1.0
	last_raid_night = -99
	last_raided_rival = -1
	ff_best = {}
	fork_level = 1
	fence_level = 1
	fence_max = 100.0
	fence_hp.clear()
	for i in SEGMENTS:
		fence_hp.append(fence_max)
	_reset_seg_max()
	bonus_planks = 0
	seen_types = {}
	pieces.clear()
	scarecrow_hp.clear()
	plan.clear()
	plan_i = 0
	raid_rival = -1
	raid_stats = {}
	night_time = 0.0
	for f in fx_layer.get_children():
		f.queue_free()
	_reset_touch()
	var kinds := ["chicken", "chicken", "chicken", "pig", "pig", "cow"]
	var herd_n := 6 if sweep_values.is_empty() else sweep_herd
	for i in herd_n:
		_add_animal(kinds[i % kinds.size()])
	if not sweep_values.is_empty():
		night = sweep_start_night
		vaccines = 1 + sweep_start_night / 3
	farmer.carrying = null
	farmer.position = PEN_CENTER + Vector2(0, 90)
	session_log.clear()
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


func claim_chew(seg: int) -> bool:
	## each fence section holds at most CHEWERS_PER_SECTION chewing zombies per frame
	var n: int = int(chew_claims.get(seg, 0))
	if n >= CHEWERS_PER_SECTION:
		return false
	chew_claims[seg] = n + 1
	return true


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


func _turn_cap() -> int:
	## at most 35 % of the dusk herd may turn tonight (rounded down, at least 1)
	return maxi(1, int(floor(NO_WIPE_SHARE * herd_at_dusk)))


func bite(target: Node2D, _by: Node2D) -> bool:
	if not target.is_bitable():
		return false
	# no-wipe guard: once 35 % of the dusk herd has turned, bites only spook (02_combat sec 2.5)
	if stats["turned"] >= _turn_cap() or (night <= 3 and healthy_count() <= 2):
		stats["spooked"] += 1
		popup(target.position + Vector2(0, -24), "spooked!", Color(0.9, 0.9, 0.6))
		return false
	target.infect()
	stats["bitten"] += 1
	stats["last_bite_t"] = night_time
	if not stats.has("first_bite_t"):
		stats["first_bite_t"] = night_time
	if _by != null and _by.get("ztype") == "crow":
		stats["crow_bites"] = int(stats.get("crow_bites", 0)) + 1
	if _by != null and _by.get("ztype") == "bloater":
		stats["bloater_bites"] = int(stats.get("bloater_bites", 0)) + 1
	show_banner("bitten", 5.0)
	popup(target.position + Vector2(0, -24), "BITTEN!", Color(0.85, 0.5, 1.0))
	return true


func _resolve(a: Node2D, method: String) -> void:
	## telemetry for every bite resolution (save / cure / cull / chain / turned)
	var latency: float = night_time - a.bitten_at
	stats["lat_sum"] += latency
	stats["lat_n"] += 1
	if method != "turned":
		stats["left_sum"] += a.infect_time / max(0.01, a.infect_total)
		if a.infect_time < 0.25 * a.infect_total:
			stats["tense"] += 1
	if method != "turned" and a.infect_time < 1.0:
		stats["near_miss"] += 1
	stats[method] += 1


func _guard_full() -> bool:
	return stats["turned"] + int(stats.get("lost_strict", 0)) >= int(ceil(NO_WIPE_SHARE * herd_at_dusk))


func on_animal_turned(a: Node2D) -> void:
	if STRICT_GUARD and _guard_full():
		# D-46 strict no-wipe guard: the timer runs out but the animal is only "spooked & exhausted"
		if farmer.carrying == a:
			farmer.carrying = null
		a.cure()
		a.set_meta("no_pay", true)   # too shaken to lay / milk tomorrow
		stats["spooked"] += 1
		_resolve(a, "spooked_t")
		return
	if farmer.carrying == a:
		farmer.carrying = null
		a.position = farmer.position + Vector2(20, 0)
	if fan_target == a:
		_close_fan(false)
	# no-wipe guard, enforced when the timer runs out: several animals bitten at once (bloater burst)
	# must not push the night past the cap
	if stats["turned"] >= _turn_cap():
		stats["spooked"] += 1
		a.cure()
		a.set_meta("no_pay", true)   # too shaken to lay / milk tomorrow
		popup(a.position + Vector2(0, -30), "shook it off! (no produce tomorrow)", Color(0.9, 0.9, 0.6), 18)
		return
	_resolve(a, "turned")
	a.turn()
	var lines: Array = TURN_LINES[a.kind]
	popup(a.position + Vector2(0, -30), lines.pick_random(), Color(0.6, 1.0, 0.4), 18)


func on_enemy_killed(e: Node2D) -> void:
	if e.get("ztype") == "bloater" and e in zombies:
		stats["kills"] += 1
		bloater_burst(e, false)
		return
	if e.get("is_raider") == true and e in zombies:
		zombies.erase(e)
		var bounty: int = 4 + 2 * raid_rival
		var back: int = int(e.stolen)
		coins += bounty + back
		raid_stats["beaten"] += 1
		raid_stats["recovered"] += back
		popup(e.position, "BONK! +%d bounty%s" % [bounty, (" +%d back" % back) if back > 0 else ""], Color(1, 0.85, 0.3))
		e.queue_free()
		return
	if e in zombies:
		zombies.erase(e)
		stats["kills"] += 1
		stats["last_kill_t"] = night_time
		e.queue_free()
	elif e in animals:
		animals.erase(e)
		parts += 1
		stats["zombie_animals_killed"] += 1
		popup(e.position, "+1 grody bits", Color(0.6, 1, 0.5))
		e.queue_free()


func popup(pos: Vector2, text: String, color := Color.WHITE, size := 16) -> void:
	if not sweep_values.is_empty():
		return
	var f: Node2D = FloatText.new()
	if ux2:
		size = int(size * 1.3)
		var w := ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var half_w := screen.x / cam.zoom.x / 2.0
		pos.x = clampf(pos.x, cam.position.x - half_w + w / 2 + 6, cam.position.x + half_w - w / 2 - 6)
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

func _fresh_panel() -> bool:
	## true for a moment after a panel appears under the player's finger: ignore that tap
	return Time.get_ticks_msec() - panel_opened_ms < GHOST_TAP_MS


func _enter_day() -> void:
	phase = Phase.DAY
	panel_opened_ms = Time.get_ticks_msec()
	raids_today = 0
	if county_panel:
		county_panel.visible = false
	shop_panel.visible = sweep_values.is_empty()
	dawn_panel.visible = false
	over_panel.visible = false
	_close_fan(false)
	_refresh_ui()


func start_night() -> void:
	## DAY -> DUSK: show tonight's forecast and let the player spend planks on fence sections
	if phase != Phase.DAY:
		return
	_make_plan()
	pieces.clear()
	scarecrow_hp.clear()
	planks = PLANKS_BASE + fence_level + bonus_planks + int(PLANKS_PER_LANE * plan.size())
	bonus_planks = 0
	phase = Phase.DUSK
	shop_panel.visible = false
	if county_panel:
		county_panel.visible = false
	if not sweep_values.is_empty():
		if not sweep_lazy:
			_eval_plan()
		begin_night()
		return
	dusk_panel.visible = true
	panel_opened_ms = Time.get_ticks_msec()
	_dusk_camera(true)
	_refresh_dusk()


func begin_night() -> void:
	if phase != Phase.DUSK:
		return
	phase = Phase.NIGHT
	dusk_panel.visible = false
	barricade_base.clear()
	_dusk_camera(false)
	var dig_in := FENCE_PER_NIGHT * (night - 1)
	for i in SEGMENTS:
		if fence_hp[i] > 0.0:
			fence_hp[i] += dig_in
			seg_max[i] += dig_in
	for seg in pieces:
		if pieces[seg] == "barricade":
			barricade_base[seg] = fence_hp[seg]   # the barricade soaks damage first and is gone at dawn
			fence_hp[seg] += fence_max
			seg_max[seg] = fence_max * 2.0
	night_time = 0.0
	plan_i = 0
	chain_posts = mini(CHAIN_POSTS_PER_NIGHT, maxi(0, DEAD_STOCK_CAP - dead_stock))
	herd_at_dusk = healthy_count()
	raid_spawn_at = -1.0
	raid_stats = {}
	if pending_raid >= 0:
		raid_rival = pending_raid
		pending_raid = -1
		raid_spawn_at = 16.0
		raid_stats = {"raiders": 0, "beaten": 0, "stolen": 0, "recovered": 0, "escaped": 0}
	stats = {"bitten": 0, "turned": 0, "saved": 0, "cured": 0, "culled": 0, "chained": 0, "spooked": 0, "spooked_t": 0, "lost_strict": 0,
		"kills": 0, "zombie_animals_killed": 0, "lat_sum": 0.0, "lat_n": 0, "near_miss": 0,
		"fan_opens": 0, "fan_actions": 0, "auto_carry": 0, "left_sum": 0.0, "tense": 0,
		"spike_kills": 0, "breaches": 0, "fork_kills": 0, "crow_bites": 0, "bloater_bites": 0, "plan_pieces": pieces.values()}
	popup(PEN_CENTER + Vector2(0, -200), "NIGHT %d: THEY WANT YOUR LIVESTOCK" % night, Color(1, 0.5, 0.4), 22)
	_refresh_ui()


func _end_night() -> void:
	phase = Phase.DAWN
	pieces.clear()
	scarecrow_hp.clear()
	for seg in barricade_base:
		fence_hp[seg] = minf(fence_hp[seg], float(barricade_base[seg]))   # no free repair from a barricade
	barricade_base.clear()
	for i in SEGMENTS:
		fence_hp[i] = minf(fence_hp[i], fence_max)
	_reset_seg_max()
	autotest_t = 0.0
	_close_fan(false)
	touch_dir = Vector2.ZERO
	joy_index = -1
	stats["zombies_left"] = zombies.size()
	for z in zombies:
		if z.get("is_raider") == true and not raid_stats.is_empty():
			raid_stats["escaped"] += 1   # still on the farm at sunrise = got away with what they stole
		z.queue_free()
	zombies.clear()
	var burned := 0
	var lost_infected := 0
	for a in animals.duplicate():
		if a.state == AnimalScript.State.INFECTED or a.state == AnimalScript.State.CARRIED:
			if STRICT_GUARD and _guard_full():
				a.cure()   # still under the strict guard: spooked, not lost
				continue
			stats["lost_strict"] = int(stats.get("lost_strict", 0)) + 1
			lost_infected += 1
			a.cure()   # the sun cures them, but a sick animal pays nothing this morning
			a.set_meta("no_pay", true)
		elif a.is_enemy():
			burned += 1
			animals.erase(a)
			a.queue_free()
	for a in animals:
		if a.state == AnimalScript.State.SAFE:
			a.cure()
			a.position = random_point_in_pen()
	farmer.carrying = null
	parts += burned
	var produce := 0
	for a in animals:
		if a.has_meta("no_pay"):
			a.remove_meta("no_pay")
			continue
		produce += a.payout()
	var bonus: int = 5 + int(stats["kills"])
	var total: int = produce + bonus
	coins += total
	var extra_txt := _dawn_army_and_raids()
	var rec := _telemetry_record(lost_infected)
	session_log.append(rec)
	print("[telemetry] ", JSON.stringify(rec))
	if not sweep_values.is_empty():
		_sweep_after_night(rec)
		return
	if animals.is_empty():
		_game_over()
		return
	var txt := "Night %d survived.\n\n" % night
	txt += "Bitten %d  Saved %d  Cured %d  Sent upstate %d  Chained %d  Turned %d\n" % [stats["bitten"], stats["saved"], stats["cured"], stats["culled"], stats["chained"], stats["turned"]]
	txt += "Avg bite -> action: %.1fs   Buzzer-beaters (<1s left): %d\n" % [rec["avg_latency_s"], stats["near_miss"]]
	txt += "Action Fan opened %d, used %d   Auto-carries %d\n" % [stats["fan_opens"], stats["fan_actions"], stats["auto_carry"]]
	if stats["spooked"] > 0:
		txt += "No-wipe guard: %d bites only spooked the herd.\n" % stats["spooked"]
	if lost_infected > 0:
		txt += "%d bitten animal(s) didn't make it to sunrise.\n" % lost_infected
	if burned > 0:
		txt += "%d zombie animal(s) tucked in by the sun (+%d grody bits).\n" % [burned, burned]
	txt += "\nProduce from %d animals: +%d   Survival bonus: +%d   Total: +%d coins\nDead Stock army: %d" % [animals.size(), produce, bonus, total, dead_stock]
	txt += extra_txt
	if ux2:
		txt = _dawn_text_v2(rec, produce, bonus, total, lost_infected, burned, extra_txt)
	dawn_label.text = txt
	dawn_panel.visible = true
	night += 1
	_refresh_ui()


func _telemetry_record(lost_infected: int) -> Dictionary:
	var resolved: int = stats["saved"] + stats["cured"] + stats["culled"] + stats["chained"] + stats["turned"]
	return {
		"night": night, "turn_timer_s": turn_timer, "herd_at_dusk": herd_at_dusk, "herd_at_dawn": animals.size(),
		"bitten": stats["bitten"], "saved": stats["saved"], "cured": stats["cured"], "culled": stats["culled"],
		"chained": stats["chained"], "turned": stats["turned"], "spooked": stats["spooked"],
		"lost_infected_at_dawn": lost_infected, "near_miss": stats["near_miss"],
		"avg_latency_s": (stats["lat_sum"] / stats["lat_n"]) if stats["lat_n"] > 0 else 0.0,
		"turn_rate": (float(stats["turned"]) / resolved) if resolved > 0 else 0.0,
		"time_left_share": (stats["left_sum"] / max(1, stats["lat_n"] - stats["turned"])),
		"tense": stats["tense"],
		"fan_opens": stats["fan_opens"], "fan_actions": stats["fan_actions"], "auto_carry": stats["auto_carry"],
		"portrait": portrait,
		"spike_kills": stats.get("spike_kills", 0), "breaches": stats.get("breaches", 0), "kills": stats["kills"],
		"fork_kills": stats.get("fork_kills", 0), "crow_bites": stats.get("crow_bites", 0), "bloater_bites": stats.get("bloater_bites", 0),
		"last_bite_t": stats.get("last_bite_t", -1.0), "first_bite_t": stats.get("first_bite_t", -1.0), "night_end_t": night_time, "last_kill_t": stats.get("last_kill_t", -1.0), "zombies_left": stats.get("zombies_left", 0),
		"pieces": stats.get("plan_pieces", []), "planner": bot_planner, "coins": coins, "to_spawn_total": _plan_total(),
	}


func _next_day() -> void:
	_enter_day()


func _reset_touch() -> void:
	_close_fan(false)
	touch_dir = Vector2.ZERO
	joy_index = -1
	farmer.bot_input = Vector2.ZERO


func _game_over() -> void:
	phase = Phase.GAME_OVER
	_reset_touch()
	over_label.text = "THE FARM IS LOST\n\nYou made it to night %d." % night
	if ux2:
		over_label.text = "THE FARM IS LOST\n\nEvery animal was bitten and turned on night %d.\n\nNext time:\n- Carry bitten animals into the BARN (4 spots)\n- Buy a vaccine dart before night\n- Place planks on the glowing fence spots at dusk" % night
		if army_total() > 0:
			over_label.text += "\n\n(Your %d soldiers can't guard the herd at night. Keep enough animals at home.)" % army_total()
	over_panel.visible = true
	shop_panel.visible = false
	_refresh_ui()


# ---------------------------------------------------------------- shop

func _cost(item: String) -> int:
	match item:
		"repair": return 10
		"vaccine": return 15
		"fork": return 20 * fork_level
		"fence": return 30 * fence_level
		"chicken": return 12
		"pig": return 25
		"cow": return 45
		"planks": return 10 * (1 + bonus_planks / 3)
		"train_chicken": return TRAIN_COST["chicken"]
		"train_pig": return TRAIN_COST["pig"]
		"train_cow": return TRAIN_COST["cow"]
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
			if animals.size() >= pen_cap():
				popup(farmer.position + Vector2(0, -40), "the pen is full (upgrade fences)", Color(1, 0.6, 0.5))
				return
			_add_animal(item)
		"planks":
			bonus_planks += 3
			popup(farmer.position + Vector2(0, -40), "+3 planks for tonight", Color(0.9, 0.8, 0.5))
		"train_chicken", "train_pig", "train_cow":
			var kind := item.trim_prefix("train_")
			var a := _healthy_of(kind)
			if a == null:
				popup(farmer.position + Vector2(0, -40), "no %s in the herd to train" % kind, Color(1, 0.6, 0.5))
				return
			if healthy_count() <= 1:
				popup(farmer.position + Vector2(0, -40), "keep at least one animal on the farm!", Color(1, 0.6, 0.5))
				return
			animals.erase(a)
			a.queue_free()
			army[kind] += 1
			popup(farmer.position + Vector2(0, -40), "drafted: %s!" % SOLDIER_LABEL[kind], Color(0.6, 1, 0.6))
	coins -= c
	_refresh_ui()


# ---------------------------------------------------------------- player actions

func _nearest_animal(states: Array, rng := ACTION_RANGE) -> Node2D:
	var best: Node2D = null
	var best_d := rng * rng
	for a in animals:
		if a.state in states:
			var d := farmer.position.distance_squared_to(a.position)
			if d < best_d:
				best_d = d
				best = a
	return best


func _most_urgent_bitten(rng: float) -> Node2D:
	## UX rule: the fan targets the bitten animal with the least time left in range
	var best: Node2D = null
	var best_t := INF
	for a in animals:
		if a.state == AnimalScript.State.INFECTED and farmer.position.distance_to(a.position) <= rng:
			if a.infect_time < best_t:
				best_t = a.infect_time
				best = a
	return best


func barn_used() -> int:
	var n := 0
	for a in animals:
		if a.state == AnimalScript.State.SAFE:
			n += 1
	return n


func _save_into_barn(a: Node2D) -> void:
	if barn_used() >= BARN_SLOTS:
		if not stats.get("barn_full_warned", false):
			popup(BARN_RECT.get_center() + Vector2(0, -40), "BARN FULL! cure, chain or send upstate", Color(1, 0.6, 0.5), 18)
			stats["barn_full_warned"] = true
		return
	farmer.carrying = null
	_resolve(a, "saved")
	a.state = AnimalScript.State.SAFE
	a.contact_time = 0.0
	a.infect_time = 0.0
	a.position = BARN_RECT.get_center()
	a.visible = false
	popup(BARN_RECT.get_center() + Vector2(0, -30), SAVE_LINES.pick_random(), Color(0.5, 1, 0.6), 18)


func action_carry(target: Node2D = null) -> void:
	if farmer.carrying:
		var a: Node2D = farmer.carrying
		if BARN_RECT.grow(16).has_point(farmer.position) and barn_used() < BARN_SLOTS:
			_save_into_barn(a)
		else:
			farmer.carrying = null
			a.state = AnimalScript.State.INFECTED
			a.position = farmer.position + Vector2(18, 6)
		return
	if target == null:
		target = _nearest_animal([AnimalScript.State.INFECTED])   # a bitten animal in reach wins over a healthy one
		if target == null:
			target = _nearest_animal([AnimalScript.State.HEALTHY])
	if target and target.state == AnimalScript.State.INFECTED:
		target.state = AnimalScript.State.CARRIED
		farmer.carrying = target
	elif target:
		popup(farmer.position + Vector2(0, -40), "it's fine, leave it", Color(0.8, 0.8, 0.8))


func action_cure(target: Node2D = null) -> void:
	if target == null:
		target = farmer.carrying if farmer.carrying else _most_urgent_bitten(ACTION_RANGE)
	if target == null:
		return
	if vaccines <= 0:
		popup(farmer.position + Vector2(0, -40), "no darts!", Color(1, 0.6, 0.5))
		return
	vaccines -= 1
	if farmer.carrying == target:
		farmer.carrying = null
		target.position = farmer.position + Vector2(18, 6)
	_resolve(target, "cured")
	target.cure()
	popup(target.position + Vector2(0, -30), "CURED!", Color(0.5, 0.9, 1.0), 18)
	_refresh_ui()


func action_cull(target: Node2D = null) -> void:
	if target == null:
		target = farmer.carrying if farmer.carrying else _nearest_animal([AnimalScript.State.INFECTED])   # zombies must be fought
	if target == null:
		return
	if farmer.carrying == target:
		farmer.carrying = null
	animals.erase(target)
	var fee := 0
	if target.state != AnimalScript.State.ZOMBIE:
		_resolve(target, "culled")
		fee = 5   # Uncle Gary's finder's fee, so sending one upstate is sometimes the right call
		coins += fee
	popup(target.position + Vector2(0, -30), CULL_LINES.pick_random() + ("  +%d" % fee if fee > 0 else ""), Color(0.85, 0.85, 0.85))
	target.queue_free()
	_refresh_ui()


func action_chain(target: Node2D = null) -> void:
	if target == null:
		target = farmer.carrying if farmer.carrying else _most_urgent_bitten(ACTION_RANGE)
	if target == null:
		return
	if chain_posts <= 0:
		popup(farmer.position + Vector2(0, -40), "no free chain posts", Color(1, 0.6, 0.5))
		return
	chain_posts -= 1
	if farmer.carrying == target:
		farmer.carrying = null
	animals.erase(target)
	_resolve(target, "chained")
	dead_stock += 1
	popup(target.position + Vector2(0, -30), CHAIN_LINES.pick_random(), Color(0.75, 0.6, 1.0), 18)
	target.queue_free()


func _cycle_timer() -> void:
	var i := TIMER_STEPS.find(turn_timer)
	turn_timer = TIMER_STEPS[(i + 1) % TIMER_STEPS.size()]
	popup(farmer.position + Vector2(0, -50), "turn timer: %ds" % int(turn_timer), Color(1, 1, 0.6), 18)


func _unhandled_input(event: InputEvent) -> void:
	if overlay != null:
		return
	if phase == Phase.DUSK:
		if event is InputEventScreenTouch and event.pressed:
			_dusk_tap(get_canvas_transform().affine_inverse() * event.position)
		elif event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_SPACE, KEY_ENTER]:
			begin_night()
		return
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
			KEY_C:
				if phase == Phase.NIGHT:
					action_chain()
			KEY_T:
				_cycle_timer()
			KEY_F:
				auto_carry = not auto_carry
				popup(farmer.position + Vector2(0, -50), "auto-carry %s" % ("ON" if auto_carry else "OFF"), Color(1, 1, 0.6))
			KEY_SPACE, KEY_ENTER:
				if phase == Phase.DAY:
					start_night()
				elif phase == Phase.DAWN:
					_next_day()
	elif event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		if event.index == joy_index:
			joy_pos = event.position
			touch_dir = ((joy_pos - joy_origin) / JOY_RADIUS).limit_length(1.0)
			if touch_dir.length() < 0.08:
				touch_dir = Vector2.ZERO
		elif event.index == fan_hold_index and _fan_button_at(event.position) != fan_hold_btn:
			fan_hold_index = -1
			fan_hold_btn = ""


# ---------------------------------------------------------------- touch: joystick + Action Fan

func _fan_center() -> Vector2:
	return fan_pos


func _fan_button_at(p: Vector2) -> String:
	if not fan_open:
		return ""
	var lay: Dictionary = FAN_LAYOUT_V2 if ux2 else FAN_LAYOUT
	var rr: float = FAN_R_V2 if ux2 else FAN_BTN_R
	for k in lay:
		if p.distance_to(_fan_center() + lay[k]) <= rr + 6.0:
			return k
	return ""


func _fan_enabled(k: String) -> bool:
	if fan_target == null or not is_instance_valid(fan_target):
		return false
	match k:
		"cure": return vaccines > 0
		"chain": return chain_posts > 0
		"carry": return farmer.carrying == null
	return true


func _open_fan(screen_pos: Vector2) -> void:
	var t := _most_urgent_bitten(FAN_RANGE)
	if t == null:
		return
	fan_target = t
	fan_open = true
	fan_age = 0.0
	fan_pos = Vector2(clampf(screen_pos.x, 215 if ux2 else 150, screen.x - (215 if ux2 else 150)), clampf(screen_pos.y, 300 if ux2 else 260, screen.y - 40))
	stats["fan_opens"] += 1


func _close_fan(_used: bool) -> void:
	fan_open = false
	fan_target = null
	fan_hold_index = -1
	fan_hold_btn = ""
	fan_hold_t = 0.0


func _fire_fan(k: String) -> void:
	if not _fan_enabled(k):
		popup(farmer.position + Vector2(0, -40), {"cure": "no darts!", "chain": "no chain posts", "carry": "hands full"}.get(k, "can't"), Color(1, 0.6, 0.5))
		return
	var t := fan_target
	stats["fan_actions"] += 1
	_close_fan(true)
	match k:
		"cure": action_cure(t)
		"carry": action_carry(t)
		"chain": action_chain(t)
		"cull": action_cull(t)


func _on_touch(e: InputEventScreenTouch) -> void:
	if phase != Phase.NIGHT:
		return
	if e.pressed:
		var b := _fan_button_at(e.position)
		if b != "":
			if b == "cull":
				fan_hold_index = e.index
				fan_hold_btn = b
				fan_hold_t = 0.0
			else:
				_fire_fan(b)
			return
		if fan_open:
			_close_fan(false)
		if joy_index == -1:
			joy_index = e.index
			joy_origin = e.position
			joy_pos = e.position
			touch_dir = Vector2.ZERO
	else:
		if e.index == fan_hold_index:
			fan_hold_index = -1
			fan_hold_btn = ""
			fan_hold_t = 0.0
			return
		if e.index == joy_index:
			joy_index = -1
			touch_dir = Vector2.ZERO
			if farmer.carrying == null:
				_open_fan(e.position)


func _touch_tick(delta: float) -> void:
	if fan_open:
		fan_age += delta
		if fan_target == null or not is_instance_valid(fan_target) or fan_target.state != AnimalScript.State.INFECTED or fan_age > 3.0:
			_close_fan(false)
	if fan_hold_index != -1 and fan_hold_btn == "cull":
		fan_hold_t += delta
		if fan_hold_t >= CULL_HOLD:
			_fire_fan("cull")
	# auto-carry: walking into a bitten animal with empty hands picks it up after 0.25 s of contact
	if auto_carry and farmer.carrying == null:
		for a in animals:
			if a.state == AnimalScript.State.INFECTED:
				if farmer.position.distance_to(a.position) < a.radius + 14.0:
					a.contact_time += delta
					if a.contact_time >= AUTO_CARRY_T:
						a.state = AnimalScript.State.CARRIED
						farmer.carrying = a
						stats["auto_carry"] += 1
						if fan_target == a:
							_close_fan(false)
						break
				else:
					a.contact_time = 0.0
	# auto-save on entering the barn glow (_save_into_barn warns once a night if the barn is full)
	if farmer.carrying and BARN_RECT.grow(16).has_point(farmer.position):
		_save_into_barn(farmer.carrying)


# ---------------------------------------------------------------- main loop

func _process(delta: float) -> void:
	if overlay != null:
		if autotest_dir != "":
			_autotest_overlay(delta)
		return
	var target_sky := 1.0 if phase == Phase.NIGHT else (0.45 if phase == Phase.DUSK else 0.0)
	sky = move_toward(sky, target_sky, delta * 0.8)
	if phase != Phase.GAME_OVER:
		farmer.tick(delta)
	if phase == Phase.NIGHT:
		night_time += delta
		_touch_tick(delta)
		while plan_i < plan.size() and night_time >= float(plan[plan_i]["t"]):
			_spawn_group(plan[plan_i])
			plan_i += 1
		chew_claims.clear()
		for z in zombies.duplicate():
			z.tick(delta)
		for a in animals.duplicate():
			a.tick(delta)
		var enemies := zombies.size()
		for a in animals:
			if a.is_enemy():
				enemies += 1
		if raid_spawn_at >= 0.0 and night_time >= raid_spawn_at:
			_spawn_raid_gang()
		if night_time >= night_length or (to_spawn == 0 and enemies == 0 and night_time > 12.0 and raid_spawn_at < 0.0):
			_end_night()
		elif animals.is_empty():
			_game_over()
		timer_label.text = "Sunrise in %ds" % int(ceil(max(0.0, night_length - night_time)))
	else:
		for a in animals:
			a.tick(delta)
	_update_hint()
	top_label.text = "Day %d  Coins %d  Darts %d  Bits %d  Herd %d  Barn %d/%d\nArmy: %d hens  %d pigs  %d cows  %d Dead Stock   Ribbons %d" % [night, coins, vaccines, parts, healthy_count(), barn_used(), BARN_SLOTS, army["chicken"], army["pig"], army["cow"], dead_stock, ribbons]
	if ux2:
		var lbl := "NIGHT" if phase == Phase.NIGHT else ("DUSK" if phase == Phase.DUSK else "DAY")
		top_label.text = "%s %d    Coins %d    Darts %d    Herd %d" % [lbl, night, coins, vaccines, healthy_count()]
		if army_total() > 0 and phase == Phase.DAY:
			top_label.text += "\nArmy %d" % army_total()
		if phase == Phase.NIGHT:
			timer_label.text = "Sunrise in %ds    Barn %d/%d" % [int(ceil(max(0.0, night_length - night_time))), barn_used(), BARN_SLOTS]
			if farmer.stamina < 1.0:
				show_banner("stamina", 4.0)
		if banner_t > 0.0:
			banner_t -= delta / maxf(Engine.time_scale, 0.01)
			if banner_t <= 0.0:
				banner_panel.visible = false
	timer_label.visible = phase == Phase.NIGHT
	forecast_label.visible = phase == Phase.DUSK
	queue_redraw()
	touch_overlay.queue_redraw()
	if not sweep_values.is_empty():
		_sweep_bot(delta)
	elif autotest_dir != "":
		_autotest(delta)


func _spawn_wave() -> void:
	var side := randi() % 4
	var waves_left: int = max(1, int(ceil((night_length * 0.7 - night_time) / spawn_interval)))
	var count: int = clampi(int(ceil(float(to_spawn) / waves_left)), 1, to_spawn)
	var names := ["NORTH", "SOUTH", "WEST", "EAST"]
	popup(PEN_CENTER + Vector2(0, -250), "Horde from the %s!" % names[side], Color(1, 0.55, 0.4), 20)
	for i in count:
		_spawn_zombie(side)
		to_spawn -= 1


func _spawn_group(g: Dictionary) -> void:
	var side: int = g["side"]
	var units: Dictionary = g["units"]
	popup(PEN_CENTER + SIDE_DIRS[side] * 150.0, "%s from the %s!" % [_units_text(units), SIDE_NAMES[side]], Color(1, 0.55, 0.4), 18)
	for ty in units:
		if not seen_types.has(ty):
			seen_types[ty] = true
			if ty != "walker":
				if ux2:
					show_banner(ty, 7.0)
				else:
					popup(PEN_CENTER + Vector2(0, -60), TYPE_TIPS[ty], Color(1, 0.85, 0.5), 15)
		for i in int(units[ty]):
			_spawn_zombie(side, ty)
			to_spawn -= 1


func _spawn_zombie(side: int, ty := "walker") -> void:
	var z: Node2D = ZombieScript.new()
	var jitter := randf_range(-55, 55)
	# portrait: east/west hordes spawn just off the narrower visible edge
	var ew := 220.0 if portrait else 660.0
	match side:
		0: z.position = Vector2(640 + jitter, 30 - randf() * 60)
		1: z.position = Vector2(640 + jitter, 750 + randf() * 60)
		2: z.position = Vector2(640 - ew - 20 - randf() * 60, 400 + jitter)
		_: z.position = Vector2(640 + ew + 20 + randf() * 60, 400 + jitter)
	z.position = PEN_CENTER + (z.position - PEN_CENTER).rotated(LANE_SHIFT)
	entity_layer.add_child(z)
	z.setup(self, night, ty)
	zombies.append(z)


func _update_hint() -> void:
	if ux2:
		_update_hint_v2()
		return
	match phase:
		Phase.DAY:
			hint_label.text = "DAY: shop, then START NIGHT (Space)."
		Phase.NIGHT:
			if farmer.carrying:
				hint_label.text = "Carrying: walk into the BARN glow to save it."
			else:
				hint_label.text = "Drag to move. Lift your thumb near a bitten animal for the Action Fan.\nKeys: E carry  Q cure  X cull  C chain  F auto-carry"
		Phase.DAWN:
			hint_label.text = "DAWN: Space / Next Day"
		Phase.DUSK:
			hint_label.text = "DUSK: read the forecast. Pick a piece, tap a fence section to place it (tap again to remove)."
		Phase.GAME_OVER:
			hint_label.text = ""


func _draw() -> void:
	if overlay != null:
		return
	var day_grass := Color(0.47, 0.66, 0.3)
	var night_grass := Color(0.16, 0.24, 0.32)   # night is blue, not black (04_art)
	var grass := day_grass.lerp(night_grass, sky)
	draw_rect(Rect2(-400, -400, 2080, 1520), grass)
	var crop := Color(0.36, 0.52, 0.22).lerp(Color(0.12, 0.2, 0.26), sky)
	for row in 6:
		draw_rect(Rect2(40, 90 + row * 34, 300, 14), crop)
		draw_rect(Rect2(940, 90 + row * 34, 300, 14), crop)
	draw_circle(PEN_CENTER, PEN_RADIUS, Color(0.62, 0.5, 0.33).lerp(Color(0.24, 0.23, 0.28), sky))
	for i in SEGMENTS:
		var a0 := float(i) / SEGMENTS * TAU
		var a1 := float(i + 1) / SEGMENTS * TAU
		var r := clampf(fence_hp[i] / fence_max, 0.0, 1.0)
		if fence_hp[i] <= 0.0:
			draw_arc(PEN_CENTER, PEN_RADIUS, a0 + 0.08, a1 - 0.08, 6, Color(0.9, 0.3, 0.2, 0.35), 2.0)
		else:
			var col := Color(0.85, 0.25, 0.2).lerp(Color(0.6, 0.42, 0.22), r)
			draw_arc(PEN_CENTER, PEN_RADIUS, a0 + 0.02, a1 - 0.02, 10, col, 3.0 + 5.0 * r)
			for k in 3:
				var ak := lerpf(a0, a1, (k + 0.5) / 3.0)
				draw_circle(PEN_CENTER + Vector2.from_angle(ak) * PEN_RADIUS, 4.0, col.darkened(0.3))
	_draw_plan()
	var b := BARN_RECT
	if sky > 0.3:
		draw_circle(b.get_center(), 70, Color(1, 0.75, 0.35, 0.10 * sky))  # lantern pool = safe zone
	draw_rect(b, Color(0.84, 0.29, 0.2))
	draw_colored_polygon(PackedVector2Array([b.position, b.position + Vector2(b.size.x, 0), b.position + Vector2(b.size.x / 2, -26)]), Color(0.55, 0.15, 0.12))
	draw_rect(Rect2(b.position + Vector2(30, 28), Vector2(24, 36)), Color(0.95, 0.92, 0.85))
	draw_string(ThemeDB.fallback_font, b.position + Vector2(18, 20), "BARN", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 0.95, 0.85))
	if farmer.carrying:
		draw_rect(b.grow(16), Color(0.5, 1, 0.6, 0.35 + 0.25 * sin(Time.get_ticks_msec() / 150.0)), false, 3.0)
	# off-screen bite arrows are unnecessary at this zoom; draw a line from farmer to fan target instead
	if fan_open and fan_target and is_instance_valid(fan_target):
		draw_line(farmer.position, fan_target.position, Color(1, 1, 1, 0.35), 2.0)


func _draw_overlay() -> void:
	## screen-space: joystick and Action Fan (drawn by touch_overlay on the UI layer)
	var o := touch_overlay
	if joy_index != -1:
		o.draw_circle(joy_origin, JOY_RADIUS, Color(1, 1, 1, 0.10))
		o.draw_arc(joy_origin, JOY_RADIUS, 0, TAU, 32, Color(1, 1, 1, 0.35), 2.0)
		o.draw_circle(joy_origin + touch_dir * JOY_RADIUS, 26, Color(1, 1, 1, 0.35))
	if fan_open and ux2:
		_draw_fan_v2(o)
	elif fan_open:
		var font := ThemeDB.fallback_font
		var cols := {"carry": Color(0.30, 0.75, 0.29), "cure": Color(0.25, 0.71, 1.0), "chain": Color(0.6, 0.45, 0.85), "cull": Color(0.9, 0.28, 0.23)}
		var labels := {"carry": "SAVE", "cure": "CURE", "chain": "CHAIN", "cull": "HOLD\nUPSTATE"}
		for k in FAN_LAYOUT:
			var c: Vector2 = fan_pos + FAN_LAYOUT[k]
			var col: Color = cols[k]
			if not _fan_enabled(k):
				col = Color(0.4, 0.4, 0.4)
			o.draw_circle(c + Vector2(0, 5), FAN_BTN_R, col.darkened(0.45))
			o.draw_circle(c, FAN_BTN_R, col)
			if k == "cull" and fan_hold_btn == "cull":
				o.draw_arc(c, FAN_BTN_R + 6, -PI / 2, -PI / 2 + TAU * clampf(fan_hold_t / CULL_HOLD, 0, 1), 32, Color.WHITE, 6.0)
			var lines: PackedStringArray = labels[k].split("\n")
			for li in lines.size():
				var w := font.get_string_size(lines[li], HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
				o.draw_string_outline(font, c + Vector2(-w / 2, 6 + 18 * (li - (lines.size() - 1) / 2.0)), lines[li], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, 4, Color(0, 0, 0, 0.8))
				o.draw_string(font, c + Vector2(-w / 2, 6 + 18 * (li - (lines.size() - 1) / 2.0)), lines[li], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)
		if fan_target and is_instance_valid(fan_target):
			var tl := "%.1fs" % fan_target.infect_time
			o.draw_string_outline(font, fan_pos + Vector2(-20, -205), tl, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, 5, Color.BLACK)
			o.draw_string(font, fan_pos + Vector2(-20, -205), tl, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 0.8, 0.3))


# ---------------------------------------------------------------- UI

func _panel(pos: Vector2, size: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	p.position = pos
	p.size = size
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.07, 0.06, 0.88)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(14)
	sb.border_color = Color(0.85, 0.7, 0.3)
	sb.set_border_width_all(2)
	p.add_theme_stylebox_override("panel", sb)
	ui.add_child(p)
	return p


func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	touch_overlay = Node2D.new()
	touch_overlay.draw.connect(_draw_overlay)
	ui.add_child(touch_overlay)
	var fs := 20 if portrait else 18
	top_label = Label.new()
	top_label.position = Vector2(14, 10)
	top_label.add_theme_font_size_override("font_size", fs)
	top_label.add_theme_color_override("font_outline_color", Color.BLACK)
	top_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(top_label)

	timer_label = Label.new()
	timer_label.position = Vector2(14, 64)
	timer_label.add_theme_font_size_override("font_size", fs)
	timer_label.add_theme_color_override("font_outline_color", Color.BLACK)
	timer_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(timer_label)

	hint_label = Label.new()
	hint_label.position = Vector2(14, screen.y - (70 if portrait else 34))
	hint_label.add_theme_font_size_override("font_size", 15)
	hint_label.add_theme_color_override("font_outline_color", Color.BLACK)
	hint_label.add_theme_constant_override("outline_size", 5)
	ui.add_child(hint_label)

	var shop_pos := Vector2(24, screen.y * 0.60) if portrait else Vector2(1000, 150)
	shop_panel = _panel(shop_pos, Vector2(screen.x - 48 if portrait else 260, 0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	shop_panel.add_child(v)
	var head := Label.new()
	head.text = "FARM STORE"
	head.add_theme_font_size_override("font_size", 20)
	head.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	v.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 3 if portrait else 1
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	v.add_child(grid)
	for item in ["repair", "vaccine", "fork", "fence", "planks", "chicken", "pig", "cow", "train_chicken", "train_pig", "train_cow"]:
		var btn := Button.new()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 14)
		btn.clip_text = true
		btn.custom_minimum_size = Vector2(0, 52 if portrait else 0)  # >= 48 dp touch targets
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(func(): if not _fresh_panel(): buy(item))
		btn.focus_mode = Control.FOCUS_NONE
		grid.add_child(btn)
		shop_buttons[item] = btn
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	v.add_child(nav)
	for pair in [["RIVAL RAIDS", open_county], ["FENCE FIXER", open_fence_fixer]]:
		var nb2 := Button.new()
		nb2.text = pair[0]
		nb2.custom_minimum_size = Vector2(0, 56)
		nb2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nb2.focus_mode = Control.FOCUS_NONE
		nb2.add_theme_font_size_override("font_size", 18)
		var cb: Callable = pair[1]
		nb2.pressed.connect(func(): if not _fresh_panel(): cb.call())
		nav.add_child(nb2)
	var start := Button.new()
	start.text = "START NIGHT"
	start.custom_minimum_size = Vector2(0, 72 if portrait else 0)
	start.focus_mode = Control.FOCUS_NONE
	start.add_theme_font_size_override("font_size", 22)
	start.pressed.connect(func(): if not _fresh_panel(): start_night())
	v.add_child(start)

	var dpos := Vector2(30, screen.y * 0.30) if portrait else Vector2(300, 150)
	dawn_panel = _panel(dpos, Vector2(screen.x - 60 if portrait else 680, 0))
	var dv := VBoxContainer.new()
	dawn_panel.add_child(dv)
	var dh := Label.new()
	dh.text = "SUNRISE"
	dh.add_theme_font_size_override("font_size", 26)
	dh.add_theme_color_override("font_color", Color(1, 0.8, 0.3))
	dv.add_child(dh)
	dawn_label = Label.new()
	dawn_label.add_theme_font_size_override("font_size", 16)
	dawn_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dv.add_child(dawn_label)
	var nb := Button.new()
	nb.text = "NEXT DAY"
	nb.custom_minimum_size = Vector2(0, 64)
	nb.focus_mode = Control.FOCUS_NONE
	nb.pressed.connect(_next_day)
	dv.add_child(nb)
	dawn_panel.visible = false

	over_panel = _panel(dpos + Vector2(0, 60), Vector2(screen.x - 60 if portrait else 600, 0))
	var ov := VBoxContainer.new()
	over_panel.add_child(ov)
	over_label = Label.new()
	over_label.add_theme_font_size_override("font_size", 20)
	ov.add_child(over_label)
	var rb := Button.new()
	rb.text = "START A NEW FARM"
	rb.custom_minimum_size = Vector2(0, 64)
	rb.focus_mode = Control.FOCUS_NONE
	rb.pressed.connect(_new_game)
	ov.add_child(rb)
	over_panel.visible = false

	county_panel = _panel(Vector2(24, screen.y * 0.18) if portrait else Vector2(300, 80), Vector2(screen.x - 48 if portrait else 680, 0))
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 8)
	county_panel.add_child(cv)
	var ch := Label.new()
	ch.text = "COUNTY MAP: RIVAL FARMS"
	ch.add_theme_font_size_override("font_size", 22)
	ch.add_theme_color_override("font_color", Color(1, 0.8, 0.3))
	cv.add_child(ch)
	county_label = Label.new()
	county_label.add_theme_font_size_override("font_size", 15)
	county_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	county_label.custom_minimum_size = Vector2(screen.x - 90 if portrait else 640, 0)
	cv.add_child(county_label)
	for i in RaidScript.RIVALS.size():
		var rbtn := Button.new()
		rbtn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		rbtn.custom_minimum_size = Vector2(0, 66)
		rbtn.focus_mode = Control.FOCUS_NONE
		rbtn.add_theme_font_size_override("font_size", 15)
		rbtn.pressed.connect(start_raid.bind(i))
		cv.add_child(rbtn)
		rival_buttons.append(rbtn)
	var cb := Button.new()
	cb.text = "BACK"
	cb.custom_minimum_size = Vector2(0, 56)
	cb.focus_mode = Control.FOCUS_NONE
	cb.pressed.connect(func(): county_panel.visible = false; shop_panel.visible = true)
	cv.add_child(cb)
	county_panel.visible = false

	forecast_label = Label.new()
	forecast_label.position = Vector2(14, 66)
	forecast_label.add_theme_font_size_override("font_size", 15)
	forecast_label.add_theme_color_override("font_outline_color", Color.BLACK)
	forecast_label.add_theme_constant_override("outline_size", 6)
	forecast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	forecast_label.custom_minimum_size = Vector2(screen.x - 28, 0)
	forecast_label.size = Vector2(screen.x - 28, 0)
	ui.add_child(forecast_label)
	dusk_panel = _panel(Vector2(24, screen.y - 330) if portrait else Vector2(980, 330), Vector2(screen.x - 48 if portrait else 280, 0))
	var dkv := VBoxContainer.new()
	dkv.add_theme_constant_override("separation", 6)
	dusk_panel.add_child(dkv)
	planks_label = Label.new()
	planks_label.add_theme_font_size_override("font_size", 18)
	planks_label.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	dkv.add_child(planks_label)
	var pr := HBoxContainer.new()
	pr.add_theme_constant_override("separation", 8)
	dkv.add_child(pr)
	for pc in ["barricade", "spikes", "scarecrow"]:
		var pb := Button.new()
		pb.custom_minimum_size = Vector2(0, 58)
		pb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pb.focus_mode = Control.FOCUS_NONE
		pb.add_theme_font_size_override("font_size", 15)
		pb.pressed.connect(func(): selected_piece = pc; _refresh_dusk())
		pr.add_child(pb)
		piece_buttons[pc] = pb
	var info := Label.new()
	info.name = "PieceInfo"
	info.add_theme_font_size_override("font_size", 14)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size = Vector2(screen.x - 90 if portrait else 250, 0)
	dkv.add_child(info)
	var dr := HBoxContainer.new()
	dr.add_theme_constant_override("separation", 8)
	dkv.add_child(dr)
	var clr := Button.new()
	clr.text = "CLEAR"
	clr.custom_minimum_size = Vector2(150, 60)
	clr.focus_mode = Control.FOCUS_NONE
	clr.pressed.connect(func():
		if _fresh_panel():
			return
		for sg in pieces:
			planks += int(PIECE_COST[pieces[sg]])
		pieces.clear()
		scarecrow_hp.clear()
		_refresh_dusk())
	dr.add_child(clr)
	var go := Button.new()
	go.text = "HOLD THE LINE (Space)"
	go.custom_minimum_size = Vector2(0, 60)
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go.focus_mode = Control.FOCUS_NONE
	go.add_theme_font_size_override("font_size", 20)
	go.pressed.connect(func(): if not _fresh_panel(): begin_night())
	dr.add_child(go)
	dusk_panel.visible = false
	if ux2:
		_build_ui_v2()


func _refresh_ui() -> void:
	if shop_buttons.is_empty():
		return
	if ux2:
		_refresh_ui_v2()
		return
	var names := {
		"repair": "Repair fences",
		"vaccine": "Vaccine dart (%d)" % vaccines,
		"fork": "Pitchfork Lv %d (+stamina)" % fork_level,
		"fence": "Fences Lv %d (+1 plank)" % fence_level,
		"chicken": "Chicken +4",
		"pig": "Pig +7",
		"cow": "Cow +12",
		"planks": "3 planks (%d stored)" % bonus_planks,
		"train_chicken": "Train hen bomber",
		"train_pig": "Train pig brawler",
		"train_cow": "Train cow tank",
	}
	for item in shop_buttons:
		var btn: Button = shop_buttons[item]
		btn.text = "%s\n%d coins" % [names[item], _cost(item)]   # price on its own line so clip_text never hides it
		btn.disabled = coins < _cost(item)
		if item.begins_with("train_") and (_healthy_of(item.trim_prefix("train_")) == null or healthy_count() <= 1):
			btn.disabled = true


# ---------------------------------------------------------------- dusk planning: forecast + fence pieces

func _reset_seg_max() -> void:
	seg_max.clear()
	for i in SEGMENTS:
		seg_max.append(fence_max)


func _seg_dir(seg: int) -> Vector2:
	return Vector2.from_angle((seg + 0.5) / SEGMENTS * TAU)


func _units_text(units: Dictionary) -> String:
	var parts_txt: Array = []
	for ty in ["walker", "brute", "crow", "bloater"]:
		var n: int = int(units.get(ty, 0))
		if n > 0:
			parts_txt.append("%d %s%s" % [n, ty, "s" if n > 1 else ""])
	return ", ".join(parts_txt)


func _make_plan() -> void:
	## Tonight's horde, decided at dusk and shown to the player so they can plan.
	plan.clear()
	var avail := ["walker"]
	if night >= 2:
		avail.append("brute")
	if night >= 3:
		avail.append("crow")
	if night >= 4:
		avail.append("bloater")
	var featured: String = avail[mini(night - 1, avail.size() - 1)]   # the newest type always shows up
	var waves: int = 2 if night == 1 else (3 if night <= 3 else (4 if night <= 7 else 5))
	var budget: float = (5.0 + 3.0 * night + 0.08 * night * night) * horde_scale
	var gap: float = maxf(9.0, 15.0 - night)
	var cost := {"walker": 1.0, "brute": 3.0, "crow": 1.0, "bloater": 3.0}
	var last_side := -1
	var t := 4.0
	for w in waves:
		var side := randi() % 4
		while side == last_side:
			side = randi() % 4
		last_side = side
		var units := {}
		var wb: float = budget / waves
		if w == 1 or (waves == 2 and w == 0 and featured != "walker"):
			if featured != "walker":
				var n_f := 2 if featured == "crow" else 1
				units[featured] = n_f
				wb -= cost[featured] * n_f
		elif w >= 2 and avail.size() > 1:
			var extra: String = avail[1 + randi() % (avail.size() - 1)]
			var n_e := 2 if extra == "crow" else 1
			units[extra] = n_e
			wb -= cost[extra] * n_e
		units["walker"] = int(units.get("walker", 0)) + maxi(1, int(round(wb)))
		plan.append({"t": t, "side": side, "units": units})
		# from night 4 on, some waves hit two sides at once
		if night >= 4 and w == waves - 1:
			var side2 := (side + 2) % 4
			plan.append({"t": t, "side": side2, "units": {"walker": maxi(2, int(budget / waves * 0.6))}})
		t += gap
	plan.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))
	to_spawn = 0
	for g in plan:
		for ty in g["units"]:
			to_spawn += int(g["units"][ty])
	night_length = t + NIGHT_TAIL


func _forecast_text() -> String:
	var lines: Array = ["TONIGHT'S HORDE (night %d)" % night]
	var types := {}
	for g in plan:
		lines.append("  0:%02d  %s: %s" % [int(g["t"]), SIDE_NAMES[g["side"]], _units_text(g["units"])])
		for ty in g["units"]:
			types[ty] = true
	if pending_raid >= 0:
		lines.append("  0:16  RIVAL RAID: %s's gang (steals coins, ignores the herd)" % RaidScript.RIVALS[pending_raid]["owner"])
	for ty in ["brute", "crow", "bloater"]:
		if types.has(ty) and not seen_types.has(ty):   # tips only for types you haven't met yet (keeps the list off the pen)
			lines.append(TYPE_TIPS[ty])
	return "\n".join(lines)


func _refresh_dusk() -> void:
	if ux2:
		_refresh_dusk_v2()
		return
	forecast_label.text = _forecast_text()
	planks_label.text = "DUSK PLANNING: %d planks left" % planks
	var names := {"barricade": "Barricade (1)", "spikes": "Spikes (2)", "scarecrow": "Scarecrow (2)"}
	for pc in piece_buttons:
		var b: Button = piece_buttons[pc]
		b.text = names[pc]
		b.modulate = Color(1, 0.9, 0.4) if pc == selected_piece else Color.WHITE
		b.disabled = planks < int(PIECE_COST[pc])
	var info: Label = dusk_panel.find_child("PieceInfo", true, false)
	if info:
		info.text = PIECE_INFO[selected_piece] + ".  Tap a fence section to place it, tap again to remove."


func _dusk_tap(world: Vector2) -> void:
	if absf(world.distance_to(PEN_CENTER) - PEN_RADIUS) > 45.0:
		return
	var seg := segment_at(world)
	if pieces.has(seg):
		planks += int(PIECE_COST[pieces[seg]])
		pieces.erase(seg)
		scarecrow_hp.erase(seg)
	elif planks >= int(PIECE_COST[selected_piece]):
		place_piece(seg, selected_piece)
	else:
		popup(world, "not enough planks", Color(1, 0.6, 0.5))
	_refresh_dusk()


func place_piece(seg: int, pc: String) -> bool:
	if pieces.has(seg) or planks < int(PIECE_COST[pc]):
		return false
	pieces[seg] = pc
	planks -= int(PIECE_COST[pc])
	if pc == "scarecrow":
		scarecrow_hp[seg] = SCARECROW_HP
	return true


func _auto_plan() -> void:
	## bot / sweep: a sensible player reading the forecast, biggest waves first. Spikes on every lane they
	## can afford (they also pop bloaters OUTSIDE the fence), barricade lanes led by brutes (spikes only do
	## half), a scarecrow next to the first crow lane, then barricade the lanes still bare.
	var order := plan.duplicate()
	order.sort_custom(func(x, y): return _threat(x) > _threat(y))
	var crow_done := false
	for g in order:
		var seg := segment_at(PEN_CENTER + SIDE_DIRS[g["side"]] * PEN_RADIUS)
		var u: Dictionary = g["units"]
		if pieces.has(seg):
			continue
		if int(u.get("brute", 0)) * 3 >= int(u.get("walker", 0)):
			place_piece(seg, "barricade")
		elif not place_piece(seg, "spikes"):
			place_piece(seg, "barricade")
		if u.has("crow") and not crow_done:
			crow_done = place_piece((seg + 1) % SEGMENTS, "scarecrow")
	if SLIDE_RATE > 0.0:
		for g in order:
			for k in [1, -1]:
				place_piece((segment_at(PEN_CENTER + SIDE_DIRS[g["side"]] * PEN_RADIUS) + k + SEGMENTS) % SEGMENTS, "barricade")


func decoy_point_for(pos: Vector2, ty: String) -> Vector2:
	## a scarecrow pulls ground hordes that arrive within ~75 degrees of it to its fence section
	if ty == "crow":
		return PEN_CENTER
	var ang := (pos - PEN_CENTER).angle()
	var best := -1
	var best_d := deg_to_rad(50.0)
	for seg in pieces:
		if pieces[seg] != "scarecrow":
			continue
		var d := absf(angle_difference(ang, _seg_dir(seg).angle()))
		if d < best_d:
			best_d = d
			best = seg
	if best < 0:
		return PEN_CENTER
	return PEN_CENTER + _seg_dir(best) * (PEN_RADIUS + 6.0)


func nearest_scarecrow(pos: Vector2):
	var best = null
	var best_d := INF
	for seg in pieces:
		if pieces[seg] != "scarecrow":
			continue
		var p := PEN_CENTER + _seg_dir(seg) * (PEN_RADIUS - 26.0)
		var d := pos.distance_to(p)
		if d < best_d:
			best_d = d
			best = {"pos": p, "seg": seg}
	return best


func peck_scarecrow(seg: int, dmg: float) -> void:
	if not scarecrow_hp.has(seg):
		return
	scarecrow_hp[seg] -= dmg
	if scarecrow_hp[seg] <= 0.0:
		scarecrow_hp.erase(seg)
		pieces.erase(seg)
		popup(PEN_CENTER + _seg_dir(seg) * (PEN_RADIUS - 26.0), "scarecrow shredded!", Color(1, 0.6, 0.4))


func bloater_burst(z: Node2D, contact: bool) -> void:
	if z.dead:
		return
	z.dead = true
	var hit := 0
	for a in animals.duplicate():
		if a.is_bitable() and a.position.distance_to(z.position) < BURST_RADIUS:
			if bite(a, z):
				hit += 1
	popup(z.position + Vector2(0, -20), "BLOATER BURST! %s" % ("%d bitten" % hit if hit > 0 else "nobody hurt"), Color(0.9, 0.5, 1.0) if hit > 0 else Color(0.8, 1, 0.6), 18)
	if not contact:
		pass
	zombies.erase(z)
	z.queue_free()


func _draw_plan() -> void:
	var font := ThemeDB.fallback_font
	for seg in pieces:
		var d := _seg_dir(seg)
		var a0 := float(seg) / SEGMENTS * TAU
		var a1 := float(seg + 1) / SEGMENTS * TAU
		match pieces[seg]:
			"barricade":
				draw_arc(PEN_CENTER, PEN_RADIUS + 7.0, a0 + 0.05, a1 - 0.05, 10, Color(0.35, 0.25, 0.15), 6.0)
				draw_string(font, PEN_CENTER + d * (PEN_RADIUS + 26.0) - Vector2(8, -5), "x2", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 0.9, 0.6))
			"spikes":
				for k in 4:
					var ak := lerpf(a0, a1, (k + 0.5) / 4.0)
					var base := PEN_CENTER + Vector2.from_angle(ak) * (PEN_RADIUS + 10.0)
					var out := Vector2.from_angle(ak)
					draw_colored_polygon(PackedVector2Array([base - out.orthogonal() * 4.0, base + out * 12.0, base + out.orthogonal() * 4.0]), Color(0.75, 0.75, 0.8))
			"scarecrow":
				var p := PEN_CENTER + d * (PEN_RADIUS - 26.0)
				draw_line(p + Vector2(0, 14), p + Vector2(0, -12), Color(0.5, 0.35, 0.2), 3.0)
				draw_line(p + Vector2(-12, -4), p + Vector2(12, -4), Color(0.5, 0.35, 0.2), 3.0)
				draw_circle(p + Vector2(0, -14), 6, Color(0.95, 0.85, 0.5))
				draw_rect(Rect2(p + Vector2(-8, -22), Vector2(16, 4)), Color(0.85, 0.7, 0.3))
				if scarecrow_hp.has(seg):
					draw_rect(Rect2(p + Vector2(-12, 18), Vector2(24 * float(scarecrow_hp[seg]) / SCARECROW_HP, 3)), Color(0.95, 0.75, 0.2))
	if ux2 and phase == Phase.DUSK:
		var hot := _wave_segments()
		var pulse := 0.6 + 0.4 * sin(Time.get_ticks_msec() / 220.0)
		for sg in SEGMENTS:
			if pieces.has(sg):
				continue
			var sp := PEN_CENTER + _seg_dir(sg) * PEN_RADIUS
			if hot.has(sg):
				draw_circle(sp, 22.0, Color(1, 0.6, 0.2, 0.35 * pulse))
				draw_arc(sp, 22.0, 0, TAU, 24, Color(1, 0.8, 0.3, pulse), 3.0)
			else:
				draw_arc(sp, 15.0, 0, TAU, 20, Color(1, 1, 1, 0.45), 2.0)
			draw_string_outline(font, sp + Vector2(-6, 7), "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, 4, Color(0, 0, 0, 0.7))
			draw_string(font, sp + Vector2(-6, 7), "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 0.95, 0.8))
	if ux2 and (phase == Phase.DUSK or phase == Phase.NIGHT):
		_draw_wave_labels_v2(font)
	# forecast arrows for waves that haven't arrived yet
	elif phase == Phase.DUSK or phase == Phase.NIGHT:
		var shown := {}
		for i in range(plan_i if phase == Phase.NIGHT else 0, plan.size()):
			var g: Dictionary = plan[i]
			var side: int = g["side"]
			var k: int = shown.get(side, 0)
			shown[side] = k + 1
			var d: Vector2 = SIDE_DIRS[side]
			var ew := side >= 2 and portrait   # east/west edges are close to the screen edge in portrait
			var tip := PEN_CENTER + d * (PEN_RADIUS + 12.0)
			var tail := PEN_CENTER + d * (PEN_RADIUS + (28.0 if ew else 70.0))
			var col := Color(1, 0.5, 0.35, 0.9 if phase == Phase.DUSK else 0.5)
			draw_line(tail, tip, col, 4.0)
			draw_colored_polygon(PackedVector2Array([tip, tip - d * 14.0 + d.orthogonal() * 9.0, tip - d * 14.0 - d.orthogonal() * 9.0]), col)
			var txt := "0:%02d %s" % [int(g["t"]), _short_units(g["units"])]
			var lp := tail + d * 12.0 + Vector2(-30, 4 + 16 * k)
			if portrait and side == 0:     # north: below the fence, not under the forecast text
				lp = PEN_CENTER + d * (PEN_RADIUS - 30.0) + Vector2(-30, 14 + 16 * k)
			elif portrait and side == 1:   # south: above the fence, not under the dusk panel
				lp = PEN_CENTER + d * (PEN_RADIUS - 30.0) + Vector2(-30, -4 - 16 * k)
			elif side == 2:
				lp = PEN_CENTER + d * (PEN_RADIUS - 36.0) + Vector2(0, -24 + 16 * k)
			elif side == 3:
				lp = PEN_CENTER + d * (PEN_RADIUS - 36.0) + Vector2(-62, -24 + 16 * k)
			draw_string_outline(font, lp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color(0, 0, 0, 0.8))
			draw_string(font, lp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 0.85, 0.6))


func _short_units(units: Dictionary) -> String:
	var abbr := {"walker": "W", "brute": "B", "crow": "C", "bloater": "BL"}
	var out: Array = []
	for ty in ["walker", "brute", "crow", "bloater"]:
		if int(units.get(ty, 0)) > 0:
			out.append("%d%s" % [units[ty], abbr[ty]])
	return " ".join(out)


# ---------------------------------------------------------------- release-1 PvP: army, rival raids, raid events

func _healthy_of(kind: String) -> Node2D:
	for a in animals:
		if a.kind == kind and a.state == AnimalScript.State.HEALTHY:
			return a
	return null


func pen_cap() -> int:
	return PEN_BASE + PEN_PER_FENCE * fence_level


func spike_dps() -> float:
	return SPIKE_DPS + SPIKE_DPS_PER_NIGHT * night


func army_total() -> int:
	return int(army["chicken"]) + int(army["pig"]) + int(army["cow"]) + dead_stock


func week() -> int:
	return (night - 1) / 7


func open_county() -> void:
	if phase != Phase.DAY or overlay != null:
		return
	shop_panel.visible = false
	county_label.text = "Raid prebuilt rival farms with the livestock you've trained (and chained Dead Stock). Units that fall are gone for good. Rivals rebuild every week.\nYour army: %d hen bombers, %d pig brawlers, %d cow tanks, %d Dead Stock.   Raids left today: %d/%d   Ribbons: %d" % [
		army["chicken"], army["pig"], army["cow"], dead_stock, RAIDS_PER_DAY - raids_today, RAIDS_PER_DAY, ribbons]
	for i in RaidScript.RIVALS.size():
		var r: Dictionary = RaidScript.RIVALS[i]
		var b: Button = rival_buttons[i]
		var stars: int = int(rival_best.get(i, 0))
		if night < int(r["unlock"]):
			b.text = "LOCKED until day %d: %s" % [r["unlock"], r["name"]]
			b.disabled = true
		elif int(rival_week.get(i, -1)) == week():
			b.text = "FLATTENED this week: %s\nThey rebuild on day %d" % [r["name"], (week() + 1) * 7 + 1]
			b.disabled = true
		else:
			b.text = "%s  %s\nOwner: %s   Loot up to ~%d coins" % ["*".repeat(stars) + "-".repeat(3 - stars), r["name"], r["owner"], int(r["loot"]) + 30]
			b.disabled = army_total() == 0 or raids_today >= RAIDS_PER_DAY
	county_panel.visible = true


func start_raid(i: int) -> void:
	if army_total() == 0 or raids_today >= RAIDS_PER_DAY or phase != Phase.DAY or overlay != null:
		return
	if night < int(RaidScript.RIVALS[i]["unlock"]) or int(rival_week.get(i, -1)) == week():
		return
	county_panel.visible = false
	var r: Node2D = RaidScript.new()
	r.setup(i, {"chicken": army["chicken"], "pig": army["pig"], "cow": army["cow"], "undead": dead_stock}, week())
	r.auto = autotest_dir != ""
	r.finished.connect(_on_raid_finished)
	_open_overlay(r)


func _on_raid_finished(res: Dictionary) -> void:
	if overlay == null:
		return
	var i: int = int(res["rival"])
	# rivals rebuild weekly; a farm you already hit this week has less left to take
	var key := "%d:%d" % [i, week()]
	var k: int = int(raid_counts.get(key, 0))
	res["loot"] = int(round(float(res["loot"]) * pow(LOOT_REPEAT, k)))
	raid_counts[key] = k + 1
	coins += int(res["loot"])
	ribbons += int(res["stars"]) * 10
	var sv: Dictionary = res["survivors"]
	army["chicken"] = int(sv["chicken"])
	army["pig"] = int(sv["pig"])
	army["cow"] = int(sv["cow"])
	dead_stock = int(sv["undead"])
	rival_best[i] = max(int(rival_best.get(i, 0)), int(res["stars"]))
	if int(res["stars"]) > 0:
		rival_week[i] = week()
	if int(res.get("deployed", 1)) > 0:   # backing out without dropping a unit doesn't use up a raid
		raids_today += 1
		last_raided_rival = i
	_close_overlay()
	shop_panel.visible = true
	popup(PEN_CENTER + Vector2(0, -150), "Raid: +%d coins, %d stars" % [res["loot"], res["stars"]], Color(1, 0.85, 0.3), 20)


func open_fence_fixer() -> void:
	if phase != Phase.DAY or overlay != null:
		return
	var ff: Node2D = FF_SCENE.instantiate()
	ff.embedded = true
	ff.best = ff_best.duplicate()
	ff.exited.connect(_on_ff_exit)
	_open_overlay(ff)


func _on_ff_exit(best: Dictionary) -> void:
	var new_stars := 0
	for k in best.keys():
		new_stars += max(0, int(best[k]) - int(ff_best.get(k, 0)))
	ff_best = best.duplicate()
	var pay := new_stars * 4
	coins += pay
	_close_overlay()
	if pay > 0:
		popup(PEN_CENTER + Vector2(0, -150), "Fence Fixer: %d new stars, +%d coins" % [new_stars, pay], Color(1, 0.85, 0.3), 20)


func _open_overlay(n: Node) -> void:
	overlay = n
	ui.visible = false
	entity_layer.visible = false
	fx_layer.visible = false
	at.erase("ov_t")
	add_child(n)
	queue_redraw()


func _close_overlay() -> void:
	if overlay:
		overlay.queue_free()
	overlay = null
	ui.visible = true
	entity_layer.visible = true
	fx_layer.visible = true
	cam.make_current()
	get_tree().root.content_scale_size = Vector2i(int(screen.x), int(screen.y))
	_refresh_ui()
	queue_redraw()


func _spawn_raid_gang() -> void:
	raid_spawn_at = -1.0
	var r: Dictionary = RaidScript.RIVALS[raid_rival]
	var n: int = 3 + raid_rival
	var side := randi() % 4
	var names := ["NORTH", "SOUTH", "WEST", "EAST"]
	show_banner("raid", 6.0)
	popup(PEN_CENTER + Vector2(0, -230), "%s'S GANG RAIDS FROM THE %s!" % [String(r["owner"]).to_upper(), names[side]], Color(1, 0.6, 0.3), 20)
	var ew := 220.0 if portrait else 660.0
	for i in n:
		var g: Node2D = RaiderScript.new()
		var jitter := randf_range(-120, 120)
		match side:
			0: g.position = Vector2(640 + jitter, 30 - randf() * 60)
			1: g.position = Vector2(640 + jitter, 750 + randf() * 60)
			2: g.position = Vector2(640 - ew - 20 - randf() * 60, 400 + jitter)
			_: g.position = Vector2(640 + ew + 20 + randf() * 60, 400 + jitter)
		entity_layer.add_child(g)
		g.setup(self, night, raid_rival, r["color"])
		zombies.append(g)
		raid_stats["raiders"] += 1


func raider_steal(r: Node2D) -> int:
	var amt: int = mini(int(coins * 0.15), 15 + 10 * raid_rival)
	amt = max(amt, 0)
	coins -= amt
	raid_stats["stolen"] += amt
	popup(r.position + Vector2(0, -30), "-%d coins! stop that %s!" % [amt, "goat" if r.goat else "hog"], Color(1, 0.5, 0.4), 18)
	return amt


func on_raider_escaped(r: Node2D) -> void:
	zombies.erase(r)
	raid_stats["escaped"] += 1
	r.queue_free()


func _dawn_army_and_raids() -> String:
	## upkeep (billed only on days you play a night), raid report, and tomorrow's Gazette
	var t := ""
	var feed := 0
	for k in FEED_PER_SOLDIER:
		feed += int(army[k]) * int(FEED_PER_SOLDIER[k])
	if feed > 0:
		if coins >= feed:
			coins -= feed
			t += "\nArmy feed: -%d coins." % feed
		else:
			var short := feed - coins
			coins = 0
			var deserted := 0
			for k in ["cow", "pig", "chicken"]:
				while short > 0 and army[k] > 0:
					army[k] -= 1
					short -= int(FEED_PER_SOLDIER[k]) * 2
					_add_animal(k)
					deserted += 1
			t += "\nArmy feed short! %d hungry soldier(s) wandered back to the herd." % deserted
	if not raid_stats.is_empty():
		var r: Dictionary = RaidScript.RIVALS[raid_rival]
		last_raid_night = night
		t += "\nRIVAL RAID by %s: %d raiders, %d bonked, %d got away. Stolen %d, recovered %d." % [
			r["owner"], raid_stats["raiders"], raid_stats["beaten"], raid_stats["escaped"], raid_stats["stolen"], raid_stats["recovered"]]
		raid_stats = {}
	# schedule tomorrow's rival raid (announced a day ahead, never in the first days, shield after a raid)
	var unlocked: Array = []
	for i in RaidScript.RIVALS.size():
		if night + 1 >= int(RaidScript.RIVALS[i]["unlock"]):
			unlocked.append(i)
	var chance := 0.0
	if night >= 3 and night - last_raid_night >= 2:
		chance = 0.3 + (0.35 if last_raided_rival >= 0 else 0.0)
	if autotest_dir != "" and night == 1:
		chance = 1.0
	if pending_raid < 0 and randf() < chance and not unlocked.is_empty():
		pending_raid = last_raided_rival if last_raided_rival >= 0 else unlocked.pick_random()
		var rr: Dictionary = RaidScript.RIVALS[pending_raid]
		var lines := ["%s was seen sharpening goats.", "%s bought a lot of bandanas at the feed store.", "%s says your fences look 'chewy'.", "%s is still mad about the pie contest."]
		t += "\n\nDAWN GAZETTE: %s RIVAL RAID EXPECTED TONIGHT. Fix your fences!" % (String(lines.pick_random()) % rr["owner"])
	last_raided_rival = -1
	return t


func _autotest_overlay(delta: float) -> void:
	at["ov_t"] = at.get("ov_t", 0.0) + delta
	var ov_t: float = at["ov_t"]
	if overlay is RaidScript:
		var r = overlay
		if r.t > 7.0:
			_shot("raid_mid")
		if r.done:
			_shot("raid_result")
			at["raid_done_t"] = at.get("raid_done_t", 0.0) + delta
			if at["raid_done_t"] > 1.5:
				at.erase("raid_done_t")
				r._back()
	else:
		var ff = overlay
		if ov_t > 1.0 and not at.has("ff_started"):
			_shot("ff_prep")
			ff._peek()
			ff._start_night()
			ff.speed = 4
			at["ff_started"] = true
		if at.has("ff_started") and ff.mode == 2:
			_shot("ff_result")
			at["ff_done_t"] = at.get("ff_done_t", 0.0) + delta
			if at["ff_done_t"] > 1.0:
				ff.exited.emit(ff.best)


# ---------------------------------------------------------------- sweep bot (headless timer experiment)
## Bot that plays like a decent human: it notices a bite only after `bot_react` seconds, handles one
## bitten animal at a time, cures if it has a dart and is close, otherwise carries it to the barn
## (auto-carry + auto-save), never culls or chains. Buys a dart and repairs each day.

func _sweep_bot(_delta: float) -> void:
	## Sweep bot. Default "human" triage: notices a bite ~bot_react s later (+-25 %), thinks 0.5 s,
	## does ONE thing at a time, pushes the stick ~85 %, carries to the barn or darts it on the spot.
	match phase:
		Phase.DAY:
			_eval_shop()
			bot_focus = null
			bot_notice.clear()
			bot_busy_until = 0.0
			bot_focus_ready_at = 0.0
			start_night()
		Phase.NIGHT:
			farmer.bot_input = Vector2.ZERO
			if bot_triage == "lazy":
				_lazy_tick()
			elif bot_triage == "none" or not _triage_tick():
				_fight_tick()
			if farmer.bot_input != Vector2.ZERO and bot_triage == "human":
				farmer.bot_input = farmer.bot_input.normalized() * bot_stick
		Phase.GAME_OVER:
			_sweep_after_night({})


func _lazy_tick() -> void:
	## the original "drag and auto-fight" player: only reacts to bites it bumps into
	if farmer.carrying:
		_carry_tick()
		return
	var near := _nearest_animal([AnimalScript.State.INFECTED])
	if near:
		if vaccines > 0:
			action_cure(near)
		else:
			action_carry(near)
		return
	var ez := nearest_enemy(farmer.position, 2000.0)
	farmer.bot_input = (ez.position - farmer.position).normalized() if ez and farmer.position.distance_to(ez.position) > 50.0 else Vector2.ZERO


func _carry_tick() -> void:
	if barn_used() >= BARN_SLOTS:
		var c: Node2D = farmer.carrying
		if vaccines > 0:
			action_cure(c)
		elif chain_posts > 0:
			action_chain(c)
		else:
			action_cull(c)
		bot_busy_until = night_time + 0.4
		return
	farmer.bot_input = (BARN_RECT.get_center() - farmer.position).normalized()


func _noticed(a: Node2D) -> bool:
	if bot_triage == "perfect":
		return true
	var rec: Array = bot_notice.get(a, [])
	if rec.is_empty() or float(rec[0]) != float(a.bitten_at):
		rec = [a.bitten_at, a.bitten_at + bot_react * randf_range(0.75, 1.25)]
		bot_notice[a] = rec
	return night_time >= float(rec[1])


func _triage_tick() -> bool:
	## true when triage owns the farmer this frame
	if farmer.carrying:
		_carry_tick()
		return true
	if night_time < bot_busy_until:
		return true
	if bot_focus == null or not is_instance_valid(bot_focus) or bot_focus.state != AnimalScript.State.INFECTED:
		if bot_focus != null:
			bot_busy_until = night_time + (0.0 if bot_triage == "perfect" else 0.4)   # re-orient after an action
			bot_focus = null
			return true
		var best: Node2D = null
		var best_score := INF
		for a in animals:
			if a.state == AnimalScript.State.INFECTED and _noticed(a):
				var d := farmer.position.distance_to(a.position)
				var score: float = d
				if bot_triage == "perfect":
					score = float(a.infect_time) - d / float(farmer.speed)
					if score < 0.0:
						score = 1000.0 + d
				if score < best_score:
					best_score = score
					best = a
		if best == null:
			return false
		bot_focus = best
		bot_focus_ready_at = night_time + (0.0 if bot_triage == "perfect" else 0.5)
	if night_time < bot_focus_ready_at:
		return true
	var dist := farmer.position.distance_to(bot_focus.position)
	var to_barn := bot_focus.position.distance_to(BARN_RECT.get_center())
	if vaccines > 0 and dist < ACTION_RANGE - 4 and (to_barn > 90.0 or barn_used() >= BARN_SLOTS):
		action_cure(bot_focus)
		bot_focus = null
		bot_busy_until = night_time + (0.0 if bot_triage == "perfect" else 0.4)
		return true
	farmer.bot_input = (bot_focus.position - farmer.position).normalized()
	return true


func _fight_tick() -> void:
	var goal := Vector2.ZERO
	var have := false
	match bot_fight:
		"idle":
			goal = BARN_RECT.get_center() + Vector2(0, 50)
			have = true
		"guard":
			var best_d := INF
			for z in zombies:
				if z.position.distance_to(PEN_CENTER) < PEN_RADIUS:
					var d := z.position.distance_to(PEN_CENTER)
					if d < best_d:
						best_d = d
						goal = z.position
						have = true
			for a in animals:
				if a.is_enemy():
					goal = a.position
					have = true
			if not have:
				var low := INF
				for z in zombies:
					if z.get("chewing") == true:
						var seg := segment_at(z.position)
						if fence_hp[seg] < low:
							low = fence_hp[seg]
							goal = PEN_CENTER + (z.position - PEN_CENTER).normalized() * (PEN_RADIUS - 30.0)
							have = true
			if not have and plan_i < plan.size():
				goal = PEN_CENTER + SIDE_DIRS[plan[plan_i]["side"]] * (PEN_RADIUS - 40.0)
				have = true
		_:
			var e := nearest_enemy(farmer.position, 2000.0)
			if e:
				goal = e.position
				have = true
	if have and farmer.position.distance_to(goal) > 40.0:
		farmer.bot_input = (goal - farmer.position).normalized()


func _eval_shop() -> void:
	if bot_shop == "campaign":
		var damaged := false
		for i in SEGMENTS:
			if fence_hp[i] < fence_max:
				damaged = true
		if damaged and coins >= _cost("repair"):
			buy("repair")
		while vaccines < 2 and coins >= _cost("vaccine"):
			buy("vaccine")
		var guard := 0
		while healthy_count() < 6 and coins >= _cost("chicken") and guard < 10:
			guard += 1
			buy("chicken")
		return
	if coins >= _cost("vaccine"):
		buy("vaccine")
	if coins >= _cost("repair"):
		buy("repair")


func _plan_total() -> int:
	var n := 0
	for g in plan:
		for ty in g["units"]:
			n += int(g["units"][ty])
	return n


func _lane_seg(side: int) -> int:
	return segment_at(PEN_CENTER + SIDE_DIRS[side] * PEN_RADIUS)


func _eval_plan() -> void:
	match bot_planner:
		"none":
			pass
		"auto":
			_auto_plan()
		"random":
			var tries := 0
			while planks > 0 and tries < 60:
				tries += 1
				place_piece(randi() % SEGMENTS, ["barricade", "spikes", "scarecrow"].pick_random())
		"spikes_lane":
			for g in plan:
				place_piece(_lane_seg(g["side"]), "spikes")
		"barricade":
			for g in plan:
				place_piece(_lane_seg(g["side"]), "barricade")
			for g in plan:
				for k in [1, -1]:
					place_piece((_lane_seg(g["side"]) + k + SEGMENTS) % SEGMENTS, "barricade")
		"funnel":
			place_piece(10, "scarecrow")
			place_piece(4, "scarecrow")
			for seg in [9, 11, 3, 5]:
				place_piece(seg, "barricade")
		"smart":
			var order := plan.duplicate()
			order.sort_custom(func(x, y): return _threat(x) > _threat(y))
			for g in order:
				var u: Dictionary = g["units"]
				var seg := _lane_seg(g["side"])
				if u.has("crow") and not pieces.values().has("scarecrow"):
					place_piece((seg + 1) % SEGMENTS, "scarecrow")
				if u.has("brute") or u.has("bloater"):
					if not place_piece(seg, "barricade"):
						pass
				elif not place_piece(seg, "spikes"):
					place_piece(seg, "barricade")
			for g in order:
				for k in [1, -1]:
					place_piece((_lane_seg(g["side"]) + k + SEGMENTS) % SEGMENTS, "barricade")


func _threat(g: Dictionary) -> float:
	var v := 0.0
	var u: Dictionary = g["units"]
	for ty in u:
		v += float(u[ty]) * {"walker": 1.0, "brute": 3.0, "crow": 0.5, "bloater": 3.0}[ty]
	return v


func _sweep_after_night(rec: Dictionary) -> void:
	var key := str(turn_timer)
	if not sweep_acc.has(key):
		sweep_acc[key] = {"nights": 0, "bitten": 0, "turned": 0, "saved": 0, "cured": 0, "near": 0, "lat": 0.0, "kept": 0.0, "lost": 0, "spook": 0, "left": 0.0, "tense": 0}
	if not rec.is_empty():
		var s: Dictionary = sweep_acc[key]
		s["nights"] += 1
		s["bitten"] += rec["bitten"]
		s["turned"] += rec["turned"]
		s["saved"] += rec["saved"]
		s["cured"] += rec["cured"]
		s["near"] += rec["near_miss"]
		s["lat"] += rec["avg_latency_s"]
		s["lost"] += rec["lost_infected_at_dawn"]
		s["spook"] += rec["spooked"]
		s["left"] += rec["time_left_share"]
		s["tense"] += rec["tense"]
		s["kept"] += float(rec["herd_at_dawn"]) / max(1, rec["herd_at_dusk"])
	night += 1
	if not rec.is_empty() and night < sweep_start_night + sweep_nights and not animals.is_empty():
		_enter_day()
		return
	print("[run] ", JSON.stringify({"planner": bot_planner, "triage": bot_triage, "fight": bot_fight, "shop": bot_shop,
		"start": sweep_start_night, "last_night": night - 1, "herd_end": healthy_count(), "wiped": healthy_count() == 0, "coins": coins}))
	sweep_run += 1
	if sweep_run >= sweep_runs:
		sweep_run = 0
		sweep_idx += 1
	if sweep_idx >= sweep_values.size():
		_print_sweep()
		get_tree().quit()
		return
	turn_timer = sweep_values[sweep_idx]
	seed(eval_seed + sweep_run)
	_new_game()


func _print_sweep() -> void:
	print("\nBot reaction %.1fs, start night %d, herd %d, %d nights x %d runs per value" % [bot_react, sweep_start_night, sweep_herd, sweep_nights, sweep_runs])
	print("| Turn timer | Nights | Bites/night | Turned % of bites | Saved % | Cured % | Tense (<25% time left) % of saves+cures | Buzzer-beaters (<1s) % | Avg timer left at action | Avg bite->action s | Herd kept at dawn | Spooked/night |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|")
	for v in sweep_values:
		var s: Dictionary = sweep_acc.get(str(v), {})
		if s.is_empty() or s["nights"] == 0:
			continue
		var n: float = s["nights"]
		var b: float = max(1, s["bitten"])
		var sc: float = max(1, s["saved"] + s["cured"])
		print("| %ds | %d | %.1f | %.0f%% | %.0f%% | %.0f%% | %.0f%% | %.0f%% | %.0f%% | %.1f | %.0f%% | %.1f |" % [
			int(v), int(n), s["bitten"] / n, 100.0 * s["turned"] / b, 100.0 * s["saved"] / b, 100.0 * s["cured"] / b,
			100.0 * s["tense"] / sc, 100.0 * s["near"] / sc, 100.0 * s["left"] / n, s["lat"] / n, 100.0 * s["kept"] / n, s["spook"] / n])


# ---------------------------------------------------------------- autotest bot (screenshots)

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
				if night == 1 and not at.has("trained"):
					buy("train_pig")
					buy("train_chicken")
					at["trained"] = true
				if night == 2 and not at.has("county"):
					buy("train_cow")
					buy("train_chicken")
					open_county()
					_shot("county")
					at["county"] = true
					autotest_t = 1.0
					return
				if night == 2 and at.has("county") and not at.has("raided"):
					at["raided"] = true
					start_raid(0)
					return
				if night == 2 and not at.has("ff"):
					at["ff"] = true
					open_fence_fixer()
					return
				if coins >= _cost("vaccine"):
					buy("vaccine")
				if coins >= _cost("repair"):
					buy("repair")
				autotest_t = 0.0
				start_night()
		Phase.DUSK:
			if not at.has("planned%d" % night):
				at["planned%d" % night] = true
				_auto_plan()
				_refresh_dusk()
				autotest_t = 0.0
			if autotest_t > 0.8:
				_shot("dusk%d" % night)
			if autotest_t > 1.4:
				begin_night()
		Phase.NIGHT:
			if night_time > 18.0:
				_shot("night%d" % night)
			for z in zombies:
				if z.get("is_raider") == true and night_time > 22.0:
					_shot("raidnight%d" % night)
					break
			var bitten := _most_urgent_bitten(2000.0)
			if farmer.carrying:
				farmer.bot_input = (BARN_RECT.get_center() - farmer.position).normalized()
			elif bitten:
				if not fan_open and farmer.position.distance_to(bitten.position) < FAN_RANGE - 4:
					_open_fan(Vector2(screen.x / 2, screen.y * 0.8))
					farmer.bot_input = Vector2.ZERO
					_shot("fan%d" % night)
				elif fan_open and fan_age > 0.4:
					_fire_fan("cure" if vaccines > 0 else "carry")
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


# ================================================================ UX eval v2 (eval copy only)

func _btn_style(bg: Color, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(10)
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(4)
	return sb


func _big_button(text: String, h: int, fs: int, bg := Color(0.2, 0.19, 0.17)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", fs)
	b.add_theme_stylebox_override("normal", _btn_style(bg))
	b.add_theme_stylebox_override("hover", _btn_style(bg.lightened(0.12)))
	b.add_theme_stylebox_override("pressed", _btn_style(bg.darkened(0.2)))
	b.add_theme_stylebox_override("disabled", _btn_style(Color(0.16, 0.15, 0.14, 0.9)))
	b.add_theme_color_override("font_disabled_color", Color(0.55, 0.52, 0.48))
	return b


func _build_ui_v2() -> void:
	for l in [top_label, timer_label]:
		l.add_theme_font_size_override("font_size", 28)
		l.add_theme_constant_override("outline_size", 8)
	timer_label.position = Vector2(14, 48)
	hint_label.add_theme_font_size_override("font_size", 24)
	hint_label.add_theme_constant_override("outline_size", 7)
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_label.custom_minimum_size = Vector2(screen.x - 28, 0)
	hint_label.size = Vector2(screen.x - 28, 0)
	hint_label.position = Vector2(14, screen.y - 140)
	keys_label = Label.new()
	keys_label.add_theme_font_size_override("font_size", 18)
	keys_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8))
	keys_label.add_theme_color_override("font_outline_color", Color.BLACK)
	keys_label.add_theme_constant_override("outline_size", 5)
	keys_label.position = Vector2(14, screen.y - 32)
	keys_label.visible = not DisplayServer.is_touchscreen_available()
	ui.add_child(keys_label)
	# tip banner (replaces 1.8 s floating tips that ran off-screen)
	banner_panel = _panel(Vector2(16, 112), Vector2(screen.x - 32, 0))
	var bsb: StyleBoxFlat = banner_panel.get_theme_stylebox("panel").duplicate()
	bsb.bg_color = Color(0.16, 0.08, 0.2, 0.93)
	bsb.border_color = Color(0.85, 0.5, 1.0)
	bsb.set_border_width_all(4)
	banner_panel.add_theme_stylebox_override("panel", bsb)
	banner_label = Label.new()
	banner_label.add_theme_font_size_override("font_size", 25)
	banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner_label.custom_minimum_size = Vector2(screen.x - 64, 0)
	banner_panel.add_child(banner_label)
	banner_panel.visible = false
	# ---- farm store v2: 2 columns, 92 px (46 dp) rows, short benefit line, progressive unlocks
	shop_panel.queue_free()
	shop_buttons.clear()
	shop_panel = _panel(Vector2(16, screen.y - 600), Vector2(screen.x - 32, 0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	shop_panel.add_child(v)
	var head := Label.new()
	head.text = "FARM STORE: get ready for tonight"
	head.add_theme_font_size_override("font_size", 26)
	head.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	v.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	v.add_child(grid)
	for item in ["vaccine", "planks", "repair", "chicken", "fork", "fence", "pig", "cow", "train_chicken", "train_pig", "train_cow"]:
		var btn := _big_button("", 96, 21)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(buy.bind(item))
		grid.add_child(btn)
		shop_buttons[item] = btn
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 10)
	v.add_child(nav)
	for pair in [["RIVAL RAIDS", open_county], ["FENCE FIXER\npuzzles, +coins", open_fence_fixer]]:
		var nb2 := _big_button(pair[0], 96, 22)
		nb2.name = "Nav" + str(nav.get_child_count())
		nb2.pressed.connect(pair[1])
		nav.add_child(nb2)
	goal_label = Label.new()
	goal_label.add_theme_font_size_override("font_size", 22)
	goal_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	goal_label.custom_minimum_size = Vector2(screen.x - 70, 0)
	v.add_child(goal_label)
	var start := _big_button("START NIGHT  >", 110, 34, Color(0.24, 0.6, 0.25))
	start.pressed.connect(start_night)
	v.add_child(start)
	# ---- dusk panel v2
	dusk_panel.queue_free()
	piece_buttons.clear()
	dusk_panel = _panel(Vector2(16, screen.y - 392), Vector2(screen.x - 32, 0))
	var dkv := VBoxContainer.new()
	dkv.add_theme_constant_override("separation", 8)
	dusk_panel.add_child(dkv)
	planks_label = Label.new()
	planks_label.add_theme_font_size_override("font_size", 26)
	planks_label.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	dkv.add_child(planks_label)
	var pr := HBoxContainer.new()
	pr.add_theme_constant_override("separation", 10)
	dkv.add_child(pr)
	for pc in ["barricade", "spikes", "scarecrow"]:
		var pb := _big_button("", 100, 20)
		pb.pressed.connect(func(): selected_piece = pc; _refresh_dusk())
		pr.add_child(pb)
		piece_buttons[pc] = pb
	var info := Label.new()
	info.name = "PieceInfo"
	info.add_theme_font_size_override("font_size", 22)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size = Vector2(screen.x - 70, 64)
	dkv.add_child(info)
	var dr := HBoxContainer.new()
	dr.add_theme_constant_override("separation", 10)
	dkv.add_child(dr)
	auto_btn = _big_button("AUTO-PLAN", 96, 22)
	auto_btn.size_flags_horizontal = Control.SIZE_FILL
	auto_btn.custom_minimum_size = Vector2(200, 96)
	auto_btn.pressed.connect(func():
		for sg in pieces:
			planks += int(PIECE_COST[pieces[sg]])
		pieces.clear()
		scarecrow_hp.clear()
		_auto_plan()
		_refresh_dusk())
	dr.add_child(auto_btn)
	var go := _big_button("HOLD THE LINE  >", 96, 30, Color(0.24, 0.6, 0.25))
	go.pressed.connect(begin_night)
	dr.add_child(go)
	dusk_panel.visible = false
	forecast_label.add_theme_font_size_override("font_size", 26)
	forecast_label.add_theme_constant_override("outline_size", 8)
	forecast_label.position = Vector2(14, 48)
	dawn_label.add_theme_font_size_override("font_size", 24)
	over_label.add_theme_font_size_override("font_size", 24)
	over_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	over_label.custom_minimum_size = Vector2(screen.x - 100, 0)
	for pnl in [dawn_panel, over_panel]:
		for b in pnl.find_children("*", "Button", true, false):
			b.add_theme_font_size_override("font_size", 30)
			b.custom_minimum_size = Vector2(0, 104)
			b.add_theme_stylebox_override("normal", _btn_style(Color(0.24, 0.6, 0.25)))
	county_label.add_theme_font_size_override("font_size", 21)
	for rb2 in rival_buttons:
		rb2.custom_minimum_size = Vector2(0, 100)
		rb2.add_theme_font_size_override("font_size", 21)


func show_banner(key: String, secs := 6.0, once := true) -> void:
	if not ux2 or banner_panel == null or not sweep_values.is_empty():
		return
	if once and shown_tips.has(key):
		return
	shown_tips[key] = true
	banner_label.text = TIPS_V2.get(key, key)
	banner_panel.visible = true
	banner_panel.size = Vector2(screen.x - 32, 0)
	banner_t = secs


func _refresh_ui_v2() -> void:
	var names := {
		"repair": ["Repair fences", "Fix all broken sections"],
		"vaccine": ["Vaccine dart", "Cures 1 bitten animal (have %d)" % vaccines],
		"fork": ["Pitchfork Lv %d" % (fork_level + 1), "+1 swing before you tire"],
		"fence": ["Fences Lv %d" % (fence_level + 1), "Tougher, +1 plank a night"],
		"chicken": ["Chicken", "Pays 3 coins each dawn"],
		"pig": ["Pig", "Pays 6 coins each dawn"],
		"cow": ["Cow", "Pays 10 coins each dawn"],
		"planks": ["+3 planks", "Extra traps for tonight"],
		"train_chicken": ["Hen bomber", "Herd hen > raid unit"],
		"train_pig": ["Pig brawler", "Herd pig > raid unit"],
		"train_cow": ["Cow tank", "Herd cow > raid unit"],
	}
	var unlock := {"vaccine": 1, "planks": 1, "repair": 1, "chicken": 1, "fork": 2, "fence": 2, "pig": 2, "cow": 2,
		"train_chicken": 3, "train_pig": 3, "train_cow": 3}
	for item in shop_buttons:
		var btn: Button = shop_buttons[item]
		var nm: Array = names[item]
		btn.text = "%s   %d coins\n%s" % [nm[0], _cost(item), nm[1]]
		btn.visible = night >= int(unlock[item])
		btn.disabled = coins < _cost(item)
		if item == "repair":
			var dmg := false
			for i in SEGMENTS:
				if fence_hp[i] < fence_max:
					dmg = true
			btn.disabled = btn.disabled or not dmg
			if not dmg:
				btn.text = "Repair fences\nAll fences OK"
		if item.begins_with("train_") and _healthy_of(item.trim_prefix("train_")) == null:
			btn.disabled = true
	var nav0: Button = shop_panel.find_child("Nav0", true, false)
	if nav0:
		nav0.visible = night >= 3
		nav0.text = "RIVAL RAIDS\n%d raids left today" % (RAIDS_PER_DAY - raids_today)
	if goal_label:
		goal_label.text = "Tonight: zombies come for your %d animals. Every animal alive at sunrise pays coins." % healthy_count()
		if pending_raid >= 0:
			goal_label.text += "\nGAZETTE: a rival gang raids tonight!"


func _forecast_summary() -> String:
	var tot := {}
	var sides := []
	for g in plan:
		for ty in g["units"]:
			tot[ty] = int(tot.get(ty, 0)) + int(g["units"][ty])
		var sn: String = SIDE_NAMES[g["side"]]
		if not sides.has(sn):
			sides.append(sn)
	return "TONIGHT: %s\nfrom the %s" % [_units_text(tot), ", ".join(sides)]


func _wave_label(units: Dictionary) -> String:
	var out: Array = []
	for ty in ["walker", "brute", "crow", "bloater"]:
		var n: int = int(units.get(ty, 0))
		if n > 0:
			out.append(("%d %s%s" % [n, ty, "s" if n > 1 else ""]) if ty == "walker" else ("+%d %s" % [n, ty.to_upper()]))
	return " ".join(out)


func _refresh_dusk_v2() -> void:
	forecast_label.text = _forecast_summary()
	if pending_raid >= 0:
		forecast_label.text += "\n+ RIVAL RAID at 0:16 (they steal coins)"
	planks_label.text = "DUSK: %d plank%s left. Tap a glowing fence spot." % [planks, "" if planks == 1 else "s"]
	for pc in piece_buttons:
		var b: Button = piece_buttons[pc]
		b.text = "%s\n%s" % [PIECE_V2[pc][0], PIECE_V2[pc][1]]
		var sel: bool = pc == selected_piece
		b.add_theme_stylebox_override("normal", _btn_style(Color(0.3, 0.27, 0.18) if sel else Color(0.2, 0.19, 0.17), Color(1, 0.85, 0.3) if sel else Color(0, 0, 0, 0)))
		b.disabled = planks < int(PIECE_COST[pc]) and not sel
	var info: Label = dusk_panel.find_child("PieceInfo", true, false)
	if info:
		# a zombie type the player has never met gets the whole info line
		var newest := ""
		for g in plan:
			for ty in g["units"]:
				if ty != "walker" and not seen_types.has(ty):
					newest = ty
		if newest != "":
			info.text = TIPS_V2[newest]
			info.add_theme_color_override("font_color", Color(1, 0.75, 1))
		else:
			info.remove_theme_color_override("font_color")
			info.text = {
				"barricade": "BARRICADE: that fence section is twice as tough tonight. Best vs BRUTES.",
				"spikes": "SPIKES: hurt every zombie chewing that section. Best vs WALKERS.",
				"scarecrow": "SCARECROW: crows peck it first, and hordes nearby walk to it. Put SPIKES next to it.",
			}[selected_piece]


func _dusk_camera(on: bool) -> void:
	if not ux2:
		return
	if on:
		cam.zoom = Vector2(1.15, 1.15)
		cam.position = PEN_CENTER + Vector2(0, 96)
	else:
		cam.zoom = Vector2(1.5, 1.5)
		cam.position = PEN_CENTER + Vector2(0, 40)


func _wave_segments() -> Dictionary:
	var segs := {}
	for g in plan:
		# a side's arrow sits on the boundary between two sections; hordes jitter onto both
		for off in [-0.2, 0.2]:
			segs[segment_at(PEN_CENTER + SIDE_DIRS[g["side"]].rotated(off) * PEN_RADIUS)] = true
	return segs


func _update_hint_v2() -> void:
	var keys := ""
	match phase:
		Phase.DAY:
			hint_label.text = ""
			keys = "PC: Space = start night"
		Phase.DUSK:
			hint_label.text = ""
			keys = "PC: click a fence spot to place, again to remove. Space = start"
		Phase.NIGHT:
			var bitten := _most_urgent_bitten(2000.0)
			if farmer.carrying:
				hint_label.text = "Carry it into the BARN glow to save it (barn %d/%d)." % [barn_used(), BARN_SLOTS]
			elif bitten:
				hint_label.text = "%s bitten! Walk into it, or lift your finger next to it for options." % String(bitten.kind).capitalize()
			else:
				hint_label.text = "Drag anywhere to move. Your pitchfork swings by itself."
			keys = "PC: WASD move   E carry   Q cure   X send upstate   C chain"
		Phase.DAWN:
			hint_label.text = ""
			keys = "PC: Space = next day"
		_:
			hint_label.text = ""
	if keys_label:
		keys_label.text = keys


func _draw_wave_labels_v2(font: Font) -> void:
	var by_side := {}
	for i in range(plan_i if phase == Phase.NIGHT else 0, plan.size()):
		var g: Dictionary = plan[i]
		if not by_side.has(g["side"]):
			by_side[g["side"]] = []
		by_side[g["side"]].append(g)
	var order := ["1st", "2nd", "3rd", "4th", "5th", "6th", "7th"]
	for side in by_side:
		var d: Vector2 = SIDE_DIRS[side]
		var tip := PEN_CENTER + d * (PEN_RADIUS + 14.0)
		var tail := PEN_CENTER + d * (PEN_RADIUS + 60.0)
		var col := Color(1, 0.5, 0.35, 0.95 if phase == Phase.DUSK else 0.5)
		draw_line(tail, tip, col, 6.0)
		draw_colored_polygon(PackedVector2Array([tip, tip - d * 18.0 + d.orthogonal() * 12.0, tip - d * 18.0 - d.orthogonal() * 12.0]), col)
		if phase == Phase.NIGHT:
			continue
		var lines: Array = []
		for g in by_side[side]:
			lines.append("%s 0:%02d  %s" % [order[plan.find(g)], int(g["t"]), _wave_label(g["units"])])
		var fs := 19 if side < 2 else 17
		for k in lines.size():
			var w := font.get_string_size(lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var lp: Vector2
			match side:
				0: lp = PEN_CENTER + Vector2(-w / 2, -PEN_RADIUS - 66 - 22 * (lines.size() - 1 - k))
				1: lp = PEN_CENTER + Vector2(-w / 2, PEN_RADIUS + 78 + 22 * k)
				2: lp = PEN_CENTER + Vector2(-PEN_RADIUS + 30, -74 - 24 * (lines.size() - 1 - k))
				_: lp = PEN_CENTER + Vector2(PEN_RADIUS - 30 - w, -74 - 24 * (lines.size() - 1 - k))
			var bg := Rect2(lp + Vector2(-5, -17), Vector2(w + 10, 23))
			draw_rect(bg, Color(0, 0, 0, 0.55))
			draw_string(font, lp, lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.88, 0.65))


const FAN_LAYOUT_V2 := {"carry": Vector2(-150, -70), "cure": Vector2(-62, -185), "chain": Vector2(62, -185), "cull": Vector2(150, -70)}
const FAN_R_V2 := 58.0

func _draw_fan_v2(o: Node2D) -> void:
	var font := ThemeDB.fallback_font
	var cols := {"carry": Color(0.30, 0.75, 0.29), "cure": Color(0.25, 0.71, 1.0), "chain": Color(0.6, 0.45, 0.85), "cull": Color(0.9, 0.28, 0.23)}
	var labels := {"carry": "SAVE\nto barn", "cure": "CURE\n%d dart%s" % [vaccines, "" if vaccines == 1 else "s"],
		"chain": "CHAIN\n%d post%s" % [chain_posts, "" if chain_posts == 1 else "s"], "cull": "HOLD\nupstate"}
	if vaccines <= 0:
		labels["cure"] = "CURE\nno darts"
	for k in FAN_LAYOUT_V2:
		var c: Vector2 = fan_pos + FAN_LAYOUT_V2[k]
		var col: Color = cols[k]
		if not _fan_enabled(k):
			col = Color(0.4, 0.4, 0.4)
		o.draw_circle(c + Vector2(0, 6), FAN_R_V2, col.darkened(0.45))
		o.draw_circle(c, FAN_R_V2, col)
		o.draw_arc(c, FAN_R_V2, 0, TAU, 40, Color(1, 1, 1, 0.8), 3.0)
		if k == "cull" and fan_hold_btn == "cull":
			o.draw_arc(c, FAN_R_V2 + 7, -PI / 2, -PI / 2 + TAU * clampf(fan_hold_t / CULL_HOLD, 0, 1), 32, Color.WHITE, 7.0)
		var lines: PackedStringArray = labels[k].split("\n")
		for li in lines.size():
			var fs := 24 if li == 0 else 18
			var w := font.get_string_size(lines[li], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var y := -2.0 if li == 0 else 22.0
			o.draw_string_outline(font, c + Vector2(-w / 2, y), lines[li], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color(0, 0, 0, 0.8))
			o.draw_string(font, c + Vector2(-w / 2, y), lines[li], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
	if fan_target and is_instance_valid(fan_target):
		var tl := "%s turns in %ds" % [String(fan_target.kind).capitalize(), int(ceil(fan_target.infect_time))]
		var w2 := font.get_string_size(tl, HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
		o.draw_string_outline(font, fan_pos + Vector2(-w2 / 2, -262), tl, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, 7, Color.BLACK)
		o.draw_string(font, fan_pos + Vector2(-w2 / 2, -262), tl, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color(1, 0.8, 0.3))
		# line from the fan to the animal it acts on
		var tp: Vector2 = get_canvas_transform() * fan_target.position
		o.draw_line(fan_pos + Vector2(0, -250), tp, Color(1, 0.8, 0.3, 0.6), 3.0)


func _dawn_text_v2(rec: Dictionary, produce: int, bonus: int, total: int, lost_infected: int, burned: int, extra: String) -> String:
	var kept: int = animals.size()
	var start: int = int(rec["herd_at_dusk"])
	var stars := 3 if kept >= start else (2 if kept * 3 >= start * 2 else (1 if kept > 0 else 0))
	var t := "Night %d over.  Herd kept %d / %d   %s\n\n" % [night, kept, start, "*".repeat(stars) + "-".repeat(3 - stars)]
	t += "+%d coins from your animals\n+%d coins for zombies bonked\n= +%d coins\n" % [produce, bonus, total]
	var saved: int = stats["saved"] + stats["cured"]
	if saved > 0:
		t += "\nYou saved %d bitten animal%s. Nice.\n" % [saved, "" if saved == 1 else "s"]
	var lost: int = start - kept
	if lost > 0:
		t += "\nLost %d: %d turned into zombies%s.\n" % [lost, stats["turned"], (", %d still bitten at sunrise" % lost_infected) if lost_infected > 0 else ""]
	# one tip, aimed at the biggest mistake of the night
	var tip := ""
	if stats["turned"] > 0 and stats["saved"] + stats["cured"] == 0:
		tip = "TIP: a bitten animal turns in 8 s. Walk into it and carry it into the BARN."
	elif stats["turned"] > 0 and vaccines > 0:
		tip = "TIP: you still had %d dart%s. Lift your finger next to a bitten animal and tap CURE." % [vaccines, "" if vaccines == 1 else "s"]
	elif pieces.is_empty() and rec.get("planned", true) == false:
		tip = "TIP: place planks at dusk on the glowing fence spots."
	if tip != "":
		t += "\n" + tip + "\n"
	t += extra.replace("\nArmy feed:", "\nArmy ate:")
	return t
