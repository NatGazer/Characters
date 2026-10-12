extends RefCounted
const ExcavatorStock := preload("res://Components/Contraptions/excavator_stock.gd")
## Physical dimensions are metres, mass kg, output W, storage Wh, torque N*m.
## Data is intentionally independent of scenes so blueprints only contain stable IDs.

const STONE := Color("869899")
const METAL := Color("a18355")
const ENERGY := Color("74ffe0")
const FINISHES := {
	"chalk": {"title": "Chalk white", "color": Color("d9ded6")},
	"ochre": {"title": "Warm ochre", "color": Color("c69a55")},
	"sea_green": {"title": "Sea green", "color": Color("559b8c")},
	"slate_blue": {"title": "Slate blue", "color": Color("647f9e")},
	"oxide": {"title": "Red oxide", "color": Color("ac6852")}}
const WingGeometry := preload("res://Components/Contraptions/wing_geometry.gd")
const PlateGeometry := preload("res://Components/Contraptions/plate_geometry.gd")
const BeamGeometry := preload("res://Components/Contraptions/beam_geometry.gd")
const CaptiveBay := preload("res://Components/Contraptions/captive_bay_geometry.gd")
const CurvedRib := preload("res://Components/Contraptions/curved_rib_geometry.gd")
const OpenGrille := preload("res://Components/Contraptions/open_grille_geometry.gd")
const StoneBallast := preload("res://Components/Contraptions/stone_ballast_geometry.gd")
const FixedStrut := preload("res://Components/Contraptions/fixed_strut_geometry.gd")
const WorkshopBeacon := preload("res://Components/Contraptions/workshop_beacon_geometry.gd")
const SignalHorn := preload("res://Components/Contraptions/signal_horn_geometry.gd")
const WheelGeometry := preload("res://Components/Contraptions/wheel_geometry.gd")
const FlightDesign := preload("res://Components/Contraptions/flight_design.gd")
const GroundJointDesign := preload("res://Components/Contraptions/ground_joint_design.gd")
const RecoveryBallProfile := preload("res://Components/Contraptions/recovery_ball_profile.gd")
const RecoveryStator := preload("res://Components/Contraptions/recovery_stator.gd")
const RaisedGunStock := preload("res://Components/Contraptions/raised_gun_station_stock.gd")
const Universal := preload("res://Components/Contraptions/universal_joint.gd")
const BearingLimits := preload("res://Components/Contraptions/bearing_limits.gd")
const BearingFreewheel := preload("res://Components/Contraptions/bearing_freewheel.gd")
const QuickRelease := preload("res://Components/Contraptions/quick_release_coupler.gd")
const BreakawayFuse := preload("res://Components/Contraptions/breakaway_fuse.gd")
static var _definitions: Dictionary = {}

static func _socket(name: String, pos: Vector3, type: String = "mount", axis: Vector3 = Vector3.UP) -> Dictionary:
	return {"name": name, "pos": pos, "type": type, "axis": axis}

static func _mounts(size: Vector3) -> Array:
	return [_socket("top", Vector3(0, size.y * .5, 0)), _socket("bottom", Vector3(0, -size.y * .5, 0), "mount", Vector3.DOWN),
		_socket("left", Vector3(-size.x * .5, 0, 0), "mount", Vector3.LEFT),
		_socket("right", Vector3(size.x * .5, 0, 0), "mount", Vector3.RIGHT),
		_socket("front", Vector3(0, 0, -size.z * .5), "mount", Vector3.FORWARD),
		_socket("back", Vector3(0, 0, size.z * .5), "mount", Vector3.BACK)]

static func _def(title: String, category: String, mass: float, size: Vector3, extra: Dictionary = {}) -> Dictionary:
	var d := {"title": title, "category": category, "mass": mass, "size": size, "health": 100.0,
		"connectors": _mounts(size), "power": 0.0, "capacity": 0.0, "friction": .65,
		"strength": 16000.0, "color": STONE, "tool": "pickaxe", "recoverable": true}
	d.merge(extra, true)
	return d

