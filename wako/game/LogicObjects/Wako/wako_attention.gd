extends RefCounted
## Shared attention board plus one per-Wako chooser.
##
## The board is a small static ring of REAL events posted once by their owner
## (admitted work contacts, job completions, flips, landings, catches, splashes,
## hits, warnings, voices, dances...). Nothing scans the world per tick: each
## Wako scores the few live entries, the seen player and a couple of personal
## idle scan points on its existing perception cadence (~4 Hz, desynchronised),
## with novelty, salience, distance, facing and personality traits. Hysteresis,
## random fixation holds and a crowd penalty on shared targets keep a crowd
## from staring in sync. At most one visibility ray is spent per switch; it
## targets the event's own actor/part, and a rejected or vanished target is
## never kept (fall back to a candidate that needs no ray, or let go).
const RING := 40
const RADIUS := 11.0
const PLAYER_KEY := 1
const SCAN_KEY := 2
static var _ring: Array[Dictionary] = []
static var _head := 0
static var _serial := 0
static var _tree_id := 0
# Longest ttl posted to this ring: a scan walks newest -> oldest and stops
# at the first entry older than this (expired entries are never scored).
static var _max_ttl := 0.0
# Target key -> number of Wako currently attending it (crowd desync).
static var _watchers: Dictionary = {}

var worker: RigidBody3D
## Current attention result, consumed by the eyes.
var point := Vector3.INF
var node: WeakRef
var kind: StringName = &""
var serial := 0
var strength := 0.0
var novel := false
var _key := 0
var _hold := 0.0
var _last_scan := -1.0
var _seen: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _social := 1.0
var _curious := 1.0
var _span := 1.0
# Personal interest span for shared events: novelty fades and the event is
# dropped at a personal fraction of its ttl, so a crowd that turned to one
# event lets go of it one by one instead of all at once.
var _event_span := 1.0
var _player_last := Vector3.INF
var _player_speed := 0.0
var _scan_point := Vector3.INF
var _scan_count := 0
var _blocked: Dictionary = {}
var profile_scans := 0
var profile_usec := 0

static func now() -> float:
	return float(Engine.get_physics_frames())/float(Engine.physics_ticks_per_second)

## Post one real event. owner: the Wako (or node) it belongs to; follow: an
## optional node whose live position the watchers track (a dancer, a tool);
## see: the body a visibility ray may hit and still count as seeing the event
## (default: follow, else the owner), e.g. the part a work contact lands on.
static func post(owner: Node3D, event_kind: StringName, position: Vector3, salience: float, ttl := 1.6, follow: Node3D = null, see: Node3D = null) -> void:
	if not is_instance_valid(owner) or not owner.is_inside_tree() or not position.is_finite(): return
	var tree_id := owner.get_tree().get_instance_id()
	if tree_id!=_tree_id:
		_ring.clear()
		_head = 0
		_watchers.clear()
		_max_ttl = 0.0
		_tree_id = tree_id
	_serial += 1
	var entry := {"serial":_serial,"kind":event_kind,"pos":position,"sal":salience,"time":now(),"ttl":ttl,
		"owner":owner.get_instance_id(),"node":weakref(follow) if follow else null,
		"see":weakref(see if see else follow if follow else owner)}
	if _ring.size()<RING: _ring.append(entry)
	else: _ring[_head] = entry
	_head = (_head+1)%RING
	_max_ttl = maxf(_max_ttl,ttl)

static func recent(event_kind: StringName, position: Vector3, radius: float, max_age: float) -> int:
	# Bounded read used by personality to avoid duplicate posts.
	var t := now()
	var count := 0
	for entry: Dictionary in _ring:
		if entry.kind==event_kind and t-float(entry.time)<=max_age and position.distance_squared_to(entry.pos)<=radius*radius: count += 1
	return count

func setup(owner: RigidBody3D) -> void:
	worker = owner
	_rng.seed = absi(str(worker.worker_id).hash())+31337
	_social = _rng.randf_range(.7,1.3)
	_curious = _rng.randf_range(.75,1.3)
	_span = _rng.randf_range(.75,1.35)
	_event_span = _rng.randf_range(.55,1.15)

func release() -> void:
	if _key==0 and not point.is_finite(): return
	_set_watch(0)
	point = Vector3.INF
	node = null
	kind = &""
	strength = 0.0
	serial += 1

func _notification(what: int) -> void:
	# A freed Wako must not keep counting as a watcher of its last target.
	if what!=NOTIFICATION_PREDELETE or _key==0 or not _watchers.has(_key): return
	_watchers[_key] = int(_watchers[_key])-1
	if int(_watchers[_key])<=0: _watchers.erase(_key)

