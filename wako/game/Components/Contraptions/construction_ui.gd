extends Node
## A thin construction adapter around the existing aim_ray, grabber, input and UI palette.

const Catalogue := preload("res://Components/Contraptions/part_catalog.gd")
const Plans := preload("res://Components/Contraptions/blueprints.gd")
const MindMount := preload("res://Components/Contraptions/mind_mount_plan.gd")
const ProtectedBay := preload("res://Components/Contraptions/protected_bay.gd")
const PontoonDesign := preload("res://Components/Contraptions/pontoon_design.gd")
const FrontSuspension := preload("res://Components/Contraptions/front_suspension_rover.gd")
const Dash := preload("res://LogicObjects/Vehicles/UI/dash_style.gd")
const Keys := preload("res://Components/ShortcutsPanel/shortcut_keys.gd")
const QuickRelease := preload("res://Components/Contraptions/quick_release_coupler.gd")
const Placement := preload("res://Components/Contraptions/placement_preview.gd")
const AirfoilEditor := preload("res://Components/Contraptions/airfoil_editor.gd")
const FlightEditor := preload("res://Components/Contraptions/flight_editor.gd")
const GunInterface := preload("res://Components/Contraptions/gun_handoff_ui.gd")
const PlateEditor := preload("res://Components/Contraptions/plate_editor.gd")
const ProjectorLibrary := preload("res://Components/HandTools/BlueprintProjector/blueprint_projector_catalog.gd")
const Schematic := preload("res://Components/HandTools/BlueprintProjector/projector_schematic.gd")

var gun_interface: Node
var yard: Node3D
var panel: PanelContainer
var status: Label
var crew_status: Label
var supply_guide_status:Label
var crew_travel_status:Label
var crew_travel_resume:Button
var crew_travel_cancel:Button
var work_pause_button: Button
var hud: Label
var catalogue: OptionButton
var _part_search: LineEdit
var _part_matches: Label
var _part_actions: Array[Button] = []
var _part_filter_selection := ""
var symmetry: OptionButton
var learned: OptionButton
var cruise_speed: SpinBox
var mechanism_slider: HSlider
var brake_slider: HSlider
var finish_choice: OptionButton
var beam_length: SpinBox
var beam_profile: OptionButton
var beam_parameters: VBoxContainer
var wheel_parameters: VBoxContainer
var wheel_profile: OptionButton
var wing_editor: VBoxContainer
var flight_editor: VBoxContainer
var plate_editor: VBoxContainer
var cockpit_parameters: VBoxContainer
var cockpit_mode: OptionButton
var bearing_parameters: VBoxContainer
var bearing_direction: OptionButton
var connector_choice: OptionButton
var connector_angle: SpinBox
var bearing_lock: CheckButton
var placement: Node3D
var _poll := 0.0
var _last_mouse := Input.MOUSE_MODE_CAPTURED
var _holstered := false
var _learned_hash := -1
var _instructions: Label
var _study_button: Button
var _tabs: TabContainer
var _build_entry: Button
var _starter_button: Button
var _starter_stock: Label
var _starter_choice: OptionButton
var _starter_detail: Label
var _starter_diagram: Control
var _starter_plans: Array[Dictionary] = []
var _continue_heading: Label
var _selected_build: Label
var _selected_stock: Label
var _selected_step: Label
var _stock_recovery: Label
var _build_choice: OptionButton
var _customize_button: Button
var _cancel_unfinished_button: Button
var _projector_button: Button
var _part_stock: Label
var _parts_page := 0
var _selected_feedback := ""
var _selected_work_job_id := ""
var _operate_page := 0
var _dismantle_buttons: Array[Button] = []
var _dismantle_review: VBoxContainer
var _dismantle_detail: Label
var _dismantle_confirm: Button
var _dismantle_identity := 0