static func all() -> Dictionary:
	if not _definitions.is_empty():
		return _definitions
	var chassis := _def("Core chassis", "structure", 110, Vector3(2.4, .38, 3.2), {"strength": 42000.0})
	chassis.connectors.append_array([
		_socket("ramp_back", Vector3(0, .19, 1.6), "mount", Vector3.RIGHT),
		_socket("wheel_fl", Vector3(-1.2, -.32, -1.05), "axle", Vector3.LEFT),
		_socket("wheel_fr", Vector3(1.2, -.32, -1.05), "axle", Vector3.RIGHT),
		_socket("wheel_rl", Vector3(-1.2, -.32, 1.05), "axle", Vector3.LEFT),
		_socket("wheel_rr", Vector3(1.2, -.32, 1.05), "axle", Vector3.RIGHT)])
	# Additive real side-face axles for the fresh captive carriage's original
	# six tyres. Preserve old sockets; 1.3 m pitch clears spiked envelopes.
	for side: float in [-1.0,1.0]:
		for station: String in ["f","m","r"]:
			var wheel_z := -1.3 if station == "f" else 1.3 if station == "r" else 0.0
			chassis.connectors.append(_socket("guard_wheel_"+station+("l" if side<0 else "r"),
				Vector3(side*1.2,-.32,wheel_z),"axle",Vector3.LEFT if side<0 else Vector3.RIGHT))
	for x in [-1.0, 1.0]:
		for z in [-1.05, 1.05]:
			var leg_name := "leg_%s%s" % ["f" if z < 0 else "r", "l" if x < 0 else "r"]
			chassis.connectors.append(_socket(leg_name, Vector3(x, -.15, z), "mount", Vector3.DOWN))
	# Real rear-face fastener points let an independent canopy brace stand clear
	# of the axle tyres, without moving any established mounting connector.
	chassis.connectors.append_array([_socket("rear_left",Vector3(-1,.17,1.6),"mount",Vector3.BACK),
		_socket("rear_right",Vector3(1,.17,1.6),"mount",Vector3.BACK)])
	# The fixed recovered arch bears on two exposed points of the existing top
	# face. These additive sockets change no established shape or connector.
	chassis.connectors.append_array([_socket("rib_left", Vector3(-.9, .19, 0)),
		_socket("rib_right", Vector3(.9, .19, 0))])
	# Additional mounts preserve every original chassis socket and body.
	for side: float in [-1.0,1.0]:
		for end: float in [-1.0,1.0]:
			chassis.connectors.append(_socket("exc_track_%s%s"%["f" if end<0 else "r","l" if side<0 else "r"],
				Vector3(side*1.2,-.16,end*.95),"mount",Vector3.RIGHT*side))
	var container := _def("Secured parts container", "storage", 28, Vector3(1.2, .85, 1.25), {"storage_kg": 600.0, "color": Color("777b70")})
	# Exposed container bottom-edge fasteners share a full secured load through
	# actual independent chassis welds, rather than one central soft mount.
	for edge: Dictionary in [{"id":"left","at":Vector3(-.6,0,0)}, {"id":"right","at":Vector3(.6,0,0)},
		{"id":"front","at":Vector3(.6,0,-.625)}, {"id":"back","at":Vector3(-.6,0,.625)}]:
		chassis.connectors.append(_socket("cargo_"+edge.id,edge.at+Vector3.UP*.19,"mount",Vector3.UP))
		container.connectors.append(_socket("base_"+edge.id,edge.at+Vector3.DOWN*.425,"mount",Vector3.DOWN))
	var panel := _def("Stone panel", "structure", 18, Vector3(1.2, .1, 1.2))
	panel.connectors.append_array([_socket("left_lower",Vector3(-.6,-.05,0),"mount",Vector3.LEFT),
		_socket("right_lower",Vector3(.6,-.05,0),"mount",Vector3.RIGHT)])
	for x in [-.5, .5]:
		for z in [-.5, .5]:
			var corner := "%s%s" % ["f" if z < 0 else "r", "l" if x < 0 else "r"]
			container.connectors.append(_socket("rack_" + corner, Vector3(x, -.325, z)))
			panel.connectors.append(_socket("corner_" + corner, Vector3(x, -.05, z), "mount", Vector3.DOWN))
	var wing_shape := WingGeometry.describe()
	var wing := _def("Parametric glider wing", "flight", float(wing_shape.mass), wing_shape.size,
		{"parametric": "airfoil", "area": wing_shape.area, "bounds": wing_shape.bounds, "connectors": wing_shape.connectors})
	_definitions = {
		"chassis": chassis,
		"beam": _def("Box beam", "structure", 16, Vector3(.22, .22, 2), {"parametric": "length", "min_length": .3, "max_length": 8.0}),
		"curved_rib": _def("Composite curved rib", "structure", CurvedRib.MASS, CurvedRib.describe().size, CurvedRib.describe()),
		"open_grille": _def("Open composite grille", "structure", OpenGrille.MASS, OpenGrille.SIZE, OpenGrille.describe()),
		"stone_ballast": _def("Stone ballast block", "structure", StoneBallast.MASS, StoneBallast.SIZE, StoneBallast.describe()),
		"fixed_strut": _def("Fixed support strut", "structure", FixedStrut.MASS, FixedStrut.SIZE, FixedStrut.describe()),
		"panel": panel,
		"armor": _def("Cut armour plate", "defence", 32, Vector3(1.2, .15, 1.2), {"health": 180.0, "strength": 24000.0, "parametric": "outline"}),
		"bracket": _def("Mounting bracket", "structure", 5, Vector3(.3, .3, .3), {"color": METAL}),
		"quick_release": _def("Manual quick-release coupler", "mechanism", QuickRelease.MASS, QuickRelease.SIZE,
			{"color":METAL,"connectors":QuickRelease.sockets(),"bounds":QuickRelease.bounds(),"strength":18000.0}),
		"breakaway_fuse": _def("Geometric breakaway cartridge", "mechanism", BreakawayFuse.MASS, BreakawayFuse.SIZE,
			{"color":METAL,"connectors":BreakawayFuse.sockets(),"bounds":BreakawayFuse.bounds()}),
		"access_ramp": _def("Machine access ramp", "structure", 18, Vector3(1.2, .12, 3.2),
			{"color": METAL, "walk_width": 1.2, "max_slope": 32.0,
			"connectors": [_socket("top", Vector3(0, .06, 0)), _socket("bottom", Vector3(0, -.06, 0), "mount", Vector3.DOWN),
				_socket("entry", Vector3(0, .06, 1.6), "mount", Vector3.LEFT), _socket("exit", Vector3(0, .06, -1.6), "mount", Vector3.LEFT)]}),
		"assembly_tool": _def("Mechanical mallet", "tool", 5, Vector3(.24, 1.05, .13),
			{"work_capabilities": ["build", "repair", "unbend", "maintenance"], "tool_model": "sledgehammer", "color": METAL}),
		"salvage_tool": _def("Fastener pickaxe", "tool", 3, Vector3(.61, 1.05, .18),
			{"work_capabilities": ["dismantle"], "tool_model": "pickaxe", "color": METAL}),
		"suspension": _def("Coil spring and shock carrier", "suspension", 12, Vector3(.34, .75, .34),
			{"preferred_joint": "suspension", "spring_rate": 12000.0, "damping": 1000.0, "travel": .5, "strength": 18000.0,
			"connectors": [_socket("top", Vector3(0, .375, 0)), _socket("bottom", Vector3(0, -.375, 0), "mount", Vector3.DOWN),
				_socket("hub_left", Vector3(-.17, -.2, 0), "axle", Vector3.LEFT), _socket("hub_right", Vector3(.17, -.2, 0), "axle", Vector3.RIGHT)]}),
		"bearing": _def("Lockable rotary bearing", "mechanism", 6, Vector3(.35, .35, .35),
			{"preferred_joint": "bearing", "strength": 18000.0, "brake_torque": 35.0, "angular_limit_deg": 0.0, "color": METAL}),
		"universal": _def("Two-axis universal carrier", "mechanism", 5, Vector3(.30, .30, .30),
			{"preferred_joint": "universal", "strength": 18000.0, "color": METAL,
			"connectors": [_socket("left", Vector3(-.15, 0, 0), "mount", Vector3.LEFT),
				_socket("right", Vector3(.15, 0, 0), "mount", Vector3.RIGHT)]}),
		"flywheel": _def("Finite reaction-wheel rotor", "mechanism", 24, Vector3(.18, 1.1, 1.1),
			{"preferred_joint": "bearing", "power": 80.0, "torque": 18.0, "max_speed": 30.0,
			"radius": .55, "shape": "cylinder_x", "health": 120.0, "strength": 18000.0, "color": METAL,
			"connectors": [_socket("hub", Vector3(-.09, 0, 0), "mount", Vector3.LEFT)]}),
		"ball_joint": _def("Omnidirectional ball carrier", "mechanism", 7, Vector3(.55, .25, .55),
			{"color": METAL, "connectors": [_socket("top", Vector3(0, .125, 0)),
				_socket("bottom", Vector3(0, -.55, 0), "mount", Vector3.DOWN)]}),
		"wheel": _def("Off-road motor wheel", "locomotion", 24, Vector3(.32, 1.24, 1.24),
			{"radius": .62, "torque": 600.0, "power": 1400.0, "friction": 1.1, "color": Color("22282b"),
			"connectors": [_socket("left", Vector3(-.16, 0, 0), "axle", Vector3.LEFT),
				_socket("right", Vector3(.16, 0, 0), "axle", Vector3.RIGHT), _socket("mount", Vector3.ZERO, "axle", Vector3.RIGHT)]}),
		"track": _def("Track pod", "locomotion", 48, Vector3(.5, .65, 1.8), {"power": 240.0, "torque": 220.0, "friction": 1.2}),
		"leg": _def("Assisted articulated leg", "locomotion", 32, Vector3(.3, 1.5, .3), {"power": 220.0, "reach": 1.6, "torque": 240.0}),
		"leg_upper": _def("Powered upper leg", "locomotion", 16, Vector3(.18, .8, .18),
			{"health": 120.0, "strength": 30000.0, "torque": 2200.0, "power": 1500.0, "max_speed": 2.5, "preferred_joint": "leg_hip",
			"connectors": [_socket("hip", Vector3(0, .4, 0)), _socket("knee", Vector3(0, -.4, 0), "mount", Vector3.DOWN)]}),
		"leg_lower": _def("Powered lower leg", "locomotion", 12, Vector3(.18, .8, .18),
			{"health": 120.0, "strength": 30000.0, "torque": 1200.0, "power": 750.0, "max_speed": 3.0, "preferred_joint": "leg_knee",
			"connectors": [_socket("knee", Vector3(0, .4, 0)), _socket("ankle", Vector3(0, -.4, 0), "mount", Vector3.DOWN)]}),
		"leg_foot": _def("Articulated grip pad", "locomotion", 5, Vector3(.45, .16, .65),
			{"health": 120.0, "strength": 30000.0, "torque": 220.0, "power": 300.0, "max_speed": 3.0,
			"friction": 1.2, "preferred_joint": "leg_ankle", "connectors": [_socket("ankle", Vector3(0, .08, 0))]}),
		"gyro": _def("Balanced sphere drive", "locomotion", 42, Vector3(1.1, 1.1, 1.1),
			{"preferred_joint": "ball", "power": 350.0, "torque": 180.0, "radius": .55, "friction": 1.0,
			"connectors": [_socket("hub", Vector3.ZERO), _socket("top", Vector3.ZERO)]}),
		"battery": _def("Energy cell", "power", 26, Vector3(.65, .45, .85), {"capacity": 1800.0, "color": Color("405e5b")}),
		"generator": _def("Flux generator", "power", 48, Vector3(.8, .65, .95), {"output": 650.0, "fuel": 600.0}),
		"solar": _def("Solar collector", "power", 12, Vector3(1.2, .08, 1.2), {"output": 280.0, "area": 1.44}),
		"cable": _def("Power bridge", "power", 2, Vector3(.12, .12, .8), {"color": ENERGY}),
		"switch": _def("Isolation switch", "control", 3, Vector3(.25, .22, .3)),
		"cockpit": _def("Latched motion cockpit", "control", 24, Vector3(.65, .6, .8), {"color": METAL}),
		"mind": _def("Protected machine mind", "control", 16, Vector3(.6, .45, .55), {"power": 3.0, "health": 150.0, "strength": 26000.0, "color": ENERGY}),
		"station": _def("Wako utility station", "control", 12, Vector3(.7, .45, .7), {"station_role": "utility", "color": METAL}),
		"container": container,
		"pontoon": _def("Sealed flotation pontoon", "aquatic", 28, Vector3(.6, .55, 3.2),
			{"health": 140.0, "strength": 24000.0, "sealed_fill": .95}),
		"hinge": _def("Powered hinge", "mechanism", 9, Vector3(.3, .3, .3), {"power": 55.0, "torque": 180.0, "lower": -1.2, "upper": 1.2, "color": METAL}),
		"slider": _def("Prismatic rail", "mechanism", 14, Vector3(.25, .25, 1.2), {"power": 65.0, "stroke": 1.0, "color": METAL}),
		"motor": _def("Rotary actuator", "mechanism", 12, Vector3(.4, .4, .45), {"power": 80.0, "torque": 220.0, "color": METAL}),
		"piston": _def("Linear actuator", "mechanism", 18, Vector3(.25, .25, 1.2), {"power": 90.0, "stroke": .9, "color": METAL}),
		"winch": _def("Reaction-force winch", "utility", 20, Vector3(.55, .4, .6), {"power": 140.0, "pull": 2600.0, "color": METAL}),
		"rope": _def("Tension cable", "utility", 3, Vector3(.08, .08, 1), {"strength": 4000.0, "color": METAL}),
		"wing": wing,
		"thruster": _def("Counterrotating ducted fan", "flight", 26, Vector3(.55, .55, .85),
			{"power": 15000.0, "thrust": 600.0, "disk_area": .238, "efficiency": .7}),
		"gun": _def("Wako gun station", "combat", 34, Vector3(.6, .6, 1.1), {"power": 90.0, "station_role": "weapon", "damage": 9.0, "color": METAL, "connectors": _mounts(Vector3(.6,.6,1.1))+[_socket("plinth_bottom",Vector3(0,-.21,0),"mount",Vector3.DOWN)]}),
		"shield": _def("Sacrificial defence panel", "defence", 22, Vector3(1.2, 1.2, .16), {"health": 220.0}),
		"light": _def("Expressive eye lamp", "feedback", 2, Vector3(.22, .22, .16), {"power": 2.0, "color": ENERGY}),
		"workshop_beacon": _def("Powered workshop beacon", "feedback", WorkshopBeacon.MASS, WorkshopBeacon.SIZE, WorkshopBeacon.describe()),
		"signal_horn": _def("Powered signal horn", "feedback", SignalHorn.MASS, SignalHorn.SIZE, SignalHorn.describe()),
		"remote_core": _def("Hostile remote core", "control", 12, Vector3(.55, .55, .55), {"recoverable": false, "health": 55.0, "color": Color("9b3949")})}
	# An additional flush mount lies on the same finite cell right face. Its
	# forward seat lets a low gun keep its full barrel sweep clear of side stock.
	_definitions.battery.connectors.append(_socket("right_forward",Vector3(.325,0,-.30),"mount",Vector3.RIGHT))
	for kind: String in ExcavatorStock.KINDS: _definitions[kind] = ExcavatorStock.definition(kind)
	return _definitions

