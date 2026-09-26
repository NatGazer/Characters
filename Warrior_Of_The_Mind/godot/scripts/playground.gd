extends Node3D
## Playground for the playable Warrior: arena, a ladder tower, steps, training dummies.

func _ready() -> void:
	EnvBuilder.build(self)
	var player := CharacterBody3D.new()
	player.set_script(load("res://scripts/player.gd"))
	player.position = Vector3(0, 0.1, 0)
	add_child(player)
	_tower(Vector3(0, 0, 6.5))
	for i in 5:
		_box(Vector3(-4.0 + i * 0.0, 0.2 + i * 0.4, -3.0 - i * 0.9), Vector3(2.0, 0.4 + i * 0.8, 0.9))
	for p in [Vector3(3.5, 0, -2.0), Vector3(-3.0, 0, 2.5), Vector3(4.5, 0, 3.0)]:
		_dummy(p)
	var ui := CanvasLayer.new(); add_child(ui)
	var help := Label.new()
	help.text = "WASD move  Shift sprint  Ctrl walk  Space jump  LMB sword  RMB bolt  F blast  G gesture\nQ/E dodge  C roll  X stance  H hit  K ragdoll  Enter get up  W at the ladder = climb  Tab showcase"
	help.position = Vector2(30, 20)
	help.add_theme_color_override("font_color", Color(1.0, 0.86, 0.6))
	help.add_theme_color_override("font_outline_color", Color.BLACK)
	help.add_theme_constant_override("outline_size", 5)
	ui.add_child(help)

func _box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new(); b.position = pos
	var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = size; cs.shape = bs; b.add_child(cs)
	var mi := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = size; mi.mesh = bm
	mi.material_override = EnvBuilder.stone_material(); b.add_child(mi)
	add_child(b)
	return b

func _tower(pos: Vector3) -> void:
	var h := 3.2
	_box(pos + Vector3(0, h * 0.5, 0.6), Vector3(3.0, h, 1.2))           # wall block with a flat top
	# ladder on the front face (-Z side of the block)
	var ladder := Area3D.new()
	ladder.position = pos + Vector3(0, h * 0.5, -0.05)
	ladder.rotation.y = PI            # its -Z (normal) points back toward the arena centre
	ladder.set_meta("height", h)
	var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = Vector3(1.0, h, 1.4); cs.shape = bs
	ladder.add_child(cs)
	add_child(ladder)
	var wood := StandardMaterial3D.new(); wood.albedo_color = Color(0.25, 0.16, 0.09); wood.roughness = 0.8
	for sx in [-0.28, 0.28]:
		var rail := MeshInstance3D.new(); var rm := BoxMesh.new(); rm.size = Vector3(0.06, h + 0.3, 0.06)
		rail.mesh = rm; rail.material_override = wood; rail.position = pos + Vector3(sx, h * 0.5, -0.03); add_child(rail)
	var y := 0.3
	while y < h:
		var rung := MeshInstance3D.new(); var cm := CylinderMesh.new(); cm.top_radius = 0.02; cm.bottom_radius = 0.02; cm.height = 0.56
		rung.mesh = cm; rung.material_override = wood; rung.rotation.z = PI / 2; rung.position = pos + Vector3(0, y, -0.03)
		add_child(rung); y += 0.3
	ladder.body_entered.connect(func(b): if b.has_method("_enter_ladder"): b.ladder = ladder)
	ladder.body_exited.connect(func(b): if b.has_method("_enter_ladder") and b.ladder == ladder: b.ladder = null)

func _dummy(pos: Vector3) -> void:
	var d := StaticBody3D.new(); d.position = pos; d.add_to_group("dummies")
	d.set_script(load("res://scripts/dummy.gd"))
	add_child(d)