func setup(service: Node3D) -> void:
	yard = service
	add_to_group(&"shortcut_providers")
	add_to_group(&"fullscreen_ui")
	var layer := CanvasLayer.new()
	layer.layer = 25
	add_child(layer)
	panel = PanelContainer.new()
	panel.position = Vector2(28, 28)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(.035, .055, .07, .97)
	style.border_color = Dash.BRONZE
	style.set_border_width_all(1)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	panel.add_theme_font_override("font", Dash.font("reg"))
	layer.add_child(panel)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 9)
	panel.add_child(frame)
	var title := _text("BUILD A CONTRAPTION", 24)
	title.add_theme_color_override("font_color", Dash.HEADING)
	frame.add_child(title)
	var caption := _text("Start with a plan, then add your own parts. Wako build from real stock.", 15)
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	frame.add_child(caption)
	status = _text("", 16)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.max_lines_visible = 3
	status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	frame.add_child(status)
	var tabs := TabContainer.new()
	_tabs = tabs
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(tabs)
	var box := _page(tabs, "Start")
	(box.get_parent() as ScrollContainer).follow_focus = true
	box.add_child(_text("1  CHOOSE A STARTER", 18))
	_starter_plans = [
		{"title": "Powered lamp · learn with two pieces", "action": "Start a lamp",
			"detail": "An energy cell and an eye lamp. A small first project to watch Wako carry and fasten real stock.", "plan": Plans.eye_lamp_display()},
		{"title": "Rover · recommended first vehicle", "action": "Start a rover",
			"detail": "A chassis, four wheels, an energy cell and a helm. Finish it, then add your own snapped parts.", "plan": Plans.rover()},
		{"title": "Cargo workshop · a larger project", "action": "Start a workshop",
			"detail": "A rover with storage, a lifting arm, a work station and a lit roof. More stock and crew work than the starter rover.", "plan": Plans.home()}]
	_starter_choice = OptionButton.new()
	_starter_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_starter_choice.fit_to_longest_item = false
	_starter_choice.custom_minimum_size.y = 32
	_starter_choice.tooltip_text = "Review a starter blueprint and its matching stored stock. Choosing a row creates no plan or parts."
	for entry: Dictionary in _starter_plans:
		_starter_choice.add_item(entry.title)
	_starter_choice.select(1)
	box.add_child(_starter_choice)
	var starter_review := HBoxContainer.new()
	starter_review.add_theme_constant_override("separation", 12)
	box.add_child(starter_review)
	_starter_diagram = Schematic.new()
	_starter_diagram.custom_minimum_size = Vector2(180, 108)
	_starter_diagram.mouse_filter = Control.MOUSE_FILTER_IGNORE
	starter_review.add_child(_starter_diagram)
	_starter_detail = _text("", 14)
	_starter_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_starter_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	starter_review.add_child(_starter_detail)
	_starter_stock = _text("", 15)
	_starter_stock.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_starter_stock)
	var start_actions := HFlowContainer.new()
	box.add_child(start_actions)
	_starter_button = _button(start_actions, "Start a rover", _start_starter)
	_starter_choice.item_selected.connect(_select_starter)
	_select_starter(_starter_choice.selected)
	_button(start_actions, "Other blueprints", func() -> void: _tabs.current_tab = 1)
	_continue_heading = _text("2  CONTINUE OR CUSTOMIZE", 18)
	box.add_child(_continue_heading)
	box.add_child(_text("Your builds", 15))
	_build_choice = OptionButton.new()
	_build_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_choice.fit_to_longest_item = false
	_build_choice.custom_minimum_size.y = 32
	_build_choice.tooltip_text = "Choose an existing machine or unfinished plan, including plans with no installed parts."
	_build_choice.item_selected.connect(_select_build)
	box.add_child(_build_choice)
	_selected_build = _text("", 15)
	_selected_build.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_selected_build)
	_selected_stock = _text("", 15)
	_selected_stock.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_selected_stock.add_theme_color_override("font_color", Dash.CLUTCH_BLUE)
	box.add_child(_selected_stock)
	_selected_step = _text("", 14)
	_selected_step.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_selected_step.add_theme_color_override("font_color", Dash.TEXT_2)
	box.add_child(_selected_step)
	var build_actions := HFlowContainer.new()
	box.add_child(build_actions)
	_customize_button = _button(build_actions, "Customize selected machine", func() -> void: _tabs.current_tab = _parts_page)
	_dismantle_buttons.append(_button(build_actions, "Dismantle selected", _review_dismantle))
	_cancel_unfinished_button = _button(build_actions, "Cancel unfinished", func() -> void:
		yard.cancel_plan()
		_update_build_workflow()
		_focus_start_section(is_instance_valid(yard.selected_assembly) and not yard.selected_assembly.parts.is_empty())
		_poll = 0.0)
	_cancel_unfinished_button.tooltip_text = "Cancel the selected build's unfinished placements. Installed parts stay; reserved parts are released safely."
	var custom_help := _text("In Parts: choose a part, preview, aim at a cyan connector, rotate and confirm. Cancel unfinished keeps installed parts; Dismantle recovers installed parts to storage.", 15)
	custom_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(custom_help)
	_stock_recovery = _text("", 15)
	_stock_recovery.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stock_recovery.add_theme_color_override("font_color", Dash.CLUTCH_BLUE)
	box.add_child(_stock_recovery)
	_projector_button = _button(box, "Equip Projector · place a whole blueprint", _equip_projector)
	_projector_button.tooltip_text = "Use your owned projector to choose a whole blueprint, aim its footprint at clear ground, then project a crew plan."
	box = _page(tabs, "Blueprints")
	var plans := HFlowContainer.new()
	box.add_child(plans)
	_button(plans, "Rover plan", func() -> void: yard.plan_blueprint(Plans.rover()))
	var sprung := _button(plans, "Sprung cargo rover", func() -> void: yard.plan_blueprint(FrontSuspension.blueprint()))
	sprung.tooltip_text = "Two passive front springs add 24 kg and widen the front stance. Each front tyre has 25 cm of travel in either direction. Keep loads balanced; deep diagonal steps can still unload a wheel."
	_button(plans, "Mobile workshop", func() -> void: yard.plan_blueprint(Plans.home()))
	_button(plans, "Protected workshop", func() -> void: yard.plan_blueprint(ProtectedBay.blueprint()))
	_button(plans, "Two-ended arch", func() -> void: yard.plan_blueprint(Plans.curved_rib_frame()))
	_button(plans, "Open grille", func() -> void: yard.plan_blueprint(Plans.open_grille_frame()))
	var ballast := _button(plans,"Counterweighted cargo stand",func() -> void: yard.plan_blueprint(Plans.counterweighted_cargo_stand()))
	ballast.tooltip_text = "A passive cargo cantilever with a 70 kg stone block opposite the load. Placement matters: ballast adds weight and cannot level a poor design automatically."
	var table := _button(plans,"Raised work table",func() -> void: yard.plan_blueprint(Plans.raised_work_table()))
	table.tooltip_text = "A passive 140 kg table with its top beside the chassis edge for grounded access. Original chassis, 12 kg fixed alloy strut and stone top; both end plates receive real foot work."
	_button(plans, "Eye lamp display", func() -> void: yard.plan_blueprint(Plans.eye_lamp_display()))
	var beacon := _button(plans, "Workshop beacon display", func() -> void: yard.plan_blueprint(Plans.workshop_beacon_display()))
	beacon.tooltip_text = "A standalone 6 W workshop light on an original energy cell. Its bounded 4.5 m glow has no shadows and dims with shared power."
	var horn := _button(plans,"Signal horn display",func() -> void: yard.plan_blueprint(Plans.signal_horn_display()))
	horn.tooltip_text = "A recoverable 3 kg open-bell horn on an original energy cell. Use it for one 0.35 s, 12 W signal; silent devices draw no energy."
	_button(plans, "Cargo / arm upgrade", func() -> void: yard.plan_blueprint(Plans.upgrade(), true))
	var articulation := HFlowContainer.new()
	box.add_child(articulation)
	_button(articulation, "Universal arm upgrade", func() -> void: yard.plan_blueprint(Plans.universal_upgrade(), true))
	_button(articulation, "Rover pontoons", func() -> void: yard.plan_blueprint(PontoonDesign.upgrade(), true))
	var drives := HFlowContainer.new()
	box.add_child(drives)
	_button(drives, "Rolling scout", func() -> void: yard.plan_blueprint(Plans.ballbot()))
	_button(drives, "Walking frame", func() -> void: yard.plan_blueprint(Plans.walker()))
	_button(drives, "Mind upgrade", _plan_mind_upgrade)
	var tracked := HFlowContainer.new()
	box.add_child(tracked)
	_button(tracked, "Tracked hauler", func() -> void: yard.plan_blueprint(Plans.crawler()))
	_button(tracked, "Reaction-wheel rover", func() -> void: yard.plan_blueprint(Plans.reaction_rover()))
	_button(tracked, "Solar hauler", func() -> void: yard.plan_blueprint(Plans.solar_crawler()))
	var study := HFlowContainer.new()
	box.add_child(study)
	learned = OptionButton.new()
	learned.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	study.add_child(learned)
	_study_button = _button(study, "Build studied body", func() -> void:
		if learned.selected >= 0 and learned.selected < yard.learned_blueprints.size():
			yard.plan_blueprint(yard.learned_blueprints[learned.selected]))
	box = _page(tabs, "Operate")
	_operate_page = tabs.get_tab_count() - 1
	_dismantle_review = VBoxContainer.new()
	_dismantle_review.add_theme_constant_override("separation", 9)
	box.add_child(_dismantle_review)
	_dismantle_review.add_child(_text("RECOVER THIS MACHINE'S PARTS?", 18))
	_dismantle_detail = _text("", 15)
	_dismantle_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dismantle_review.add_child(_dismantle_detail)
	var recover_actions := HFlowContainer.new()
	_dismantle_review.add_child(recover_actions)
	_dismantle_confirm = _button(recover_actions, "Begin dismantling", _confirm_dismantle)
	_button(recover_actions, "Keep this build", _close_dismantle_review)
	_dismantle_review.hide()
	var life := HFlowContainer.new()
	box.add_child(life)
	_button(life, "Awaken", yard.activate_selected)
	_button(life, "Inspect machine", yard.inspect_selected)
	_dismantle_buttons.append(_button(life, "Dismantle selected", _review_dismantle))
	var route_controls:=HFlowContainer.new()
	box.add_child(route_controls)
	_button(route_controls,"Guide to valley staging",func()->void:_set_supply_guide("valley"))
	_button(route_controls,"Clear supply guide",func()->void:_set_supply_guide(""))
	supply_guide_status=_text("",15)
	supply_guide_status.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	box.add_child(supply_guide_status)
	var cruise := HBoxContainer.new()
	box.add_child(cruise)
	cruise.add_child(_text("Helm cruise speed", 15))
	cruise_speed = SpinBox.new()
	cruise_speed.min_value = 0
	cruise_speed.max_value = 6
	cruise_speed.step = .1
	cruise_speed.suffix = "m/s"
	cruise_speed.value = 2.2
	cruise.add_child(cruise_speed)
	cruise_speed.value_changed.connect(func(value: float) -> void:
		if is_instance_valid(yard.selected_assembly):
			yard.selected_assembly.target_speed = value
			yard.selected_assembly.set_meta(&"workshop_speed", value))
	var mechanism_row := HBoxContainer.new()
	box.add_child(mechanism_row)
	mechanism_row.add_child(_text("Mechanism / rotor speed", 15))
	var mechanism := HSlider.new()
	mechanism_slider = mechanism
	mechanism.tooltip_text = "Rotors: negative/positive sets spin direction and speed; centre coasts. Spin-up applies opposite mount torque. Bearings lock separately."
	mechanism.min_value = -1
	mechanism.max_value = 1
	mechanism.step = .05
	mechanism.custom_minimum_size.x = 180
	mechanism_row.add_child(mechanism)
	mechanism.value_changed.connect(func(value: float) -> void:
		if is_instance_valid(yard.selected_assembly): yard.selected_assembly.mechanism_control = value)
	bearing_lock = CheckButton.new()
	bearing_lock.text = "Lock bearings at their current angle"
	bearing_lock.tooltip_text = "A mechanical pin locks each bearing. Release it to restore free rotation. Reverse the powered rotor lever for gradual motor braking."
	bearing_lock.toggled.connect(func(locked: bool) -> void:
		if is_instance_valid(yard.selected_assembly):
			for connection: Node3D in yard.selected_assembly.connections:
				if connection.kind == "bearing": connection.set_locked(locked))
	box.add_child(bearing_lock)
	var brake_row := HBoxContainer.new()
	box.add_child(brake_row)
	brake_row.add_child(_text("Rotary brake", 15))
	brake_slider = HSlider.new()
	brake_slider.min_value = 0
	brake_slider.max_value = 1
	brake_slider.step = .05
	brake_slider.custom_minimum_size.x = 180
	brake_slider.tooltip_text = "Gradual braking, independent of the bearing pin. Prolonged braking heats the pads and reduces their grip."
	brake_row.add_child(brake_slider)
	brake_slider.value_changed.connect(func(value: float) -> void:
		if is_instance_valid(yard.selected_assembly): yard.selected_assembly.brake_control = value)
	var save := HFlowContainer.new()
	box.add_child(save)
	_button(save, "Save blueprint", yard.save_blueprint)
	_button(save, "Load blueprint", yard.load_blueprint)
	_button(save, "Cancel unfinished", yard.cancel_plan)
	var gun_page := _page(tabs,"Guns")
	gun_interface = GunInterface.new()
	add_child(gun_interface)
	gun_interface.setup(self,gun_page)
	box = _page(tabs, "Parts")
	(box.get_parent() as ScrollContainer).follow_focus = true
	_parts_page = tabs.get_tab_count() - 1
	box.add_child(_text("CONNECTOR CONSTRUCTION", 18))
	var part_help := _text("Choose a part, preview it, then aim at a cyan connector on an installed machine. Cyan ghosts fit; amber ghosts explain what to change.", 15)
	part_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(part_help)
	_part_stock = _text("", 15)
	_part_stock.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_part_stock.max_lines_visible = 2
	box.add_child(_part_stock)
	var search_row := HBoxContainer.new()
	box.add_child(search_row)
	search_row.add_child(_text("Find a part", 15))
	_part_search = LineEdit.new()
	_part_search.placeholder_text = "Name or category: energy, bracket"
	_part_search.clear_button_enabled = true
	_part_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_part_search.custom_minimum_size.y = 32
	_part_search.tooltip_text = "Search part names and categories. Clear the search to see every part. Missing stock may still be planned for Wako to build later."
	search_row.add_child(_part_search)
	_part_matches = _text("", 14)
	_part_matches.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_part_matches)
	catalogue = OptionButton.new()
	catalogue.fit_to_longest_item = false
	catalogue.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_populate_part_catalogue("")
	box.add_child(catalogue)
	var tools := HFlowContainer.new()
	box.add_child(tools)
	_part_actions.append(_button(tools, "Preview part / plan work", func() -> void: _start_placement(false)))
	_part_actions.append(_button(tools, "Install nearby part", func() -> void: _start_placement(true)))
	_part_actions.append(_button(tools, "Release stock", _release_stock))
	var finish_row := HBoxContainer.new()
	box.add_child(finish_row)
	finish_row.add_child(_text("Shell finish", 15))
	finish_choice = OptionButton.new()
	finish_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	finish_choice.add_item("Original stone / metal")
	finish_choice.set_item_metadata(0, "original")
	for finish: String in Catalogue.FINISHES:
		finish_choice.add_item(Catalogue.FINISHES[finish].title)
		finish_choice.set_item_metadata(finish_choice.item_count - 1, finish)
	finish_choice.tooltip_text = "Choose a shell colour for new components or your selected machine."
	finish_row.add_child(finish_choice)
	var refinishing := HFlowContainer.new()
	box.add_child(refinishing)
	_button(refinishing, "Paint aimed part", _paint_aimed)
	_button(refinishing, "Paint selected machine", _paint_selected)
	var attachment_row := HBoxContainer.new()
	box.add_child(attachment_row)
	attachment_row.add_child(_text("Part connector", 15))
	connector_choice = OptionButton.new()
	connector_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	attachment_row.add_child(connector_choice)
	connector_angle = SpinBox.new()
	connector_angle.min_value = -180
	connector_angle.max_value = 180
	connector_angle.step = 1
	connector_angle.suffix = "°"
	connector_angle.tooltip_text = "Rotate around this connector. For a pitched ramp, connect its exit to the chassis rear ramp mount."
	attachment_row.add_child(connector_angle)
	_update_connector_choices()
	beam_parameters = VBoxContainer.new()
	box.add_child(beam_parameters)
	beam_profile = OptionButton.new()
	for profile: String in Catalogue.BeamGeometry.PROFILES:
		beam_profile.add_item(Catalogue.BeamGeometry.PROFILES[profile])
		beam_profile.set_item_metadata(beam_profile.item_count - 1, profile)
	beam_profile.tooltip_text = "Profiles require matching recovered stock. Tube bores and I-section gaps remain physically open."
	beam_parameters.add_child(beam_profile)
	beam_profile.item_selected.connect(func(_index: int) -> void: _update_connector_choices())
	var dimensions := HBoxContainer.new()
	beam_parameters.add_child(dimensions)
	dimensions.add_child(_text("Beam length", 15))
	beam_length = SpinBox.new()
	beam_length.min_value = .3
	beam_length.max_value = 8
	beam_length.step = .1
	beam_length.value = 2
	beam_length.suffix = "m"
	dimensions.add_child(beam_length)
	beam_parameters.add_child(_text("Wako cut matching stock and keep usable offcuts.\nEach profile requires its full length of material.", 14))
	beam_parameters.hide()
	wheel_parameters = VBoxContainer.new()
	box.add_child(wheel_parameters)
	wheel_parameters.add_child(_text("WHEEL STOCK", 16))
	wheel_profile = OptionButton.new()
	var wheel_notes := {
		"offroad": "Balanced solid wheel with tread. Original stock and axle geometry.",
		"slick": "Lighter smooth wheel with reduced ground grip.",
		"spiked": "Heavy metal tips catch edges; expect a rougher ride.",
		"paddle": "Wide cleats for uneven ground; allow room around the axle.",
		"airless": "Light open-spoke ring. Stiff support without a pneumatic cushion."}
	for profile: String in Catalogue.WheelGeometry.PROFILES:
		wheel_profile.add_item(Catalogue.WheelGeometry.PROFILES[profile])
		wheel_profile.set_item_metadata(wheel_profile.item_count - 1, profile)
		var definition := Catalogue.get_def("wheel", {"wheel_profile": profile})
		wheel_profile.set_item_tooltip(wheel_profile.item_count - 1, "%s\n%.0f kg · %.2f ground grip" % [wheel_notes[profile], definition.mass, definition.friction])
	wheel_parameters.add_child(wheel_profile)
	wheel_parameters.add_child(_text("Use matching recovered wheels; stock keeps its profile.", 14))
	wheel_profile.item_selected.connect(func(_index: int) -> void: _update_connector_choices())
	wheel_parameters.hide()
	wing_editor = AirfoilEditor.new()
	box.add_child(wing_editor)
	wing_editor.setup(Catalogue.WingGeometry)
	wing_editor.parameters_changed.connect(func(_values: Dictionary) -> void: _update_connector_choices())
	wing_editor.hide()
	plate_editor = PlateEditor.new()
	box.add_child(plate_editor)
	plate_editor.setup()
	plate_editor.parameters_changed.connect(func(_values: Dictionary) -> void: _update_connector_choices())
	plate_editor.hide()
	flight_editor = FlightEditor.new()
	box.add_child(flight_editor)
	flight_editor.setup()
	flight_editor.hide()
	cockpit_parameters = VBoxContainer.new()
	box.add_child(cockpit_parameters)
	cockpit_parameters.add_child(_text("MOTION CONTROLS", 16))
	cockpit_mode = OptionButton.new()
	cockpit_mode.add_item("Ground: forward and turn")
	cockpit_mode.add_item("Flight: pitch, yaw, roll and throttle")
	cockpit_parameters.add_child(cockpit_mode)
	cockpit_parameters.add_child(_text("Wako never drive. Latched levers keep their setting\nafter you leave; powered hinges move wings and fan pods.", 14))
	cockpit_parameters.hide()
	bearing_parameters = VBoxContainer.new()
	box.add_child(bearing_parameters)
	bearing_parameters.add_child(_text("BEARING STOCK",16))
	bearing_direction = OptionButton.new()
	for direction in [0,-1,1]:
		bearing_direction.add_item(Catalogue.BearingFreewheel.label({Catalogue.BearingFreewheel.KEY:direction}))
		bearing_direction.set_item_metadata(bearing_direction.item_count-1,direction)
		bearing_direction.set_item_disabled(bearing_direction.item_count-1,direction!=0 and not Catalogue.BearingFreewheel.available())
	bearing_direction.tooltip_text = "Fixed recovered inserts require matching stock. Reverse grip is finite: overload slips and heats the pads. Direction is viewed from the marked right face."
	bearing_parameters.add_child(bearing_direction)
	bearing_direction.item_selected.connect(func(_index: int) -> void: _update_connector_choices())
	bearing_parameters.hide()
	catalogue.item_selected.connect(func(index: int) -> void:
		_part_filter_selection = str(catalogue.get_item_metadata(index))
		_select_catalogue_part(index))
	_part_search.text_changed.connect(_filter_parts)
	_part_search.text_submitted.connect(func(_query: String) -> void:
		if not catalogue.disabled:
			_part_filter_selection = str(catalogue.get_item_metadata(catalogue.selected))
			catalogue.grab_focus())
	symmetry = OptionButton.new()
	for name_: String in ["Single", "Mirror across chassis", "Radial ×4"]:
		symmetry.add_item(name_)
	box.add_child(symmetry)
	_instructions = _text("", 15)
	_instructions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_instructions)
	box = _page(tabs, "Crew")
	box.add_child(_text("Your Wako choose useful work automatically.", 15))
	crew_status = _text("", 15)
	crew_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(crew_status)
	crew_travel_status=_text("",15)
	crew_travel_status.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	box.add_child(crew_travel_status)
	crew_travel_resume=_button(box,"Resume original crew route",func()->void:yard.crew_travel_resume())
	crew_travel_cancel=_button(box,"Hold original crew here",func()->void:yard.crew_travel_cancel())
	crew_travel_cancel.tooltip_text="The original helpers stay at their actual local position; no automatic distant depot return."
	var work := HFlowContainer.new()
	frame.add_child(work)
	work_pause_button = _button(work, "Pause work", func() -> void:
		yard.work_paused = not yard.work_paused
		_poll = 0.0)
	_button(work, "Close", func() -> void: toggle(false))
	hud = _text("", 17)
	hud.position = Vector2(26, 26)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_theme_constant_override("outline_size", 5)
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, .85))
	layer.add_child(hud)
	_build_entry = _button(layer, "Build contraption", func() -> void: InputHub.tap_action(&"contraption_bench"))
	_build_entry.custom_minimum_size = Vector2(270, 58)
	_build_entry.focus_mode = Control.FOCUS_NONE
	_build_entry.add_theme_stylebox_override("disabled", _build_entry.get_theme_stylebox("normal"))
	_build_entry.add_theme_color_override("font_disabled_color", Dash.TEXT)
	_build_entry.tooltip_text = "Open starter plans, your owned Blueprint Projector and connector construction."
	_build_entry.hide()
	panel.hide()
	placement = Placement.new()
	yard.add_child(placement)
	placement.setup(yard)
	_resize_panel()