static func get_def(kind: String, parameters: Dictionary = {}) -> Dictionary:
	var definitions := all()
	var result: Dictionary = definitions.get(kind, definitions["bracket"]).duplicate(true)
	if kind == "ball_joint" and RecoveryStator.applies(parameters):
		result.merge(RecoveryStator.describe(parameters), true)
	if kind == "gun" and RaisedGunStock.applies(parameters):
		result.merge(RaisedGunStock.describe(parameters),true)
	if kind == "gyro" and RecoveryBallProfile.applies(parameters):
		result.merge(RecoveryBallProfile.describe(), true)
	if kind == "container" and CaptiveBay.applies(parameters):
		result.merge(CaptiveBay.describe(), true)
	elif kind in ExcavatorStock.KINDS:
		result = ExcavatorStock.definition(kind,parameters)
	elif kind == "beam":
		result.merge(BeamGeometry.describe(parameters), true)
	elif kind == "wheel":
		result.wheel_profile = WheelGeometry.normalize(parameters).wheel_profile
		if result.wheel_profile != "offroad": result.merge(WheelGeometry.describe(parameters), true)
	elif kind == "wing":
		result.merge(WingGeometry.describe(parameters), true)
	elif kind == "armor":
		result.merge(PlateGeometry.describe(parameters), true)
		var fraction: float = float(result.area) / PlateGeometry.STOCK_AREA
		result.health *= fraction
		result.strength *= sqrt(fraction)
	elif kind == "cockpit":
		result.control_mode = "flight" if parameters.get("control_mode", "ground") == "flight" else "ground"
		if result.control_mode == "flight": result.title = "Latched flight cockpit"
	elif kind == "bearing":
		result.merge(BearingLimits.normalize(parameters), true)
		result.merge(BearingFreewheel.normalize(parameters), true)
		if int(result.freewheel_direction)!=0:
			result.mass = BearingFreewheel.MASS
			result.freewheel_torque = BearingFreewheel.TORQUE
			result.parametric = "bearing_freewheel"
			result.title = "One-way bearing: " + BearingFreewheel.label(parameters).to_lower()
		if float(result.angular_limit_deg) > 0:
			result.title = (result.title if int(result.freewheel_direction)!=0 else "Stopped rotary bearing") + " (+/- %.1f degrees)" % float(result.angular_limit_deg)
	result.color = finish_color(kind, parameters)
	return result