func _set_watch(key: int) -> void:
	if _key==key: return
	if _key!=0 and _watchers.has(_key):
		_watchers[_key] = int(_watchers[_key])-1
		if int(_watchers[_key])<=0: _watchers.erase(_key)
	if key!=0: _watchers[key] = int(_watchers.get(key,0))+1
	_key = key

## One scoring pass, on the personality's perception cadence. player: the
## already-visible player (or null). can_see: Callable(point, target) for the
## single switch ray.
func scan(player: Node3D, can_see: Callable) -> void:
	# Far/off-screen faces think at half the perception rate.
	_scan_count += 1
	var eyes: RefCounted = worker.get("eyes")
	if eyes and int(eyes._lod)>=2 and _scan_count%2==1: return
	var began := Time.get_ticks_usec()
	var t := now()
	var dt := clampf(t-_last_scan,0.0,1.0) if _last_scan>=0.0 else 0.0
	_last_scan = t
	_hold -= dt
	var head: Vector3 = worker._visual_head_point if worker._visual_head_point.is_finite() else worker.global_position+Vector3.UP*.3
	var forward: Vector3 = -worker._model.global_basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared()>.0001 else Vector3.FORWARD
	var best_score := 0.0
	var best_key := 0
	var best_point := Vector3.INF
	var best_node: Node3D
	var best_kind: StringName = &""
	var best_novel := false
	var best_see: WeakRef
	# Fallback candidate that needs no ray (the seen player, a scan point),
	# and the current target's fresh state if it is still present.
	var safe_score := 0.0
	var safe := {}
	var current := {}
	# The seen player: a social target, livelier when moving, near or making
	# eye contact through the camera; damped when the crowd already watches.
	if is_instance_valid(player):
		var at: Vector3 = player.global_position+Vector3.UP*.6
		if _player_last.is_finite() and dt>.0: _player_speed = lerpf(_player_speed,(at-_player_last).length()/dt,.5)
		_player_last = at
		var interest := .45*_social
		if _player_speed>.6: interest += .25
		var distance := head.distance_to(at)
		if distance<3.0: interest += .2
		var camera: Camera3D = worker.get_viewport().get_camera_3d() if worker.is_inside_tree() else null
		if camera and camera.global_position.distance_squared_to(head)<49.0:
			var view := (head-camera.global_position).normalized()
			if view.dot(-camera.global_basis.z)>.975: interest += .3
		var others := int(_watchers.get(PLAYER_KEY,0))-(1 if _key==PLAYER_KEY else 0)
		interest /= 1.0+.7*maxf(others,0)
		var score := _score(interest,PLAYER_KEY,at,head,forward,distance,t)
		var candidate := {"key":PLAYER_KEY,"score":score,"point":at,"node":player,"kind":&"player","novel":false}
		if _key==PLAYER_KEY: current = candidate
		if score>safe_score: safe_score = score; safe = candidate
		if score>best_score:
			best_score = score; best_key = PLAYER_KEY; best_point = at; best_node = player; best_kind = &"player"; best_novel = false; best_see = null
	else:
		_player_last = Vector3.INF
	# Recent real events on the shared board (bounded ring), newest first;
	# the walk stops at the first entry older than any ttl.
	var me := worker.get_instance_id()
	var count := _ring.size()
	for step in count:
		var entry: Dictionary = _ring[(_head-1-step+count)%count]
		var age: float = t-float(entry.time)
		if age>_max_ttl: break
		var span: float = float(entry.ttl)*_event_span
		if age>span or age<0.0 or int(entry.owner)==me: continue
		var at: Vector3 = entry.pos
		var follow: Node3D = entry.node.get_ref() if entry.node else null
		# An event posted with an actor/part that has since been freed is no
		# longer a real current target (no staring at its stale position).
		if entry.node and not is_instance_valid(follow): continue
		if is_instance_valid(follow):
			var face: Variant = follow.get("_visual_head_point")
			at = face if face is Vector3 and face.is_finite() else follow.global_position
		var distance := head.distance_to(at)
		if distance>RADIUS: continue
		var novelty := 1.0-age/span
		var key: int = 1000+int(entry.serial)
		if is_instance_valid(follow): key = follow.get_instance_id()
		var interest: float = float(entry.sal)*(.45+.55*novelty)*_curious
		var others := int(_watchers.get(key,0))-(1 if _key==key else 0)
		interest /= 1.0+.45*maxf(others,0)
		# An event this Wako could not see a moment ago is not re-tried at once.
		if t<float(_blocked.get(key,-1.0)): continue
		var score := _score(interest,key,at,head,forward,distance,t)
		if key==_key: current = {"key":key,"score":score,"point":at,"node":follow,"kind":entry.kind,"novel":novelty>.55}
		if score>best_score:
			best_score = score; best_key = key; best_point = at; best_node = follow; best_kind = entry.kind
			best_novel = novelty>.55; best_see = entry.get("see")
	# Personal idle scan point (ground ahead, horizon to a side, sky).
	if not _scan_point.is_finite() or (_key==SCAN_KEY and _hold<=0.0):
		_scan_point = _new_scan_point(head,forward)
		if _key==SCAN_KEY:
			# A new look-around point is a new fixation (eyes saccade to it).
			serial += 1
			_hold = .9*_span*_rng.randf_range(.6,1.5)
	var scan_score := _score(.2,SCAN_KEY,_scan_point,head,forward,head.distance_to(_scan_point),t)
	var scan_candidate := {"key":SCAN_KEY,"score":scan_score,"point":_scan_point,"node":null,"kind":&"scan","novel":false}
	if _key==SCAN_KEY: current = scan_candidate
	if scan_score>safe_score: safe_score = scan_score; safe = scan_candidate
	if scan_score>best_score:
		best_score = scan_score; best_key = SCAN_KEY; best_point = _scan_point; best_node = null; best_kind = &"scan"; best_novel = false; best_see = null
	if best_key!=0 and best_key!=_key and best_see:
		# One visibility ray per switch toward another actor's event; a hit
		# on that actor (or the part it works on) counts as seen.
		var target: Node3D = best_see.get_ref()
		if is_instance_valid(target) and can_see.is_valid() and not can_see.call(best_point,target):
			_blocked[best_key] = t+1.0
			if _blocked.size()>16:
				for old: int in _blocked.keys():
					if float(_blocked[old])<t: _blocked.erase(old)
			# Fall back to the best target that needs no ray (or keep the
			# current one if it is still really there).
			var fallback: Dictionary = current if not current.is_empty() and float(current.score)>=safe_score else safe
			best_key = 0
			if not fallback.is_empty():
				best_key = int(fallback.key); best_score = float(fallback.score); best_point = fallback.point
				best_node = fallback.node; best_kind = fallback.kind; best_novel = bool(fallback.novel)
	if best_key!=0 and best_key!=_key:
		_seen[_key] = t
		if _seen.size()>24:
			for old: int in _seen.keys():
				if t-float(_seen[old])>8.0: _seen.erase(old)
		_set_watch(best_key)
		serial += 1
		kind = best_kind
		novel = best_novel
		var base_hold := 1.6 if best_kind==&"player" else .9 if best_kind==&"scan" else .75
		_hold = base_hold*_span*_rng.randf_range(.6,1.5)
		if best_kind==&"scan": _scan_point = best_point
	if best_key==_key and best_key!=0:
		point = best_point
		node = weakref(best_node) if best_node else null
		strength = clampf(best_score,0.0,1.0)
	elif best_key==0 and _key!=0:
		# Nothing real to switch to: keep the current target only while it is
		# still present this scan (a player out of sight, an expired event
		# or a freed actor is released, never tracked blind).
		if current.is_empty(): release()
		else:
			point = current.point
			node = weakref(current.node) if current.node else null
			strength = clampf(float(current.score),0.0,1.0)
	profile_scans += 1
	profile_usec += Time.get_ticks_usec()-began