func _page(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 7)
	scroll.add_child(content)
	return content

func _resize_panel() -> void:
	var screen := get_viewport().get_visible_rect().size
	var margin := Vector2(28, 28) if screen.x >= 600 and screen.y >= 500 else Vector2(12, 12)
	panel.position = margin
	panel.size = Vector2(minf(540, screen.x - margin.x * 2), minf(660, screen.y - margin.y * 2))
	_build_entry.position = Vector2(maxf(margin.x, screen.x - 308), margin.y)
	_build_entry.size = Vector2(minf(280, screen.x - margin.x * 2), 58)
	var shortcuts := get_tree().get_first_node_in_group(&"global_shortcuts_panels")
	if is_instance_valid(shortcuts) and shortcuts.has_method(&"screen_rect"):
		var occupied: Rect2 = shortcuts.screen_rect()
		if Rect2(_build_entry.position, _build_entry.size).intersects(occupied):
			_build_entry.position.x = maxf(margin.x, occupied.position.x - _build_entry.size.x - 12)
	hud.size.x = maxf(200, minf(680, _build_entry.position.x - 52))
	hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

func _text(value: String, size: int) -> Label:
	var l := Label.new()
	l.text = value
	l.add_theme_font_override("font", Dash.font("reg"))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Dash.TEXT)
	return l