static func supports_finish(kind: String) -> bool:
	# Recolour the existing independent shell material, retaining exposed brass,
	# rubber, tools and energy lights. These specialised models have no shell.
	return all().has(kind) and kind not in ["remote_core", "assembly_tool", "salvage_tool", "thruster", "flywheel", "wheel", "gyro", "ball_joint"]

static func valid_finish(kind: String, finish: Variant) -> bool:
	return supports_finish(kind) and finish is String and (finish == "original" or FINISHES.has(finish))

static func finish_color(kind: String, parameters: Dictionary) -> Color:
	var finish: Variant = parameters.get("finish", "original")
	if valid_finish(kind, finish) and FINISHES.has(finish): return FINISHES[finish].color
	return all().get(kind, all().bracket).color

static func design_keys(kind: String) -> Array:
	var keys: Array = shape_keys(kind)
	if kind == "hinge": keys = FlightDesign.keys() + GroundJointDesign.keys()
	elif kind == "motor": keys = GroundJointDesign.keys()
	elif kind == "cockpit": keys = ["control_mode"]
	elif kind == "access_ramp": keys = ["access_points"]
	if kind == "beam": keys.append("truss_phase_auto")
	if supports_finish(kind): keys.append("finish")
	return keys

static func design_parameters(kind: String, parameters: Dictionary) -> Dictionary:
	var design: Dictionary = shape_parameters(kind, parameters)
	if kind == "hinge":
		design = FlightDesign.normalize(parameters)
		design.merge(GroundJointDesign.normalize(parameters))
	elif kind == "motor": design = GroundJointDesign.normalize(parameters)
	elif kind == "cockpit": design = {"control_mode": "flight" if parameters.get("control_mode", "ground") == "flight" else "ground"}
	elif kind == "access_ramp" and parameters.get("access_points") is Array: design.access_points = parameters.access_points.duplicate(true)
	if kind == "beam" and design.get("profile", "") == "truss" and parameters.get("truss_phase_auto", false): design.truss_phase_auto = true
	var finish: Variant = parameters.get("finish", "original")
	if finish != "original" and valid_finish(kind, finish): design.finish = finish
	return design

