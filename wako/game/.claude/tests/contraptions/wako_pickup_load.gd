extends "res://.claude/tests/contraptions/integration.gd"
## Three independent real loose light loads begin from equal nearby stances.
## Report actual per-native-tick kickoff query cost; this is not a scaling claim.
const Part=preload("res://Components/Contraptions/contraption_part.gd")
var seen:Dictionary={}
var maximum_same_tick_launches:=0
var maximum_query_usec:=0
var airborne_helpers:=0
var launched_ids:Array[String]=[]
func _physics_process(delta:float)->void:
	super._physics_process(delta)
	if not is_instance_valid(yard):return
	var count:=0
	var cost:=0
	var active:=0
	for worker:Node in yard.workers:
		if worker.pickup.state=="flight":active+=1
		if worker.pickup.state!="flight" or not is_instance_valid(worker.pickup.part):continue
		var id:String=worker.pickup.part.part_id
		if seen.has(id):continue
		seen[id]=true
		launched_ids.append(id)
		count+=1
		cost+=worker.pickup.launch_validation_usec
	maximum_same_tick_launches=maxi(maximum_same_tick_launches,count)
	maximum_query_usec=maxi(maximum_query_usec,cost)
	airborne_helpers=maxi(airborne_helpers,active)
func _run()->void:
	var floor:=StaticBody3D.new()
	floor.position.y=-.5
	add_child(floor)
	var collider:=CollisionShape3D.new()
	var box:=BoxShape3D.new()
	box.size=Vector3(160,1,160)
	collider.shape=box
	floor.add_child(collider)
	yard=Yard.new()
	add_child(yard)
	yard.work_paused=true
	await _advance(.3)
	_park_fauna()
	for worker:Node in yard.workers:worker.paused=true
	var crew:Array=[]
	for index in 3:crew.append(yard.spawn_worker(Vector3(-2+index*3,.85,8)))
	await _advance(.3)
	for index in crew.size():
		var worker:Node3D=crew[index]
		var source:=Part.new()
		source.setup("light","concurrent_light_%d"%index,true)
		yard.add_child(source)
		source.global_position=worker.global_position+Vector3(0,-worker.ride_height+.12,-.42)
		yard.add_loose_part(source)
	await _advance(.3)
	yard.work_paused=false
	var three:=await _wait_until(func()->bool:return launched_ids.size()==3,12.0)
	_check(three and airborne_helpers==3,"three real helpers simultaneously toss three independently reserved physical light loads")
	_check(maximum_same_tick_launches==3,"all three native kickoffs share one real physics tick")
	print("CONTRAPTION_PICKUP_LOAD kickoff_queries_usec=",maximum_query_usec," same_tick_launches=",maximum_same_tick_launches," simultaneous_flights=",airborne_helpers)
	print("CONTRAPTION_PICKUP_LOAD %s ticks=%d"%["PASS" if failures==0 else "FAIL (%d)"%failures,_tick])
	Shortcuts.graceful_quit(0 if failures==0 else 1)