func _button(parent: Node, text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 32
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(.09, .13, .15)
	normal.border_color = Color(Dash.BRONZE, .5)
	normal.set_border_width_all(1)
	normal.content_margin_left = 9
	normal.content_margin_right = 9
	b.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(.15, .23, .24)
	hover.border_color = Dash.CLUTCH_BLUE
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_font_override("font", Dash.font("reg"))
	b.add_theme_font_size_override("font_size", 15)
	b.pressed.connect(func() -> void: callback.call())
	parent.add_child(b)
	return b

func is_open() -> bool:
	return panel != null and panel.visible

func toggle(open: bool) -> void:
	if open == is_open():
		return
	if open:
		if placement.enabled:
			placement.end()
		var aimed := _aimed_part()
		if is_instance_valid(aimed) and not aimed.get_meta(&"loose_shared_gun",false) and aimed.installed and yard.assemblies.has(aimed.assembly) and not aimed.assembly.get_meta(&"disabled_donor", false):
			yard.select_assembly(aimed.assembly.get_instance_id())
		_tabs.current_tab = 0
		_update_build_workflow()
		if gun_interface: gun_interface.capture_context()
		_last_mouse = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_close_dismantle_review()
		Input.mouse_mode = _last_mouse
	panel.visible = open
	if open:
		var unfinished := _unfinished_work(yard.selected_assembly)
		_focus_start_section(unfinished.placements > 0 or unfinished.welds > 0)
	hud.visible = not open
	_build_entry.visible = not open
	_set_tool_holster(open or (placement.enabled and not placement.direct))
	_poll = 0.0

func _tool_manager() -> Node:
	var player := Core.player()
	return player.find_child("HandToolManager", true, false) if is_instance_valid(player) else null

func _owns_projector(manager: Node) -> bool:
	if not is_instance_valid(manager):
		return false
	for slot: ToolDef in manager.slots:
		if slot.id == &"blueprint_projector":
			return true
	return false

func _equip_projector() -> void:
	var manager := _tool_manager()
	if not _owns_projector(manager):
		yard.last_message = "The Blueprint Projector is not in your owned tools. Use the bench plans or recover the tool."
		return
	if not bool(Core.player().get(&"active")):
		yard.last_message = "Leave the helm before equipping the Blueprint Projector."
		return
	toggle(false)
	manager.select_tool(&"blueprint_projector")

func _start_rover() -> void:
	if yard.plan_blueprint(Plans.rover()):
		yard.last_message += " Close Build to watch your crew; reopen it to customize installed parts."
	_update_build_workflow()
	_poll = 0.0

func _select_starter(index: int) -> void:
	if index < 0 or index >= _starter_plans.size(): return
	var entry: Dictionary = _starter_plans[index]
	_starter_detail.text = "%s\n%d parts · Wako build every piece." % [entry.detail, entry.plan.parts.size()]
	_starter_diagram.set_plan(entry.plan)
	_starter_button.text = entry.action
	_starter_button.tooltip_text = "Create this unfinished plan at a checked workshop site. Missing stock waits for recovery; installed parts are never granted."
	_update_starter_stock()
	_poll = 0.0

func _update_starter_stock() -> void:
	var entry: Dictionary = _starter_plans[_starter_choice.selected]
	var stock := ProjectorLibrary.stock(yard, entry.plan)
	_starter_stock.text = "%s stock: %d / %d pieces ready · %.0f kg\n%s" % [entry.plan.name, stock.ready, stock.total, stock.mass,
		"Ready for crew construction." if stock.complete else "Recover and store: " + String(stock.needs)]
	_starter_stock.tooltip_text = _starter_stock.text + "\nCounts stored, unreserved pieces for a new plan; installed and reserved pieces are excluded."

func _start_starter() -> void:
	var entry: Dictionary = _starter_plans[_starter_choice.selected]
	var previous: Node3D = yard.selected_assembly
	if _starter_choice.selected == 1:
		_start_rover()
	else:
		if yard.plan_blueprint(entry.plan):
			yard.last_message += " Close Build to watch your crew; reopen it to follow this plan."
		_update_build_workflow()
		_poll = 0.0
	if is_instance_valid(yard.selected_assembly) and yard.selected_assembly != previous:
		_focus_start_section(true)

func _focus_start_section(continue_build: bool) -> void:
	var target: Control = _build_choice if continue_build else _starter_choice
	target.grab_focus()
	_reveal_start_section.call_deferred(target)

func _reveal_start_section(target: Control) -> void:
	# Wait for wrapped status and card text to settle before positioning the page.
	# follow_focus still follows subsequent keyboard/gamepad navigation normally.
	await get_tree().process_frame
	if not is_open() or _tabs.current_tab != 0 or not target.has_focus(): return
	var scroll := _tabs.get_child(0) as ScrollContainer
	scroll.scroll_vertical = roundi(_continue_heading.position.y) if target == _build_choice else 0

func _review_dismantle() -> void:
	var selected: Node3D = yard.selected_assembly
	if is_instance_valid(selected) and yard._dismantling.has(selected.get_instance_id()):
		yard.stop_dismantle()
		_close_dismantle_review()
		_update_build_workflow()
		_poll = 0.0
		return
	var reason: String = yard.dismantle_selection_reason(selected)
	if not reason.is_empty():
		yard.last_message = reason
		_poll = 0.0
		return
	_dismantle_identity = selected.get_instance_id()
	_dismantle_review.show()
	_tabs.current_tab = _operate_page
	_update_dismantle_review()
	_dismantle_confirm.grab_focus()

func _close_dismantle_review() -> void:
	_dismantle_identity = 0
	_dismantle_review.hide()

func _update_dismantle_review() -> void:
	if _dismantle_identity == 0: return
	var selected: Node3D = yard.selected_assembly
	if not is_instance_valid(selected) or selected.get_instance_id() != _dismantle_identity \
		or yard._dismantling.has(_dismantle_identity):
		_close_dismantle_review()
		return
	var installed: int = selected.parts.values().filter(func(part: Node) -> bool: return is_instance_valid(part) and part.installed).size()
	var pending: int = selected.parts.size() - installed
	var reason: String = yard.dismantle_selection_reason(selected)
	_dismantle_detail.text = "%s\nWako will release %d installed part%s, working from the outside toward the chassis, then return the real parts to storage. Movement turns off.\nUnfinished placements: %d. These will be cancelled and their reserved stock recovered.\nChoose Stop dismantling to keep the installed parts that remain." % [_build_name(selected), installed, "" if installed == 1 else "s", pending]
	if not reason.is_empty(): _dismantle_detail.text += "\n" + reason
	_dismantle_confirm.disabled = not reason.is_empty()
	_dismantle_confirm.text = "Recover %d installed part%s" % [installed, "" if installed == 1 else "s"]

func _confirm_dismantle() -> void:
	var selected: Node3D = yard.selected_assembly
	if not is_instance_valid(selected) or selected.get_instance_id() != _dismantle_identity:
		yard.last_message = "The selected build changed. Review its dismantling before recovering parts."
		_close_dismantle_review()
		return
	if yard.plan_dismantle(): _close_dismantle_review()
	_update_build_workflow()
	_poll = 0.0

func _build_name(build: Node3D) -> String:
	var blueprint: String = build.get_meta(&"blueprint_name", "")
	return "%s · %s" % [blueprint, String(build.name)] if not blueprint.is_empty() else String(build.name)

func _select_build(index: int) -> void:
	if index < 0 or index >= _build_choice.item_count:
		return
	var identity: Variant = _build_choice.get_item_metadata(index)
	if not identity is int or not yard.select_assembly(identity):
		yard.last_message = "This build is no longer available. Choose a current build from Your builds."
	else:
		yard.last_message = "Selected build: %s. Cancel unfinished keeps installed parts; Operate has Dismantle." % _build_name(yard.selected_assembly)
	_update_build_workflow()
	_focus_start_section(true)
	_poll = 0.0

func _update_build_picker() -> void:
	var builds: Array[Node3D] = []
	for candidate: Variant in yard.assemblies:
		if is_instance_valid(candidate) and not candidate.is_queued_for_deletion() \
			and not candidate.get_meta(&"disabled_donor", false) and not candidate.parts.is_empty():
			builds.append(candidate)
	var selected_id: int = yard.selected_assembly.get_instance_id() if is_instance_valid(yard.selected_assembly) else 0
	if selected_id > 0 and not builds.any(func(build: Node3D) -> bool: return build.get_instance_id() == selected_id):
		yard.selected_assembly = null
		selected_id = 0
	# Keep open popup rows fixed until the player's choice has been validated.
	# Deletion may invalidate a row, but must never shift it onto another build.
	if _build_choice.get_popup().visible:
		return
	var changed := _build_choice.item_count != builds.size() + 1
	if not changed:
		for index in builds.size():
			if _build_choice.get_item_metadata(index + 1) != builds[index].get_instance_id():
				changed = true
				break
	if changed:
		_build_choice.clear()
		_build_choice.add_item("Choose a build" if not builds.is_empty() else "No builds yet")
		_build_choice.set_item_metadata(0, 0)
		_build_choice.set_item_disabled(0, true)
		for build: Node3D in builds:
			_build_choice.add_item("")
			_build_choice.set_item_metadata(_build_choice.item_count - 1, build.get_instance_id())
	var selected_index := 0
	for index in builds.size():
		var build: Node3D = builds[index]
		var installed: int = build.parts.values().filter(func(part: Node) -> bool: return is_instance_valid(part) and part.installed).size()
		var label := "%s · %d / %d installed" % [_build_name(build), installed, build.parts.size()]
		_build_choice.set_item_text(index + 1, label)
		_build_choice.set_item_tooltip(index + 1, "%s\n%d installed; %d planned. Cancel unfinished keeps installed parts; Operate has Dismantle." % [label, installed, build.parts.size() - installed])
		if build.get_instance_id() == selected_id: selected_index = index + 1
	_build_choice.select(selected_index)
	_build_choice.disabled = builds.is_empty()

func _unfinished_work(selected: Node3D) -> Dictionary:
	var pending := {"placements": 0, "welds": 0}
	if not is_instance_valid(selected) or not yard.assemblies.has(selected) \
		or selected.get_meta(&"disabled_donor", false): return pending
	for part: Node in selected.parts.values():
		if is_instance_valid(part) and not part.installed: pending.placements += 1
	# Installed pieces can still require a closing connector weld. Read the
	# same native connections used by cancellation and the crew scheduler.
	for descriptor: Dictionary in yard._plans.get(selected.get_instance_id(), []):
		var part: Node = selected.parts.get(descriptor.id)
		if not is_instance_valid(part) or not part.installed: continue
		for mount: Dictionary in descriptor.get("secondary_mounts", []):
			var connection: Node = yard._secondary_connection(selected, descriptor.id, mount)
			if not is_instance_valid(connection) or connection.broken: pending.welds += 1
	return pending

func _update_build_workflow() -> void:
	_update_build_picker()
	_selected_feedback = _selected_progress_status(yard.selected_assembly)
	_update_starter_stock()
	var selected: Node3D = yard.selected_assembly
	var installed := 0
	if is_instance_valid(selected) and yard.assemblies.has(selected) and not selected.get_meta(&"disabled_donor", false):
		for part: Node3D in selected.parts.values():
			if part.installed: installed += 1
	var dismantling: bool = is_instance_valid(selected) and yard._dismantling.has(selected.get_instance_id())
	_customize_button.disabled = installed == 0 or dismantling
	_customize_button.focus_mode = Control.FOCUS_NONE if _customize_button.disabled else Control.FOCUS_ALL
	_customize_button.tooltip_text = "Stop dismantling before adding parts to this machine." if dismantling \
		else "Let your crew install the first part before adding connector parts." if installed == 0 \
		else "Choose a part, preview its snapped connector, then confirm the crew plan."
	var unfinished := _unfinished_work(selected)
	for button: Button in _dismantle_buttons:
		button.disabled = installed == 0
		button.focus_mode = Control.FOCUS_NONE if button.disabled else Control.FOCUS_ALL
		button.text = "Stop dismantling selected" if dismantling else "Dismantle selected"
		button.tooltip_text = "Keep the installed parts that remain. Released parts still return to storage." if dismantling \
			else "Review the selected machine before asking Wako to recover its installed parts."
	_update_dismantle_review()
	_cancel_unfinished_button.disabled = unfinished.placements == 0 and unfinished.welds == 0
	_cancel_unfinished_button.focus_mode = Control.FOCUS_NONE if _cancel_unfinished_button.disabled else Control.FOCUS_ALL
	_cancel_unfinished_button.tooltip_text = "Cancel %d unfinished placement%s and %d connector weld%s. Installed parts and completed welds stay; reserved stock returns safely." % [unfinished.placements, "" if unfinished.placements == 1 else "s", unfinished.welds, "" if unfinished.welds == 1 else "s"]
	_selected_build.text = "No build selected. Choose one from Your builds, or Start a rover." if installed == 0 \
		else "Selected machine: %d / %d parts installed. Add parts at its compatible connectors." % [installed, selected.parts.size()]
	if is_instance_valid(selected) and yard.assemblies.has(selected) and not selected.get_meta(&"disabled_donor", false) and not selected.parts.is_empty() and installed == 0:
		_selected_build.text = "Selected plan: 0 / %d parts installed. Let your crew install its chassis before adding connector parts." % selected.parts.size()
	if is_instance_valid(selected) and yard.assemblies.has(selected) and not selected.get_meta(&"disabled_donor", false) and not selected.parts.is_empty():
		_selected_build.text = _selected_feedback
	_selected_build.tooltip_text = _selected_build.text
	_update_selected_stock(selected, installed, dismantling)
	var owns_projector := _owns_projector(_tool_manager())
	_projector_button.disabled = not owns_projector or not bool(Core.player().get(&"active"))
	_projector_button.text = "Equip Projector · place a whole blueprint" if not _projector_button.disabled else "Leave helm to equip Projector" if owns_projector else "Blueprint Projector not owned"
	if catalogue.disabled:
		_part_stock.text = "Clear or shorten Find a part to choose a component."
		_part_stock.tooltip_text = _part_stock.text
		return
	var kind: String = catalogue.get_item_metadata(catalogue.selected)
	var pieces: Array = []
	for index in range(int([1, 2, 4][symmetry.selected])):
		pieces.append({"id": "preview_%d" % index, "kind": kind, "parameters": _shape_parameters(kind)})
	var part_stock := ProjectorLibrary.stock(yard, {"parts": pieces})
	_part_stock.text = "%d / %d matching stored parts ready. %s" % [part_stock.ready, part_stock.total,
		"Wako fetch and install after you confirm." if part_stock.complete else "A plan can wait for recovered stock: " + String(part_stock.needs)]
	_part_stock.tooltip_text = _part_stock.text

func _update_selected_stock(selected: Node3D, installed: int, dismantling: bool) -> void:
	var chosen: bool = is_instance_valid(selected) and yard.assemblies.has(selected) \
		and not selected.get_meta(&"disabled_donor", false) and not selected.parts.is_empty()
	_selected_stock.visible = chosen and not dismantling and installed < selected.parts.size()
	_selected_step.visible = chosen
	if not chosen: return
	if dismantling:
		_selected_step.text = "Resume work continues dismantling. Stop dismantling keeps the installed parts that remain." if yard.work_paused \
			else "Wako return released parts to storage. Stop dismantling keeps the installed parts that remain."
		return
	var pending: int = selected.parts.size() - installed
	var supplied := true
	if pending > 0:
		var descriptors: Array = []
		for part: Node3D in selected.parts.values():
			if not part.installed: descriptors.append({"id": part.part_id, "kind": part.kind, "parameters": part.parameters})
		var selection: Dictionary = yard.worksite_context() if yard.worksite_active() else {}
		if yard.worksite_active(): selection.legacy = false
		var stock := ProjectorLibrary.stock(yard, {"parts": descriptors}, selection, selected)
		var assigned: int = ProjectorLibrary._claimed_stock(yard, selected).size()
		supplied = stock.complete
		_selected_stock.text = "Stock for this build: %d / %d remaining pieces ready" % [stock.ready, stock.total]
		if assigned > 0: _selected_stock.text += " · %d already assigned" % assigned
		if not stock.complete: _selected_stock.text += "\nRecover and store: " + String(stock.needs)
		_selected_stock.tooltip_text = _selected_stock.text + "\nCounts matching stored parts and stock already assigned to this build. Stock used by other plans is excluded."
	if yard.work_paused:
		_selected_step.text = "Resume work continues existing plans, repairs and salvage for all Wako. Pause keeps this plan."
	elif pending > 0 and not supplied:
		_selected_step.text = "Store the missing parts so your crew can finish. Cancel unfinished keeps installed parts."
	elif pending > 0 and installed == 0:
		_selected_step.text = "Your crew must install the first part before Customize unlocks. Close Build to watch their work."
	elif pending > 0:
		_selected_step.text = "Close Build to watch the crew, or Customize to add a snapped part."
	elif _unfinished_work(selected).welds > 0:
		_selected_step.text = "Let Wako finish the connector welds before Awaken, or Cancel unfinished to keep only completed welds."
	else:
		_selected_step.text = "Customize adds snapped parts. Dismantle has Wako recover this machine's installed parts."

func _selected_progress_status(selected: Node3D) -> String:
	_selected_work_job_id = ""
	if not is_instance_valid(selected) or not yard.assemblies.has(selected) \
		or selected.get_meta(&"disabled_donor", false) or selected.parts.is_empty(): return ""
	var installed := 0
	for part: Node3D in selected.parts.values():
		if is_instance_valid(part) and part.installed: installed += 1
	var title: String = selected.get_meta(&"blueprint_name", String(selected.name))
	var progress := "Dismantling %s · %d parts remain" % [title, installed] if yard._dismantling.has(selected.get_instance_id()) \
		else "%s · %d / %d installed" % [title, installed, selected.parts.size()]
	var unfinished := _unfinished_work(selected)
	if not yard._dismantling.has(selected.get_instance_id()) and unfinished.welds > 0:
		progress += " | %d connector weld%s pending" % [unfinished.welds, "" if unfinished.welds == 1 else "s"]
	var work := _selected_work_status(selected)
	return progress + ("\n" + work if not work.is_empty() else "")

func _selected_work_status(selected: Node3D) -> String:
	if yard.work_paused:
		return "Work paused; press Resume work."
	var safety := _build_safety_status(selected)
	if not safety.is_empty(): return safety
	var coordinator: Node = yard.coordinator
	var work := ""
	if is_instance_valid(coordinator):
		# Read the existing scheduler observations. Other salvage jobs must not
		# replace this selected plan's progress or its exact blocked component.
		for entry: Dictionary in coordinator.active_jobs.values():
			var target: Node = entry.job.get("target")
			if not is_instance_valid(target) or target.get("assembly") != selected: continue
			var crew: Array = entry.crew
			if crew.is_empty() or not is_instance_valid(crew[0]): continue
			work = _active_work_feedback(entry)
			_selected_work_job_id = String(entry.job.get("id", ""))
			break
		for kind: String in ["build", "join", "dismantle", "replace"]:
			var prefix := "%s:%d:" % [kind, selected.get_instance_id()]
			for job_id: String in coordinator.blocked:
				if not job_id.begins_with(prefix): continue
				var part: Node = selected.parts.get(job_id.get_slice(":", 2))
				var reason := String(coordinator.blocked[job_id])
				# Keep the truthful current crew need and the same build's actual
				# last failed carry. Other salvage must not erase that physical cause.
				if reason.contains(" Wako needed for "):
					var prior_carry: String=coordinator.prior_head_return_reason(job_id)
					if not prior_carry.is_empty(): reason+="\nPrevious carry failed: "+_carry_failure_text(prior_carry)
				reason = _selected_part_reason(part, reason)
				return work + "\n" + reason if not work.is_empty() else reason
	if not work.is_empty(): return work
	# A missing-stock slot has no schedulable source/job. Keep its actual
	# selected part and known need instead of an unlabelled workshop fallback.
	for part: Variant in selected.parts.values():
		if not is_instance_valid(part) or part.installed or not part.has_meta(&"needs"): continue
		var need := String(part.get_meta(&"needs"))
		if not need.is_empty(): return _selected_part_reason(part, need)
	return ""

func _stock_recovery_status() -> String:
	# A dismantled machine disappears from Your builds before its original
	# loose stock reaches storage. Keep those actual returns visible, using
	# only their own current scheduler observations rather than other jobs.
	var recovering: Array = yard.loose_parts.filter(func(part: Node) -> bool:
		return is_instance_valid(part) and not part.is_queued_for_deletion() \
			and part.get_meta(&"returning_released_stock", false) and not part.get_meta(&"stored", false))
	if recovering.is_empty(): return ""
	var lines: Array[String] = ["Recovering %d real part%s to storage" % [recovering.size(), "" if recovering.size() == 1 else "s"]]
	if yard.work_paused:
		lines.append("Work paused; press Resume work to return released stock.")
	var coordinator: Node = yard.coordinator
	var shown := 0
	for part: Node in recovering:
		if shown >= 6: break
		if not is_instance_valid(part) or part.is_queued_for_deletion(): continue
		shown += 1
		var id: String = "salvage:" + part.part_id
		var reason := "Waiting for Wako to recover this released part."
		var active: Dictionary = coordinator.active_jobs.get(id, {}) if is_instance_valid(coordinator) else {}
		var job: Dictionary = active.get("job", {})
		var active_part: Node = job.get("part")
		var crew: Array = active.get("crew", [])
		if part.get_meta(&"player_carry", false):
			var collection_action := "Quick menu: Salvage / place component" if Keys.pad_mode() else Keys.label_for(&"contraption_use")
			reason = "Drop this part, then aim at it and use %s to return it to Wako collection." % collection_action
		elif is_instance_valid(active_part) and not active_part.is_queued_for_deletion() and active_part == part and not crew.is_empty() and is_instance_valid(crew[0]) and not crew[0].is_queued_for_deletion():
			reason = _active_work_feedback(active)
		elif is_instance_valid(coordinator) and coordinator.blocked.has(id):
			reason = str(coordinator.blocked[id])
			if reason.contains(" Wako needed for "):
				var prior: String = coordinator.prior_head_return_reason(id)
				if not prior.is_empty(): reason += " Previous return failed: " + prior
		elif is_instance_valid(coordinator) and float(coordinator._retry_after.get(id, 0.0)) > coordinator._clock:
			reason = str(coordinator._retry_reasons.get(id, reason))
		if reason.begins_with("Original stock lacks clear supported launch access;") or reason.begins_with("Head-first launch footing did not settle;"):
			reason += " Pause work, use the Grabber to move the loose part onto clear level ground, release it, then Resume work."
		lines.append("%s%s: %s" % [part.definition.title, _work_location(part), _work_reason_text(reason)])
	if recovering.size() > shown: lines.append("%d more released parts awaiting recovery." % (recovering.size() - shown))
	return "\n".join(lines)

func _selected_part_reason(part: Variant, reason: String) -> String:
	if reason.is_empty(): return ""
	var message := "%s%s: %s" % [part.definition.title, _work_location(part), _work_reason_text(reason)] if is_instance_valid(part) else _work_reason_text(reason)
	if reason.begins_with("Missing stored "):
		message += " Recover and store matching stock."
	return message

func _work_location(body: Node3D) -> String:
	var player := Core.player()
	if not is_instance_valid(body) or not is_instance_valid(player): return ""
	var offset: Vector3 = body.global_position - player.global_position
	var horizontal := Vector2(offset.x, offset.z)
	if horizontal.length() < 1.0: return " · beside you"
	var compass: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var bearing := posmod(roundi(atan2(horizontal.x, -horizontal.y) / (PI / 4.0)), 8)
	return " · %d m %s" % [roundi(horizontal.length()), compass[bearing]]

func _work_crew_label(crew: Array) -> String:
	var names: Array[String] = []
	for worker: Variant in crew:
		if not is_instance_valid(worker) or not worker is Node3D or worker.is_queued_for_deletion(): continue
		var title: String = worker.helper_name
		if title == "Captive Wako" and worker.worker_id.begins_with("captive_") \
			and worker.get_parent() == yard and yard.workers.has(worker) and not worker.is_in_group(&"captive_wakos"):
			title = "Rescued Wako"
		names.append(title + _work_location(worker))
	return " / ".join(names) if names.size() <= 1 else "%d Wako (%s)" % [names.size(), "; ".join(names)]

func _worker_work_text(worker: Node) -> String:
	# Existing status/custody observations only; UI does not test reach or clearance.
	var message: String = worker.tool_pose_blocked if not worker.tool_pose_blocked.is_empty() else worker.needs if not worker.needs.is_empty() else worker.status_text
	var equipped: Variant = worker.equipped_tool
	if not is_instance_valid(equipped) and is_instance_valid(worker.coordinator):
		var active: Dictionary = worker.coordinator.active_jobs.get(worker.current_job_id, {})
		if active.get("crew", []).has(worker): equipped = active.get("job", {}).get("tool")
	var tool_title: String = equipped.definition.title if is_instance_valid(equipped) and not equipped.is_queued_for_deletion() else "work tool"
	if worker.tool_pose_blocked.is_empty() and worker.needs.is_empty() and _loaded_route_wait(worker):
		return "Carrying %s: waiting for a supported path. Clear the carrying passage; Pause work before moving loose parts, then Resume work." % worker._cargo_source.definition.title
	if message == "Waiting for Wako to clear the full tool passage":
		return "Waiting for Wako to clear %s's fitting passage. Give the tool crew room." % tool_title
	if message == "Clearing the full work tool passage":
		return "Clearing the tool passage so the crew can fit and stow %s." % tool_title
	if message == "Retaining the current supported original tool while its return clears":
		return "Waiting for room to stow %s. Keep nearby floor and its backpack passage clear." % tool_title
	if message in ["No clear supported retained-tool posture", "No clear supported retained-tool posture; recovering physically"]:
		return "Keeping %s clear while regaining footing. Give this Wako room to stand." % tool_title
	if message.begins_with("Recovering actual soles before head-first "):
		return "Planting feet to pick up " + message.trim_prefix("Recovering actual soles before head-first ")
	if message.begins_with("Planting feet for head-first "):
		return "Planting feet to pick up " + message.trim_prefix("Planting feet for head-first ")
	if message.begins_with("Stowing original tool before head-first "):
		return "Stowing %s to pick up %s" % [tool_title, message.trim_prefix("Stowing original tool before head-first ")]
	if message == "Giving the tool crew room to fit and stow":
		return "Clearing tool passage; give the working crew room."
	if message == "Can't reach the tool on its back. Clear nearby parts or give the Wako room to stand.":
		message = "Can't retrieve %s from its backpack. Clear nearby loose parts and give this Wako room to stand." % tool_title
	return _idle_blocked_work_text(worker, message)

func _idle_blocked_work_text(worker: Node, message: String) -> String:
	# Idle helpers mirror a workshop refusal without owning that job. Keep
	# exact cached matches, with a bounded display of five real job parts.
	if worker.current_job_id.is_empty() and not worker.needs.is_empty() and message == worker.needs and is_instance_valid(worker.coordinator):
		var waiting: Array[String] = []
		var matches := 0
		for job: Dictionary in worker.coordinator._jobs:
			if String(worker.coordinator.blocked.get(String(job.get("id", "")), "")) != message: continue
			var part: Variant = job.get("part")
			if not is_instance_valid(part) or part.is_queued_for_deletion() or not part.get("definition") is Dictionary: continue
			matches += 1
			if waiting.size() < 5: waiting.append(part.definition.title + _work_location(part))
		if not waiting.is_empty():
			var overflow := "; %d more" % (matches - waiting.size()) if matches > waiting.size() else ""
			return "Waiting for %s%s: %s" % ["; ".join(waiting), overflow, _work_reason_text(message)]
	return _work_reason_text(message)

func _loaded_route_wait(worker: Node) -> bool:
	# This is the existing refused local-machine route, never a new query or a
	# guess about the obstruction. Keep the real job, cargo and retry lifetime.
	if not worker.carrying or not is_instance_valid(worker.coordinator): return false
	var coordinator: Node = worker.coordinator
	var active: Dictionary = coordinator.active_jobs.get(worker.current_job_id, {})
	if active.get("phase", "") not in ["carry", "carry_exit"] or not active.get("crew", []).has(worker): return false
	var cargo: Variant = worker._cargo_source
	if not is_instance_valid(cargo) or cargo.is_queued_for_deletion() or cargo != active.get("job", {}).get("part"): return false
	var route: Dictionary = coordinator._routes.get(worker.get_instance_id(), {})
	return not route.is_empty() and int(route.get("local_machine", 0)) != 0 \
		and route.get("points", []).is_empty() and float(route.get("until", 0.0)) > coordinator._clock

func _active_work_feedback(entry: Dictionary, with_crew: bool = true) -> String:
	var crew: Array = entry.get("crew", [])
	if crew.is_empty() or not is_instance_valid(crew[0]): return ""
	var lead: Node = crew[0]
	var reporting: Node = lead
	for member: Variant in crew:
		if is_instance_valid(member) and not member.is_queued_for_deletion() and (not member.tool_pose_blocked.is_empty() or (member.needs.is_empty() and _loaded_route_wait(member))):
			reporting = member
			break
	var job: Dictionary = entry.get("job", {})
	var message := _worker_work_text(reporting)
	# The actual dismantle lease still owns its placing finish. Do not infer
	# a removed job from an idle worker's old caption or action name.
	var finishing_removal: bool = job.get("kind", "") == "dismantle" and entry.get("phase", "") == "placing" and message.begins_with("Securing ")
	if finishing_removal: message = "Finishing removal of " + message.trim_prefix("Securing ")
	if reporting != lead: message = _work_crew_label([reporting]) + ": " + message
	var target: Variant = job.get("target")
	if is_instance_valid(target) and not target.is_queued_for_deletion() and target.get("definition") is Dictionary and not message.contains(String(target.definition.title)):
		message = "%s: %s" % [target.definition.title, message]
	return (_work_crew_label(crew) + " · " if with_crew else "") + message + (" · %d%%" % roundi(lead.progress * 100) if lead.progress > 0 and not finishing_removal else "")

func _carry_failure_text(reason: String) -> String:
	# Describe only the explicit recorded failure. Force refusal is not an obstacle.
	if reason.begins_with("force budget at "): return "This jump needs more force than the Wako can safely apply."
	if reason.begins_with("head obstruction at ") or reason.begins_with("torso obstruction at ") or reason.begins_with("stock obstruction at "):
		return "The carrying jump has an obstruction; clear space around the part."
	if reason.begins_with("tool obstruction at ") or reason.begins_with("original back holder obstruction at "):
		return "The tool or backpack passage is obstructed; give the Wako room."
	for prefix: String in ["original stock intersects head/body before contact at ", "original stock intersects leg before contact at ", "stock crosses carrying head at ", "stock crosses carrying leg at "]:
		if reason.begins_with(prefix): return "The part overlaps the carrying Wako during this jump."
	for prefix: String in ["original stock intersects retained tool before contact at ", "original stock intersects permanent back holder before head contact at ", "shared stock crosses permanent back holder at ", "shared stock crosses retained tool at "]:
		if reason.begins_with(prefix): return "The part overlaps the Wako's tool or backpack during this jump."
	if reason.begins_with("leg ") and reason.contains(" obstruction at "):
		return "The Wako's leg passage is obstructed; give it room for the jump."
	for prefix: String in ["cooperative heads/body cross at ", "shared stock crosses partner ", "permanent back holder crosses partner ", "cooperative back holders cross at ", "retained tool crosses partner ", "cooperative retained tools cross at ", "partner leg crosses ", "stock crosses partner leg at ", "tool crosses partner leg at ", "cooperative legs cross at "]:
		if reason.begins_with(prefix): return "The helpers, carried part or tools overlap during this shared jump."
	for prefix: String in ["tucked leg crosses original ", "tucked lower leg crosses own head at "]:
		if reason.begins_with(prefix): return "The Wako can't complete this jump without hitting its own body or equipment."
	return "No safe carrying jump is available yet."

func _work_reason_text(reason: String) -> String:
	var return_prefix := "No clear original-stock return arc; source remains at its actual head-contact pose: "
	if reason.begins_with(return_prefix):
		return "Can't carry this part back. " + _carry_failure_text(reason.trim_prefix(return_prefix)) + " The part remains recoverable."
	var launch_prefix := "No clear whole-body/head-first arc; "
	if reason.begins_with(launch_prefix): return "Can't safely jump to this part. " + _carry_failure_text(reason.trim_prefix(launch_prefix))
	if reason in ["Depot tool lacks clear supported foot access; clear its handle and opposite footing", "Tool footing did not settle; clear the rack or provide supported access"]:
		return "Can't stand safely to fit the work tool. Keep its handle, nearby floor and tool passage clear. Pause work before moving loose parts with the Grabber, then Resume work."
	if reason == "Tool passage did not clear; give the fitting crew supported room":
		return "Couldn't clear the tool passage. Give the fitting crew room to stand. Pause work before moving nearby loose parts, then Resume work."
	if reason == "No clear foot/tool posture; provide a work platform or clear access":
		return "Can't use the work tool safely here. Clear the work face or provide a supported platform."
	if reason.contains(" Wako needed for ") or reason == "Two Wako needed for this load":
		return reason + " Open Crew to see each helper's current work."
	if reason == "Original tool did not reach safe back custody before the bounded head launch":
		return "The work tool isn't safely stowed yet. Give the Wako room to put it away before picking up the part."
	if reason.begins_with("Original work tool released ("):
		return reason + " Pause work before moving it with the Grabber; release it on clear level ground, then Resume work."
	return reason

func _build_safety_status(selected: Node3D) -> String:
	if not is_instance_valid(selected): return ""
	# Show the current native hazard ahead of a stock shortage. A dropped
	# original piece remains recoverable once the crew can safely return.
	for part: Node3D in selected.parts.values():
		if not part.installed and yard.unsafe_at(part.global_position):
			return "Enemy nearby; clear the work area. Crew resumes when safe."
	var sheltered := 0
	var recovering := 0
	var crew_count := 0
	for worker: Node3D in yard.workers:
		if not is_instance_valid(worker): continue
		crew_count += 1
		if yard.unsafe_at(worker.global_position): sheltered += 1
		elif worker.fear_time > 0.0: recovering += 1
	if crew_count > 0 and sheltered + recovering == crew_count:
		return "Enemy nearby; clear the work area. Crew resumes when safe." if sheltered > 0 \
			else "Wako recovering after danger; work resumes when safe."
	return ""

func _another_ui_open() -> bool:
	if InputHub.context() in [&"menu", &"map", &"almanac", &"feedback", &"cutscene"]:
		return true
	for other: Node in get_tree().get_nodes_in_group(&"fullscreen_ui"):
		if other != self and other.has_method(&"is_open") and other.is_open():
			return true
	return false

func _build_prompt() -> String:
	return "[%s] Quick menu: Build contraption" % InputGlyphs.text(Keys.label_for(&"quick_menu")) if Keys.pad_mode() else "[%s] Build contraption" % Keys.label_for(&"contraption_bench")

func _workshop_prompt() -> String:
	var player := Core.player()
	if not is_instance_valid(player): return "BUILD A CONTRAPTION"
	var to_workshop: Vector3 = yard.global_position - player.global_position
	var horizontal := Vector2(to_workshop.x, to_workshop.z)
	# Match the existing map: north is -Z, clockwise toward +X.
	var bearing := posmod(roundi(atan2(horizontal.x, -horizontal.y) / (PI / 4.0)), 8)
	var compass: Array[String] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var action := "Build · Quick menu: Track workshop" if Keys.pad_mode() else "Build · [%s] Track workshop" % Keys.label_for(&"contraption_bench")
	return "%s\nWorkshop: %d m %s" % [action, roundi(horizontal.length()), compass[bearing]]

func _held_field_stock() -> Node3D:
	# A real held camp part also makes _near_yard true. Keep home guidance
	# visible during that physical return without changing Build or custody.
	if yard.worksite_active(): return null
	var manager := _tool_manager()
	var tool: Node = manager.current_tool if is_instance_valid(manager) else null
	if not is_instance_valid(tool) or tool.tool_id != &"rb_grabber" or not tool.grabber.is_holding(): return null
	var part: Node3D = tool.grabber.grabbed_body
	if not is_instance_valid(part) or part.is_queued_for_deletion() or not yard.loose_parts.has(part) \
		or (part.installed and is_instance_valid(part.assembly)) or part.get_meta(&"stored",false) or part.global_position.distance_to(yard.global_position) <= 65.0:
		return null
	return part

func _track_workshop() -> void:
	var map := get_node_or_null(^"/root/WorldMap")
	if not is_instance_valid(map) or not map.is_active_world():
		yard.last_message = "Follow the workshop distance and compass direction; Build opens when you are nearby."
		return
	var landmark: Dictionary = map.get_landmark(&"contraption_yard")
	if landmark.is_empty(): return
	# Point to this real service, including its runtime terrain height. Marking
	# its location does not reveal unexplored land or move any native body.
	landmark.pos = yard.global_position
	map.open_to_landmark(&"contraption_yard")

func _set_tool_holster(on: bool) -> void:
	if gun_interface and gun_interface.controlling(): on = true
	var player := Core.player()
	if not player:
		return
	var manager := player.find_child("HandToolManager", true, false)
	if manager and manager.has_method(&"holster") and on != _holstered:
		manager.holster(on)
		_holstered = on

func _start_placement(direct: bool) -> void:
	if catalogue.disabled:
		yard.last_message = "Clear or shorten Find a part before previewing a component."
		return
	var kind: String = catalogue.get_item_metadata(catalogue.selected)
	var own_connector: String = connector_choice.get_item_metadata(connector_choice.selected)
	placement.begin(kind, symmetry.selected, direct, _shape_parameters(kind), own_connector, connector_angle.value)
	toggle(false)

func _plan_mind_upgrade() -> void:
	var fitting := MindMount.choose(yard, yard.selected_assembly)
	if fitting.has("reason"):
		yard.last_message = fitting.reason
		return
	yard.plan_blueprint(fitting.plan, true)

func _populate_part_catalogue(query: String) -> void:
	# Only the player's catalogue is filtered. Stock, plans and socket validity
	# retain their normal native rules, including plans waiting for material.
	# Keep the player's chosen kind while intermediate query prefixes temporarily
	# show another match. Accepting a result or clearing a valid query chooses it.
	if query.strip_edges().is_empty() and not catalogue.disabled and catalogue.selected >= 0:
		_part_filter_selection = str(catalogue.get_item_metadata(catalogue.selected))
	catalogue.clear()
	var words := query.strip_edges().to_lower().split(" ", false)
	var definitions: Dictionary = Catalogue.all()
	var total := 0
	var selected_index := -1
	for kind: String in definitions:
		if kind == "remote_core": continue
		total += 1
		var definition: Dictionary = definitions[kind]
		var searchable := (str(definition.title) + " " + str(definition.category) + " " + kind.replace("_", " ")).to_lower()
		var matches := true
		for word: String in words:
			if not searchable.contains(word):
				matches = false
				break
		if not matches: continue
		catalogue.add_item(str(definition.title))
		var at := catalogue.item_count - 1
		catalogue.set_item_metadata(at, kind)
		var description := "%s · %.0f kg" % [str(definition.category).capitalize(), float(definition.mass)]
		if float(definition.power) > 0: description += " · %.0f W rated" % float(definition.power)
		if float(definition.capacity) > 0: description += " · %.0f Wh capacity" % float(definition.capacity)
		if definition.has("torque"): description += " · %.0f Nm" % float(definition.torque)
		catalogue.set_item_tooltip(at, description)
		if kind == _part_filter_selection: selected_index = at
	var found := catalogue.item_count
	catalogue.disabled = found == 0
	if found == 0:
		catalogue.add_item("No matching parts — clear or shorten the search")
		catalogue.set_item_metadata(0, "")
		catalogue.set_item_disabled(0, true)
	else:
		catalogue.select(maxi(selected_index, 0))
		if _part_filter_selection.is_empty():
			_part_filter_selection = str(catalogue.get_item_metadata(catalogue.selected))
	_part_matches.text = "%d / %d parts · Clear search for the full catalogue" % [found, total] if not words.is_empty() else "%d parts · Search by name or category" % total

func _filter_parts(query: String) -> void:
	_populate_part_catalogue(query)
	for button: Button in _part_actions: button.disabled = catalogue.disabled
	_select_catalogue_part(catalogue.selected)

func _select_catalogue_part(index: int) -> void:
	var kind := "" if catalogue.disabled or index < 0 else str(catalogue.get_item_metadata(index))
	beam_parameters.visible = kind == "beam"
	wheel_parameters.visible = kind == "wheel"
	wing_editor.visible = kind == "wing"
	plate_editor.visible = kind == "armor"
	flight_editor.visible = kind == "hinge"
	cockpit_parameters.visible = kind == "cockpit"
	bearing_parameters.visible = kind == "bearing" and Catalogue.BearingFreewheel.available()
	_update_connector_choices()
	_poll = 0.0

func _update_connector_choices() -> void:
	var previous := str(connector_choice.get_item_metadata(connector_choice.selected)) if connector_choice.selected >= 0 else ""
	connector_choice.clear()
	connector_choice.add_item("Auto")
	connector_choice.set_item_metadata(0, "")
	connector_choice.disabled = catalogue.disabled
	if catalogue.disabled: return
	var kind: String = catalogue.get_item_metadata(catalogue.selected)
	for socket: Dictionary in Catalogue.get_def(kind, _shape_parameters(kind)).connectors:
		connector_choice.add_item(str(socket.name).capitalize())
		connector_choice.set_item_metadata(connector_choice.item_count - 1, str(socket.name))
		if socket.name == previous: connector_choice.select(connector_choice.item_count - 1)

func _shape_parameters(kind: String) -> Dictionary:
	var values := {}
	if kind == "beam" and is_instance_valid(beam_length):
		values = {"length": beam_length.value, "profile": beam_profile.get_item_metadata(beam_profile.selected)}
	elif kind == "wheel" and is_instance_valid(wheel_profile): values = {"wheel_profile": wheel_profile.get_item_metadata(wheel_profile.selected)}
	elif kind == "wing" and is_instance_valid(wing_editor): values = wing_editor.parameters()
	elif kind == "armor" and is_instance_valid(plate_editor): values = plate_editor.parameters()
	elif kind == "hinge" and is_instance_valid(flight_editor): values = flight_editor.parameters()
	elif kind == "cockpit" and is_instance_valid(cockpit_mode): values = {"control_mode": "flight" if cockpit_mode.selected == 1 else "ground"}
	elif kind == "bearing" and is_instance_valid(bearing_direction): values = {Catalogue.BearingFreewheel.KEY:bearing_direction.get_item_metadata(bearing_direction.selected)}
	var finish := _chosen_finish()
	if finish != "original" and Catalogue.supports_finish(kind): values.finish = finish
	return values

func _chosen_finish() -> String:
	return str(finish_choice.get_item_metadata(finish_choice.selected)) if is_instance_valid(finish_choice) and finish_choice.selected >= 0 else "original"

func _paint_aimed() -> void:
	var part := _aimed_part()
	if not is_instance_valid(part):
		yard.last_message = "Aim at a component within reach, then choose its shell finish."
		return
	if not part.set_finish(_chosen_finish()):
		yard.last_message = "Defeat this machine before refinishing its parts." if part.salvage_locked else "This component uses its original exposed material."
		return
	_paint_message(1)

func _paint_selected() -> void:
	if not is_instance_valid(yard.selected_assembly):
		yard.last_message = "Select a machine at the bench first."
		return
	var changed := 0
	for part: Node3D in yard.selected_assembly.parts.values():
		if part.set_finish(_chosen_finish()): changed += 1
	_paint_message(changed)

func _paint_message(count: int) -> void:
	var label := str(finish_choice.get_item_text(finish_choice.selected))
	yard.last_message = "%d component shells finished in %s." % [count, label.to_lower()]

func _release_stock() -> void:
	if catalogue.disabled:
		yard.last_message = "Choose a matching part before releasing stored stock."
		return
	var kind: String = catalogue.get_item_metadata(catalogue.selected)
	var p: Node3D = yard.available_part(kind, _shape_parameters(kind))
	if not p:
		yard.last_message = "No unreserved %s in storage." % kind
		return
	if not yard.release_stock_for_grabber(p):
		yard.last_message="The original stock is reserved; wait for the active Wako job."
		return
	var return_prompt := "Quick menu: Salvage / place component" if Keys.pad_mode() else Keys.label_for(&"contraption_use")
	yard.last_message = "Stock released at its actual storage place. Use the grabber, or aim and use %s to return it to Wako collection." % return_prompt

func _return_stock_to_collection(part: Node3D) -> bool:
	if not is_instance_valid(part) or not part.get_meta(&"player_carry",false): return false
	if part.installed and is_instance_valid(part.assembly): return false
	# The same public action is also dispatched by the gamepad Quick menu.
	# Dropping must end the actual native Grabber joint before work can own it.
	var player := Core.player()
	var manager := player.find_child("HandToolManager", true, false) if player else null
	var tool: Node = manager.current_tool if is_instance_valid(manager) else null
	if is_instance_valid(tool) and tool.tool_id == &"rb_grabber" and tool.grabber.is_holding() and tool.grabber.grabbed_body == part:
		yard.last_message = "Drop this part first so Wako can collect it safely."
		return true
	part.set_meta(&"player_carry",false)
	yard.last_message="Released to automatic Wako collection."
	return true

func _input(event: InputEvent) -> void:
	# Handle Back before the global weather panel consumes Escape.
	if event.is_action_pressed(&"ui_cancel") and not event.is_echo() and not _another_ui_open():
		if is_open():
			if _dismantle_review.visible:
				_close_dismantle_review()
				yard.last_message = "Dismantling review closed. Your build is unchanged."
				_poll = 0.0
			else: toggle(false)
		elif is_instance_valid(placement) and placement.enabled:
			placement.end()
			_set_tool_holster(false)
			yard.last_message = "Part preview closed. Confirmed placements stay in your build. Open Build to view progress or choose another part."
			_poll = 0.0
		else:
			return
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(yard):
		return
	if event.is_echo() or _another_ui_open():
		return
	var near := _near_yard()
	if event.is_action_pressed(&"contraption_bench"):
		if near:
			if placement.enabled:
				placement.end()
			toggle(not is_open())
		else:
			_track_workshop()
		get_viewport().set_input_as_handled()
	elif not near:
		return
	elif event.is_action_pressed(&"contraption_rotate") and placement.enabled:
		placement.rotate_step()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"contraption_use") and not is_open():
		if placement.enabled:
			placement.confirm()
		else:
			_salvage_aimed()
		get_viewport().set_input_as_handled()