static func shape_parameters(kind: String, parameters: Dictionary) -> Dictionary:
	if kind == "container": return CaptiveBay.normalize(parameters)
	if kind == "ball_joint": return RecoveryStator.normalize(parameters)
	if kind == "gun": return RaisedGunStock.normalize(parameters)
	if kind == "gyro": return RecoveryBallProfile.normalize(parameters)
	if kind in ExcavatorStock.KINDS: return ExcavatorStock.normalize(kind,parameters)
	if kind == "bearing":
		var bearing := BearingLimits.normalize(parameters)
		bearing.merge(BearingFreewheel.normalize(parameters))
		return bearing
	if kind == "beam": return BeamGeometry.normalize(parameters)
	if kind == CurvedRib.KIND: return CurvedRib.normalize(parameters)
	if kind == OpenGrille.KIND: return OpenGrille.normalize(parameters)
	if kind == StoneBallast.KIND: return StoneBallast.normalize(parameters)
	if kind == FixedStrut.KIND: return FixedStrut.normalize(parameters)
	if kind == WorkshopBeacon.KIND: return WorkshopBeacon.normalize(parameters)
	if kind == SignalHorn.KIND: return SignalHorn.normalize(parameters)
	if kind == "wheel": return WheelGeometry.normalize(parameters)
	if kind == "wing": return WingGeometry.normalize(parameters)
	if kind == "armor": return PlateGeometry.normalize(parameters)
	return {}

