extends RefCounted
## Harness implementation of RaulsMod's shared two-link leg solver (the real file is
## not in the rebuild package). Contract inferred from every call site:
##   two_link(hip, target, upper, lower, pole, near_margin, far_margin, fallback_forward)
##     -> {"knee": Vector3, "foot": Vector3}
## The foot is the target clamped into the reachable shell
## [|upper-lower| + near_margin, upper+lower - far_margin]; the knee lies in the plane
## spanned by the hip->foot axis and the pole, on the pole side.
static func two_link(hip: Vector3, target: Vector3, upper: float, lower: float, pole: Vector3,
		near_margin := .015, far_margin := .012, fallback_forward := Vector3.FORWARD) -> Dictionary:
	var to := target - hip
	var distance := to.length()
	var axis := to / distance if distance > 1e-6 else Vector3.DOWN
	var reach := clampf(distance, absf(upper - lower) + near_margin, upper + lower - far_margin)
	var foot := hip + axis * reach
	var bend := pole.slide(axis)
	if bend.length_squared() < 1e-8: bend = fallback_forward.slide(axis)
	if bend.length_squared() < 1e-8: bend = axis.cross(Vector3.RIGHT if absf(axis.x) < .9 else Vector3.UP)
	bend = bend.normalized()
	var along := (upper * upper - lower * lower + reach * reach) / (2.0 * reach)
	var height := sqrt(maxf(upper * upper - along * along, 0.0))
	return {"knee": hip + axis * along + bend * height, "foot": foot}