func _near_yard() -> bool:
	var p := Core.player()
	if p == null:
		return false
	if p.global_position.distance_to(yard.global_position) < 65.0:
		return true
	for a: Node in yard.assemblies:
		if is_instance_valid(a) and a.root_part() and p.global_position.distance_to(a.root_part().global_position) < 25.0:
			return true
	for enemy: Node3D in yard.enemies:
		if is_instance_valid(enemy) and enemy.assembly and enemy.assembly.root_part() and p.global_position.distance_to(enemy.assembly.root_part().global_position) < 25.0:
			return true
	for site: Node3D in get_tree().get_nodes_in_group(&"wild_machine_sites"):
		if is_instance_valid(site.wreck) and site.wreck.root_part() and p.global_position.distance_to(site.wreck.root_part().global_position) < 15.0:
			return true
	for part: Node3D in yard.loose_parts:
		if is_instance_valid(part) and p.global_position.distance_to(part.global_position) < 8.0:
			return true
	return false

func _aimed_part() -> Node3D:
	var camera := Core.camera()
	if not camera:
		return null
	var ray: Dictionary = camera.aim_ray() if camera.has_method(&"aim_ray") else {"origin": camera.global_position, "dir": -camera.global_basis.z}
	var exclude: Array[RID] = []
	if Core.player():
		exclude.append(Core.player().get_rid())
	var q := PhysicsRayQueryParameters3D.create(ray.origin, ray.origin + ray.dir * 7.0, 0xFFFFFFFF, exclude)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.collider as Node3D if hit and (hit.collider.has_meta(&"contraption_part") or hit.collider.get_meta(&"loose_shared_gun",false)) else null