static func shape_keys(kind: String) -> Array:
	if kind == "container": return ["container_profile", "container_version"]
	if kind == "ball_joint": return ["ball_carrier_profile", "ball_carrier_version"]
	if kind == "gun": return ["gun_station_profile","gun_station_version"]
	if kind == "gyro": return ["ball_drive_profile", "ball_drive_version"]
	if kind == ExcavatorStock.COUNTERBASE: return ["pedestal"]
	if kind == ExcavatorStock.PIVOT: return ["pivot_role"]
	if kind in [ExcavatorStock.BOOM,ExcavatorStock.BALANCED_BOOM]: return ["link"]
	if kind == "bearing": return [BearingLimits.KEY,BearingFreewheel.KEY]
	if kind == "beam": return ["length", "profile", "truss_phase"]
	if kind == CurvedRib.KIND: return ["rib_profile"]
	if kind == OpenGrille.KIND: return ["grille_profile"]
	if kind == StoneBallast.KIND: return ["ballast_profile"]
	if kind == FixedStrut.KIND: return ["strut_profile"]
	if kind == WorkshopBeacon.KIND: return ["beacon_profile"]
	if kind == SignalHorn.KIND: return ["horn_profile"]
	if kind == "wheel": return ["wheel_profile"]
	if kind == "wing": return WingGeometry.schema().keys()
	if kind == "armor": return ["outline"]
	return []

