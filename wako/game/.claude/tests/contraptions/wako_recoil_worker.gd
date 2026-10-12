extends "res://LogicObjects/Wako/wako_helper.gd"
var maximum_native_impact := 0.0

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	for contact in state.get_contact_count():
		maximum_native_impact = maxf(maximum_native_impact,state.get_contact_impulse(contact).length()/maxf(mass,1.0))
	super._integrate_forces(state)