func _salvage_aimed() -> void:
	if gun_interface and gun_interface.controlling(): gun_interface.leave_control(); return
	var p := _aimed_part()
	if not p:
		yard.last_message = "Aim at a machine component within wrench reach."
		return
	if gun_interface and (gun_interface.try_loose_use(p) or gun_interface.try_use(p)): return
	if p.kind==Catalogue.SignalHorn.KIND and p.installed and is_instance_valid(p.horn):
		var result: Dictionary = p.horn.request()
		yard.last_message = result.get("reason","Signal requested.")
		return
	if p.kind==QuickRelease.KIND and p.installed and is_instance_valid(p.assembly):
		var release: Dictionary=QuickRelease.release(yard,p)
		if release.has("reason"): yard.last_message=release.reason
		return
	if p.kind=="breakaway_fuse" and p.installed and is_instance_valid(p.assembly):
		var monitor:Node=p.get_node_or_null("BreakawayFuseMonitor")
		var result:Dictionary=monitor.arm(yard) if is_instance_valid(monitor) else {"reason":"The original cartridge observer is unavailable."}
		yard.last_message=result.get("reason","Original geometric fuse armed; overload retirement keeps its 4 kg spent material for finite replacement.")
		return
	if _return_stock_to_collection(p): return
	if not p.installed or p.assembly == null:
		yard.last_message = p.inspect_status() + " Use the grabber to carry / drag this part."
		return
	if not yard.assemblies.has(p.assembly) and not p.assembly.get_meta(&"disabled_donor", false):
		yard.last_message = p.inspect_status()
		return
	if not p.assembly.get_meta(&"disabled_donor", false) and not p.get_meta(&"salvageable", false):
		yard.select_assembly(p.assembly.get_instance_id())
		yard.last_message = p.inspect_status() + " Machine selected at the bench for upgrades, inspection and dismantling."
		return
	var player := Core.player()
	var manager := player.find_child("HandToolManager", true, false) if player else null
	if manager and (not manager.current_tool or manager.current_tool.tool_id not in [&"rb_grabber", &"pickaxe"]):
		yard.last_message = "Use the grabber to release fasteners, or strike with your pickaxe three times."
		return
	yard.salvage_part(p)