static func same_shape(kind: String, a: Dictionary, b: Dictionary) -> bool:
	if kind == "container": return CaptiveBay.same_stock(a, b)
	if kind == "ball_joint": return RecoveryStator.same_stock(a, b)
	if kind == "gun": return RaisedGunStock.same_stock(a,b)
	if kind == "gyro": return RecoveryBallProfile.same_stock(a, b)
	if kind in ExcavatorStock.KINDS: return ExcavatorStock.normalize(kind,a)==ExcavatorStock.normalize(kind,b)
	if kind == "bearing": return BearingLimits.same_stock(a, b) and BearingFreewheel.same_stock(a,b)
	if kind == "wheel": return WheelGeometry.same_shape(a, b)
	if kind == "wing": return WingGeometry.same_shape(a, b)
	if kind == "armor": return PlateGeometry.same_shape(a, b)
	if kind == "beam": return BeamGeometry.same_shape(a, b)
	if kind == CurvedRib.KIND: return CurvedRib.same_stock(a, b)
	if kind == OpenGrille.KIND: return OpenGrille.same_stock(a, b)
	if kind == StoneBallast.KIND: return StoneBallast.same_stock(a, b)
	if kind == FixedStrut.KIND: return FixedStrut.same_stock(a, b)
	if kind == WorkshopBeacon.KIND: return WorkshopBeacon.same_stock(a, b)
	if kind == SignalHorn.KIND: return SignalHorn.same_stock(a, b)
	return true