func _score(interest: float, key: int, at: Vector3, head: Vector3, forward: Vector3, distance: float, t: float) -> float:
	var to := (at-head).slide(Vector3.UP)
	var facing := 1.0
	if to.length_squared()>.0001:
		var cosine := forward.dot(to.normalized())
		facing = 1.15 if cosine>.5 else 1.0 if cosine>-.55 else .55
	var score := interest*facing/(1.0+distance/7.0)
	if key==_key:
		# Committed while the fixation hold lasts, then growing boredom lets
		# the eyes wander off and come back (natural gaze aversion).
		score *= 1.6 if _hold>0.0 else lerpf(.7,.1,smoothstep(0.0,2.0,-_hold))
	else:
		score *= .3+.7*smoothstep(0.0,5.0,t-float(_seen.get(key,-100.0)))
	return score*_rng.randf_range(.88,1.12)

func _new_scan_point(head: Vector3, forward: Vector3) -> Vector3:
	var choice := _rng.randf()
	var yaw := _rng.randf_range(-1.1,1.1)
	var direction := forward.rotated(Vector3.UP,yaw)
	if choice<.35: return head+direction*_rng.randf_range(1.6,3.0)+Vector3.DOWN*_rng.randf_range(.9,1.2)
	if choice<.85: return head+direction*_rng.randf_range(5.0,9.0)+Vector3.UP*_rng.randf_range(-.4,.5)
	return head+direction*4.0+Vector3.UP*_rng.randf_range(2.0,3.0)
