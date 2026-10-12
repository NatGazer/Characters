extends RefCounted
## One physical gun owns one state. Carrier changes never create or refill it.
## Weapon's old public ammo properties are views of this object.

var item_id := ""
var initialized := false
var ammo := 0
var reserve := -1
var cooldown := 0.0
var reloading := false
var reload_progress := 0.0
var bloom := 0.0
var heat := 0.0
var energy_wh := 0.0
var condition := 1.0
var wear := 0.0
var jammed := false
var shots_fired := 0

func initialize(mag_size: int, loaded: bool) -> void:
	if initialized: return
	initialized = true
	item_id = "gun_%d_%d" % [Time.get_ticks_usec(), get_instance_id()]
	ammo = mag_size if loaded else 0

func advance(delta: float, recovery: float, cooling: float) -> void:
	if not is_finite(delta) or delta <= 0.0: return
	cooldown = maxf(0.0, cooldown - delta)
	bloom = move_toward(bloom, 0.0, recovery * delta)
	heat = move_toward(heat, 0.0, cooling * delta)

func ready(shot_energy_wh: float) -> bool:
	return initialized and not reloading and cooldown <= 0.0 and ammo > 0 and condition > 0.0 and not jammed and energy_wh >= shot_energy_wh

func consume(interval: float, extra_bloom: float, max_bloom: float, shot_heat: float, shot_energy_wh: float, shot_wear: float) -> void:
	ammo -= 1
	energy_wh -= shot_energy_wh
	cooldown = interval
	bloom = minf(bloom + extra_bloom, max_bloom)
	heat += shot_heat
	wear = clampf(wear + shot_wear, 0.0, 1.0)
	jammed = jammed or wear >= 1.0
	shots_fired += 1

func serialize() -> Dictionary:
	return {"version": 1, "item_id": item_id, "ammo": ammo, "reserve": reserve, "cooldown": cooldown,
		"reloading": reloading, "reload_progress": reload_progress, "bloom": bloom, "heat": heat,
		"energy_wh": energy_wh, "condition": condition, "wear": wear, "jammed": jammed, "shots_fired": shots_fired}

func restore(data: Dictionary, mag_size: int) -> bool:
	if mag_size < 1 or data.get("version", 1) != 1: return false
	for key: String in ["reloading", "jammed"]:
		if data.has(key) and not data[key] is bool: return false
	if data.has("item_id") and not data.item_id is String: return false
	# Missing legacy fields mean no stored energy/heat, never a new full magazine.
	for key: String in ["ammo", "reserve", "cooldown", "reload_progress", "bloom", "heat", "energy_wh", "condition", "wear", "shots_fired"]:
		var value: Variant = data.get(key, 1.0 if key == "condition" else 0)
		if not (value is int or value is float) or not is_finite(float(value)): return false
		if float(value) < (-1.0 if key == "reserve" else 0.0): return false
		if key in ["ammo", "reserve", "shots_fired"] and float(value) != floorf(float(value)): return false
	if int(data.get("ammo", 0)) > mag_size or float(data.get("condition", 1.0)) > 1.0 or float(data.get("wear", 0.0)) > 1.0: return false
	if float(data.get("reload_progress", 0.0)) > 1.0: return false
	item_id = str(data.get("item_id", ""))
	if item_id.is_empty(): item_id = "legacy_gun_%d_%d" % [Time.get_ticks_usec(), get_instance_id()]
	initialized = true
	ammo = int(data.get("ammo", 0))
	reserve = int(data.get("reserve", 0))
	cooldown = float(data.get("cooldown", 0.0))
	reloading = bool(data.get("reloading", false))
	reload_progress = float(data.get("reload_progress", 0.0))
	bloom = float(data.get("bloom", 0.0))
	heat = float(data.get("heat", 0.0))
	energy_wh = float(data.get("energy_wh", 0.0))
	condition = float(data.get("condition", 1.0))
	wear = float(data.get("wear", 0.0))
	jammed = bool(data.get("jammed", false))
	shots_fired = int(data.get("shots_fired", 0))
	return true