static func bounds_of(definition: Dictionary) -> AABB:
	var size: Vector3 = definition.size
	return definition.get("bounds", AABB(-size * .5, size))

static func closest_point(definition: Dictionary, local_point: Vector3) -> Vector3:
	var material: Variant = definition.get("material_geometry")
	if material is RefCounted: return material.closest_point(local_point)
	if definition.get("parametric", "") == CaptiveBay.PROFILE: return CaptiveBay.closest_point(local_point)
	if definition.get("parametric", "") == RecoveryStator.PROFILE: return RecoveryStator.closest_point(local_point, definition)
	if definition.get("parametric", "") == "bearing_freewheel": return BearingFreewheel.closest_point(local_point)
	if definition.get("parametric", "") == "wheel_profile": return WheelGeometry.closest_point(definition, local_point)
	if definition.get("preferred_joint", "") == "universal": return Universal.closest_point(local_point)
	if definition.get("parametric", "") == "beam": return BeamGeometry.closest_point(definition, local_point)
	if definition.get("parametric", "") == "outline": return PlateGeometry.closest_point(definition, local_point)
	if definition.get("parametric", "") == CurvedRib.KIND: return CurvedRib.closest_point(local_point)
	if definition.get("parametric", "") == OpenGrille.KIND: return OpenGrille.closest_point(local_point)
	if definition.get("parametric", "") == StoneBallast.KIND: return StoneBallast.closest_point(local_point)
	if definition.get("parametric", "") == FixedStrut.KIND: return FixedStrut.closest_point(local_point)
	if definition.get("parametric", "") == WorkshopBeacon.KIND: return WorkshopBeacon.closest_point(local_point)
	if definition.get("parametric", "") == SignalHorn.KIND: return SignalHorn.closest_point(local_point)
	if definition.get("shape", "") == "cylinder_x":
		var radial := Vector2(local_point.y, local_point.z).limit_length(float(definition.radius))
		return Vector3(clampf(local_point.x, -float(definition.size.x) * .5, float(definition.size.x) * .5), radial.x, radial.y)
	var bounds := bounds_of(definition)
	return local_point.clamp(bounds.position, bounds.end)

static func socket(definition: Dictionary, key: Variant) -> Dictionary:
	var connectors: Array = definition.get("connectors", [])
	if key is int:
		return connectors[key] if key >= 0 and key < connectors.size() else {}
	for c: Dictionary in connectors:
		if c.name == str(key):
			return c
	return {}

static func compatible(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	return a.type == b.type or a.type == "mount" or b.type == "mount"
