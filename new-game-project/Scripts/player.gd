extends CharacterBody3D

# Node refs
@onready var head = $Head
@onready var standing_shape = $Standing_Shape
@onready var crouching_shape = $Crouching_Shape
@onready var ray_cast_3d = $RayCast3D


# Movement variables and constants
var Current_Speed = 5.0
const Walk_Speed = 5.0
const Sprint_Speed = 16.0
const Crouch_Speed = 3.0
const Jump_Velocity = 4.5

# Other variables
const Mouse_Sens = 0.4

var Lerp_Speed = 10.0 # This is for smoothing accelerations

var direction = Vector3.ZERO

var Crouch_Depth = -0.5

func _ready():
	# Capturing the mouse movement
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	
func _input(event):
	# Rotating the camera with mouse movement
	if event is InputEventMouseMotion:
		rotate_y(deg_to_rad(-event.relative.x * Mouse_Sens))
		head.rotate_x(deg_to_rad(-event.relative.y * Mouse_Sens))
		head.rotation.x = clamp(head.rotation.x,deg_to_rad(-89),deg_to_rad(89))

func _physics_process(delta):
	# Handling crouch functions
	if Input.is_action_pressed("Crouch_Button"):
		Current_Speed = Crouch_Speed
		head.position.y = lerp(head.position.y,1.8 + Crouch_Depth,delta * Lerp_Speed)
		standing_shape.disabled = true
		crouching_shape.disabled = false
		
	# Preventing player from standing up when under something
	elif !ray_cast_3d.is_colliding():
		standing_shape.disabled = false
		crouching_shape.disabled = true
		head.position.y = lerp(head.position.y,1.8,delta * Lerp_Speed)
		# Allowing sprint if not crouching
		if Input.is_action_pressed("Sprint_Button"):
			Current_Speed = Sprint_Speed
		else:
			Current_Speed = Walk_Speed
		
	# Allowes player to use the mouse
	if Input.is_action_just_pressed("freemouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = Jump_Velocity

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir = Input.get_vector("Left_Button", "Right_Button", "Forward_Button", "Backward_Button")
	direction = lerp(direction,(transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized(), delta*Lerp_Speed)
	
	if direction:
		velocity.x = direction.x * Current_Speed
		velocity.z = direction.z * Current_Speed
	else:
		velocity.x = move_toward(velocity.x, 0, Current_Speed)
		velocity.z = move_toward(velocity.z, 0, Current_Speed)

	move_and_slide()
