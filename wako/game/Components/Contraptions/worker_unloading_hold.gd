extends RefCounted
## Retain an already head-held reserved source during brief internal container
## oscillation. Native root, crew, floor and ownership guards remain strict.

const MAX_SECONDS := 1.5
const PHASES := ["pickup", "carry_exit", "carry_outside", "carry"]

static func clear(entry: Dictionary) -> void:
	if not entry.get("unloading_held", false): return
	entry.unloading_held = false
	for worker: Node in entry.crew:
		if is_instance_valid(worker): worker.set_work_action_held(false)

static func tick(yard: Node3D, entry: Dictionary, delta: float) -> String:
	var was_held: bool = entry.get("unloading_held", false)
	if not yard.worksite_active() or not PHASES.has(entry.phase) or not entry.get("pickup", false):
		return "cancel" if was_held else "normal"
	var crew: Array = entry.crew
	if yard.unsafe_at(entry.job.target.global_position) or crew.any(func(worker: Node) -> bool:
		return not worker.is_available() or worker.fear_time > 0 or yard.unsafe_at(worker.global_position)):
		return "cancel" if was_held else "normal"
	var observation: Dictionary = yard.worksite_unloading_context(entry.job, crew)
	if observation.is_empty(): return "cancel" if was_held else "normal"
	# The exception is internal angular settling only. Translating cargo still
	# follows the original cancellation path, even when the root is stopped.
	if observation.anchor.linear_velocity.length() > .25: return "cancel" if was_held else "normal"
	if not observation.settling:
		if was_held:
			clear(entry)
			return "resume"
		return "normal"
	var elapsed: float = float(entry.get("unloading_hold_elapsed", 0.0)) + delta
	entry.unloading_hold_elapsed = elapsed
	if elapsed > MAX_SECONDS:
		entry.unloading_hold_reason = "Container did not settle; reserved load set down safely"
		return "cancel"
	if not was_held:
		entry.unloading_held = true
		entry.unloading_hold_phase = entry.phase
		entry.unloading_hold_actions = crew.map(func(worker: Node) -> Dictionary:
			return {"worker":worker.worker_id,"action":worker.action,"progress":worker.action_progress})
	for worker: Node in crew:
		worker.set_work_action_held(true)
		worker.stop_navigation()
		worker.needs = "Waiting for the container to settle"
		worker.status_text = worker.needs
	return "held"
