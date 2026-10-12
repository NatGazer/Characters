extends "res://.claude/tests/contraptions/wako_cooperative_carry.gd"
## Replay the genuine fresh Yard carry earned by the original foot-role pair.
## Its right helper retained a mallet after a real paid panel build; the normal
## cooperative partner is bare. Both native legs remain fully observed.

func _run() -> void:
	var world := World.instantiate()
	add_child(world)
	await _advance(.2)
	yard=world.get_node("ContraptionYard")
	yard.work_paused=true
	var earned_path := "res://.claude/tmp/wako_cooperative_yard_earned_carry.json"
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--coop-yard-earned="): earned_path=argument.get_slice("=",1)
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(earned_path))
	_check(saved is Dictionary,"original cooperative right-foot cohort uses its genuinely earned finite carry save")
	if not saved is Dictionary:
		Shortcuts.graceful_quit(1)
		return
	saved.paused=true
	yard.restore(saved)
	await _advance(.5)
	_park_fauna()
	_candidate_ids.clear()
	for helper: Node in yard.workers: _candidate_ids.append(helper.worker_id)
	_expected_roles=[0,1]
	_expected_tool_roles=[1]
	print("COOP_YARD restored original crew=",yard.workers.map(func(w:Node)->Array:return [w.worker_id,w.tool_foot_side(),w.equipped_tool.part_id if is_instance_valid(w.equipped_tool) else "bare"]))
	yard.work_paused=false
	_observing=true

func _observe_jobs() -> void:
	var current := {}
	for id: String in yard.coordinator.active_jobs:
		var entry: Dictionary = yard.coordinator.active_jobs[id]
		current[id]={"phase":entry.phase,"crew":entry.crew.duplicate()}
		if _last_jobs.get(id,{}).get("phase")==entry.phase: continue
		print("COOP_YARD lease tick=",_tick," id=",id," phase=",entry.phase," source=",entry.job.part.part_id,
			" sourceAt=",entry.job.part.global_position," targetAt=",entry.job.target.global_position,
			" crew=",entry.crew.map(func(w:Node)->Array:return [w.worker_id,w.tool_foot_side(),w.action,w.global_position]))
	_last_jobs=current
