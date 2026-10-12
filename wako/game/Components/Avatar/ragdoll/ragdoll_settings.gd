extends RefCounted
## Settings of hits and knock-downs (WARRIOR REACT, R-WARRIOR-07/14):
##   gameplay/knockdowns        Off / Big hits only / Normal: how easily a hit, a blast, a car or a fall knocks the
##       body down (Off: hits still rock the body, it never falls).
##   gameplay/knockdown_camera  Follow the head / Third person: the first-person view while down (reduce motion
##       always uses the third-person pull-out).

const KNOCK := ["Off", "Big hits only", "Normal"]
const CAMERA := ["Follow the head", "Third person"]
## Threshold multiplier per gameplay/knockdowns option (INF = never)
const KNOCK_SCALE := [INF, 1.7, 1.0]


static func register() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var st : Node = tree.root.get_node_or_null(^"/root/Settings") if tree else null
	if st == null or not st.has_method(&"register") or st.has(&"gameplay/knockdowns"):
		return
	st.register(&"gameplay/knockdowns", {type = &"enum", options = KNOCK, default = "Normal",
		label = "Knock-downs", category = &"gameplay", group = "Player body",
		tooltip = "Big hits, blasts, cars and long falls throw you to the ground; you get back up on your own"})
	st.register(&"gameplay/knockdown_camera", {type = &"enum", options = CAMERA, default = "Follow the head",
		label = "Knock-down view (first person)", category = &"gameplay", group = "Player body",
		tooltip = "While knocked down in first person: see through your eyes (steadied), or step out to third person"})


static func knock_scale() -> float:
	var st := _st()
	if st == null:
		return 1.0
	var i := KNOCK.find(String(st.get_value(&"gameplay/knockdowns", "Normal")))
	return KNOCK_SCALE[i] if i >= 0 else 1.0


## True: pull the first-person view out to third person during a knock-down.
static func pull_out() -> bool:
	var st := _st()
	if st == null:
		return false
	if bool(st.get_value(&"accessibility/reduce_motion", false)):
		return true
	return String(st.get_value(&"gameplay/knockdown_camera", CAMERA[0])) == CAMERA[1]


static func _st() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	var st : Node = tree.root.get_node_or_null(^"/root/Settings") if tree else null
	return st if st and st.has_method(&"get_value") else null