func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0 or panel == null:
		return
	_poll = .2
	_resize_panel()
	work_pause_button.text = "Resume work" if yard.work_paused else "Pause work"
	work_pause_button.tooltip_text = "Resume all Wako construction, repairs and salvage from existing plans and stock." if yard.work_paused \
		else "Pause all Wako construction, repairs and salvage. Plans stay; carried stock is recovered safely."
	_stock_recovery.text = _stock_recovery_status() if is_open() else ""
	_stock_recovery.visible = not _stock_recovery.text.is_empty()
	if is_open(): _update_build_workflow()
	else: _selected_feedback = _selected_progress_status(yard.selected_assembly)
	var placement_controls := "open Quick menu to rotate or confirm" if Keys.pad_mode() else "%s rotates; %s confirms" % [Keys.label_for(&"contraption_rotate"), Keys.label_for(&"contraption_use")]
	_instructions.text = "After Preview, aim at a cyan connector: %s.\nBack / Escape cancels the preview. Wako carry stored parts and install them; heavy parts need two helpers.\nUse the grabber for Install nearby part." % placement_controls
	var near := _near_yard()
	var entry_available := is_instance_valid(Core.player()) and not is_open() and not _another_ui_open()
	hud.visible = entry_available and near
	_build_entry.visible = entry_available and not placement.enabled
	_build_entry.disabled = false
	_build_entry.text = _build_prompt() + "\nStart a rover · customize parts" if near else _workshop_prompt()
	var held_return := _held_field_stock()
	if is_instance_valid(held_return):
		_build_entry.text = _build_prompt() + "\n" + _workshop_prompt().get_slice("\n",1)
	_build_entry.tooltip_text = "Start a rover or customize a machine with your real stock and Wako crew." if Keys.pad_mode() \
		else "Press %s to open Build, or %s to free the cursor and click." % [Keys.label_for(&"contraption_bench"), Keys.label_for(&"release_mouse")]
	if not near:
		_build_entry.tooltip_text = "Track the real workshop on your map. Follow its distance and compass direction to reach the stock and Wako crew."
	_build_entry.mouse_filter = Control.MOUSE_FILTER_IGNORE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Control.MOUSE_FILTER_STOP
	if not near and is_open():
		toggle(false)
	if not near and placement.enabled:
		placement.end()
		_set_tool_holster(false)
	var lines: Array[String] = []
	var idle_count := 0
	var paused_count := 0
	var crews: Dictionary = {}
	var selected_crew_index := -1
	if yard.work_paused:
		lines.append("Work paused · %s, then Resume work" % _build_prompt())
	for w: Variant in yard.workers:
		if is_instance_valid(w):
			# Pausing stops discovery, so old connector/hit captions cannot be
			# refreshed by the scheduler. Report the current saved pause instead;
			# real native recovery and danger still keep their own crew rows.
			if yard.work_paused and w.current_job_id == "" and w.is_available() and w.fear_time <= 0.0 and not yard.unsafe_at(w.global_position):
				paused_count += 1
			elif w.current_job_id == "" and w.needs == "" and w.is_available() and w.fear_time <= 0.0 and not yard.unsafe_at(w.global_position):
				idle_count += 1
			else:
				var description := "%s%s" % [_worker_work_text(w), " · %d%%" % roundi(w.progress * 100) if w.progress > 0 else ""]
				if not w.is_available(): description = "Regaining footing"
				var active: Dictionary = yard.coordinator.active_jobs.get(w.current_job_id, {}) if is_instance_valid(yard.coordinator) else {}
				var shared: bool = not active.is_empty() and active.get("crew", []).has(w)
				if shared: description = _active_work_feedback(active, false)
				# A heavy component has one cooperative job. Show its crew size
				# instead of repeating identical progress for every supporting Wako.
				# A member's real tool refusal stays in that shared row; unrelated
				# free-worker needs still keep separate rows.
				var key := "%s\n%s\n%s" % [w.current_job_id, "" if shared else w.needs, description]
				if crews.has(key):
					crews[key].members.append(w)
				else:
					crews[key] = {"members": [w], "description": description, "job": w.current_job_id}
	for crew: Dictionary in crews.values():
		if not _selected_work_job_id.is_empty() and crew.job == _selected_work_job_id: selected_crew_index = lines.size()
		lines.append("%s · %s" % [_work_crew_label(crew.members), crew.description])
	if idle_count > 0:
		lines.append("%d Wako watching for salvage and maintenance" % idle_count)
	if paused_count > 0:
		lines.append("%d Wako waiting for work to resume" % paused_count)
	crew_status.text = "\n".join(lines)
	var travel:Dictionary=yard.crew_travel_context()
	crew_travel_status.text="Use the Blueprint Projector's Original crew page near a stopped connected container to choose a walking destination."
	crew_travel_resume.disabled=true
	crew_travel_cancel.disabled=true
	if not travel.is_empty():
		crew_travel_status.text="Original crew route: %s · %d / %d arrived"%[travel.phase,travel.arrived,travel.total]
		if not String(travel.reason).is_empty(): crew_travel_status.text+="\n"+String(travel.reason)
		crew_travel_resume.disabled=travel.phase!="held"
		crew_travel_cancel.disabled=travel.phase=="held"
	var learned_hash: int = hash(yard.learned_blueprints)
	if learned_hash != _learned_hash:
		_learned_hash = learned_hash
		learned.clear()
		if yard.learned_blueprints.is_empty():
			learned.add_item("Defeat a remote core to study its body")
		else:
			for blueprint: Dictionary in yard.learned_blueprints:
				learned.add_item(String(blueprint.get("name", "Studied body")))
		learned.disabled = yard.learned_blueprints.is_empty()
		_study_button.disabled = learned.disabled
	var message: String = yard.last_message if _selected_feedback.is_empty() else _selected_feedback + "\nWorkshop: " + yard.last_message
	# Start already shows the selected plan's full live reason in its scroll area.
	# Keep the latest action/refusal visible here without repeating that progress.
	status.text = yard.last_message if _tabs.current_tab == 0 and not _selected_feedback.is_empty() \
		else yard.with_construction_needs(message)
	status.tooltip_text = status.text
	var detail := ""
	var guide:Node=_selected_supply_guide()
	supply_guide_status.text=guide.inspect_status() if is_instance_valid(guide) else ""
	bearing_lock.disabled = true
	brake_slider.editable = false
	if is_instance_valid(yard.selected_assembly):
		var a: Node = yard.selected_assembly
		mechanism_slider.set_value_no_signal(a.mechanism_control)
		brake_slider.set_value_no_signal(a.brake_control)
		if not cruise_speed.get_line_edit().has_focus():
			cruise_speed.set_value_no_signal(a.target_speed)
		detail = "\n" + a.inspect_status()
		if is_instance_valid(guide) and not guide.observe().is_empty(): detail+="\n"+guide.inspect_status()
		var bearings: Array = a.connections.filter(func(c: Node3D) -> bool: return c.kind == "bearing")
		bearing_lock.disabled = bearings.is_empty()
		brake_slider.editable = not bearings.is_empty()
		bearing_lock.set_pressed_no_signal(bearings.any(func(c: Node3D) -> bool: return c.locked))
	var aimed := _aimed_part() if near and not is_open() else null
	if aimed:
		detail += "\n" + (aimed.inspect_status() if aimed.has_method("inspect_status") else "Loose shared gun: use to recover the same item")
		if gun_interface and gun_interface.is_installed_socket(aimed) and not gun_interface.controlling():
			detail = "\n" + gun_interface.socket_feedback(aimed) + detail
	var heading := _build_prompt() + (" · Work paused — open Build and Resume work" if yard.work_paused else "")
	if placement.enabled: heading = "PART PREVIEW · Back / Escape cancels" + (" · Work paused" if yard.work_paused else "")
	var feedback: String = placement.reason if placement.enabled else yard.last_message if _selected_feedback.is_empty() else _selected_feedback
	var selected_work_visible: bool = not placement.enabled and not _selected_feedback.is_empty()
	if is_instance_valid(held_return) and not placement.enabled:
		var grab_control := Keys.label_for(&"left_click")
		if InputGlyphs.is_token(grab_control): grab_control = InputGlyphs.text(grab_control)
		var work_control := "Quick menu" if Keys.pad_mode() else Keys.label_for(&"wako_work_here")
		feedback = "Carrying %s · %.0f kg\nHold %s to carry. Drop on clear workshop ground, then aim at your Wako and select Useful work (%s).\n%s" % [
			held_return.definition.title, held_return.mass, grab_control, work_control, feedback]
		if yard.work_paused: feedback += " Open Build and Resume work after dropping."
	var event: String = "\nWorkshop: " + yard.last_message if not placement.enabled and not _selected_feedback.is_empty() else ""
	if gun_interface and gun_interface.controlling():
		heading = "GUN CONTROL POINT"
		feedback = gun_interface.control_feedback()
		selected_work_visible = false
	var hud_lines: Array[String] = []
	for index in lines.size():
		# Crew keeps every row; HUD already presents this exact selected job.
		if selected_work_visible and index == selected_crew_index: continue
		hud_lines.append(lines[index])
	hud.text = yard.with_construction_needs("%s\n%s%s\n%s%s" % [heading,
		feedback, detail, "\n".join(hud_lines), event]).left(950)

func _selected_supply_guide() -> Node:
	if not is_instance_valid(yard.selected_assembly): return null
	for machine:Node3D in get_tree().get_nodes_in_group(&"machines"):
		if machine.get("assembly")==yard.selected_assembly and is_instance_valid(machine.get("supply_guide")):
			return machine.supply_guide
	return null

func _set_supply_guide(destination:String) -> void:
	var guide:=_selected_supply_guide()
	if not is_instance_valid(guide):
		yard.last_message="Select a wheeled machine with an installed ground helm."
		return
	var result:Dictionary=guide.select_destination(destination)
	yard.last_message=result.reason

func get_shortcut_sections() -> Array[Dictionary]:
	if gun_interface and gun_interface.controlling(): return [{"title":"Gun control point","order":5,"hints":gun_interface.hints()}]
	if not _near_yard():
		return [{"title": "Construction", "order": 5, "hints": [{"action": &"contraption_bench", "label": "Track workshop"}]}] if is_instance_valid(Core.player()) and not _another_ui_open() else []
	if is_open():
		return [{"title": "Construction", "order": 5, "hints": [{"action": &"contraption_bench", "label": "Close Build"}, {"action": &"ui_cancel", "label": "Close Build"}]}]
	var hints: Array = [{"action": &"contraption_bench", "label": "Build contraption"},
		{"action": &"contraption_use", "label": "Confirm placement" if placement and placement.enabled else "Salvage / inspect part"}]
	if not (placement and placement.enabled):
		var aimed := _aimed_part()
		if is_instance_valid(aimed) and aimed.get_meta(&"loose_shared_gun",false): hints[1].label="Take the same loose gun"
		elif gun_interface and gun_interface.is_installed_socket(aimed): hints[1].label=gun_interface.socket_use_label(aimed)
		elif is_instance_valid(aimed) and aimed.kind==QuickRelease.KIND and aimed.installed:
			hints[1].label="Release coupler payload"
		elif is_instance_valid(aimed) and aimed.kind==Catalogue.SignalHorn.KIND and aimed.installed:
			hints[1].label="Sound one powered signal"
	if placement and placement.enabled:
		hints.append({"action": &"contraption_rotate", "label": "Rotate around connector"})
		hints.append({"action": &"ui_cancel", "label": "Cancel part preview"})
	return [{"title": "Construction", "order": 5, "hints": hints}]
