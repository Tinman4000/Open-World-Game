extends Node3D
## Procedural, streaming terrain for Godot 4.x (GDScript).
##
## HOW IT WORKS (big picture)
## ---------------------------------------------------------------------------
## 1. The world is an infinite grid of square CHUNKS (default 64 m x 64 m).
## 2. The LAND SHAPE is a pure function of position, _base_sample(x, z), built
##    from several noise layers:
##        REGION noise   -> very large scale; decides "valley / hills / mountain"
##        HILL noise     -> medium scale; gentle rolling bumps
##        FOOTHILL noise -> rounded humps that ramp up before the mountains start
##        RIDGE noise    -> mountain scale; sharp ridgelines and peaks
## 3. RIVERS are then carved into that land. Each river is TRACED from a source
##    high up, stepping downhill (following the steepest slope). Where the
##    ground is nearly flat the path swings side to side, so rivers wind on
##    flat land and run straight down steep slopes. Each river keeps a "bed
##    height" that only ever goes DOWN along its path, so water can never flow
##    uphill. The path is cached, so every chunk sees the same river.
## 4. CANYONS are not separate features: wherever a river runs through
##    mountainous land, its channel is cut deeper and wider with steep, stepped
##    walls. Where the river leaves the mountains, the canyon fades back out.
## 5. Chunks near the player are generated on WORKER THREADS (no frame
##    hitches), turned into meshes on the main thread, and freed again when the
##    player moves away. Collision is only built for chunks close to the player.
##
## SETUP
## ---------------------------------------------------------------------------
## - Put this script on a Node3D (terrain.tscn already does) and keep that node
##   at the world origin (position 0,0,0, no rotation/scale).
## - Assign your player in the inspector (`player`), OR add the player to a
##   group called "player". If neither is found, the active camera is used.
## - Look for "★ TWEAK" comments: those are the values you'll most want to
##   change. All of them are also exposed in the Inspector.
## - If you change settings WHILE the game is running, call regenerate().

## Emitted once solid ground exists under the player (useful for UI/loading).
signal spawn_ground_ready

# =============================================================================
# ★ TWEAKABLE SETTINGS  (everything in this section shows up in the Inspector)
# =============================================================================

@export_group("Streaming")

## The node that terrain streams around (your CharacterBody3D "player").
@export var player: Node3D

## ★ TWEAK: How far (in chunks) terrain is loaded around the player.
## The biggest performance lever: cost grows with the SQUARE of this number.
## 7 chunks * 64 m = ~450 m draw distance with default chunk size.
@export_range(2.0, 20.0, 0.5) var view_distance_chunks: float = 7.0

## ★ TWEAK: Extra distance a chunk must be beyond view distance before it is
## unloaded. Prevents chunks flickering in/out when you stand on a boundary.
@export_range(0.0, 6.0, 0.5) var unload_buffer_chunks: float = 1.5

## ★ TWEAK: Only chunks this close get physics collision. Must be >= 1 so the
## chunk under the player always has ground. Raise it if fast vehicles /
## projectiles need to hit distant terrain.
@export_range(1.0, 6.0, 0.5) var collision_distance_chunks: float = 2.0

## Physics layer the terrain collision lives on (layer 1 by default).
@export_flags_3d_physics var collision_layer: int = 1

## How often (seconds) we re-scan which chunks should exist. Lower = more
## responsive, higher = slightly cheaper. 0.25 is a good default.
@export_range(0.05, 2.0, 0.05) var update_interval: float = 0.25

## ★ TWEAK: Max chunks being generated on background threads at once.
## Raise on CPUs with many cores for faster initial load.
@export_range(1, 16) var max_chunks_generating: int = 4

## ★ TWEAK: Max finished chunks converted to meshes per frame. Lower this if
## you see small stutters while running; higher = terrain appears faster.
@export_range(1, 8) var max_mesh_builds_per_frame: int = 2

## Max collision shapes built per frame (they're the costliest main-thread step).
@export_range(1, 4) var max_collision_builds_per_frame: int = 2


@export_group("Chunk Geometry")

## ★ TWEAK: Chunk width in metres. Bigger = fewer nodes, but each load/unload
## is a bigger (slower) job. 64 is a good balance.
@export_range(16.0, 256.0, 1.0) var chunk_size: float = 64.0

## ★ TWEAK: Quads per chunk side. Vertex spacing = chunk_size / chunk_resolution
## (default 64 / 32 = 2 m between vertices). Higher = smoother and more
## detailed, but triangle count grows with the square (32 -> 2,048 tris/chunk,
## 64 -> 8,192 tris/chunk).
@export_range(8, 128, 1) var chunk_resolution: int = 32


@export_group("World Layout")

## ★ TWEAK: Change this to get a completely different world.
@export var world_seed: int = 1337

## Sea-level-ish reference height. Hills oscillate around it; valleys dip below.
@export var base_height: float = 0.0

## ★ TWEAK: Size (metres) of the biggest features: roughly the distance from
## one mountain range to the next valley. Larger = broader, calmer biomes.
@export_range(300.0, 6000.0, 10.0) var region_size: float = 1600.0

## How strongly the region noise is stretched toward 0 or 1. Raw noise clusters
## near the middle, so without this you'd see mostly "hills". Higher = more
## frequent mountains and valleys, fewer hills.
@export_range(0.5, 4.0, 0.05) var region_contrast: float = 1.8

## ★ TWEAK: Region values (0..1) BELOW this become valleys.
## Raise it -> more of the world is valley.
@export_range(0.0, 1.0, 0.01) var valley_level: float = 0.38

## ★ TWEAK: Region values (0..1) ABOVE this become mountains.
## Lower it -> more of the world is mountainous.
## Anything between valley_level and mountain_level is rolling hills.
@export_range(0.0, 1.0, 0.01) var mountain_level: float = 0.62

## ★ TWEAK: How gradual the change between zones is. Small = abrupt cliffs
## rising out of the plains; large = long gentle foothills.
@export_range(0.01, 0.4, 0.01) var zone_blend: float = 0.12


@export_group("Rolling Hills")

## ★ TWEAK: Distance (m) between hill crests. Bigger = longer, lazier swells.
@export_range(20.0, 600.0, 1.0) var hill_size: float = 140.0

## ★ TWEAK: Hills swing +/- this many metres around base_height.
@export_range(0.0, 60.0, 0.5) var hill_height: float = 9.0

## Detail layers on the hills (each adds smaller bumps). 3-5 looks natural.
@export_range(1, 8) var hill_octaves: int = 4


@export_group("Mountains")

## ★ TWEAK: Size (m) of mountain ridges/peaks. Smaller = more numerous, spikier
## mountains; larger = massive, broad ranges.
@export_range(100.0, 1500.0, 1.0) var mountain_size: float = 420.0

## ★ TWEAK: Height (m) of the tallest ridgelines above the mountain foothills.
@export_range(0.0, 600.0, 1.0) var mountain_height: float = 170.0

## ★ TWEAK: Extra uniform lift (m) applied across all mountain zones, so
## mountain areas are raised overall rather than just having spikes.
@export_range(0.0, 200.0, 1.0) var mountain_lift: float = 25.0

## ★ TWEAK: Peak shape. 1 = rounded, softer; 2-3 = thin knife-edge ridges
## with wide low slopes between them.
@export_range(0.5, 4.0, 0.05) var ridge_sharpness: float = 1.6

## How wide the ridge pattern is spread. Raw noise rarely strays far from 0,
## so this stretches it so ridges reach the full 0..1 range.
@export_range(1.0, 4.0, 0.1) var ridge_spread: float = 2.0

## Detail layers on the mountains. More = craggier. 4-6 looks good.
@export_range(1, 8) var mountain_octaves: int = 5


@export_group("Foothills")

## ★ TWEAK: How wide the foothill belt is, in region units (0..1), measured
## from where the mountains begin back toward the hill country. Larger = a
## longer, gentler climb into the mountains. 0 = no foothills (abrupt peaks).
@export_range(0.0, 0.6, 0.01) var foothill_width: float = 0.24

## ★ TWEAK: Distance (m) between foothill crests. Bigger = broad rounded
## swells; smaller = lumpier, more broken ground.
@export_range(60.0, 800.0, 1.0) var foothill_size: float = 260.0

## ★ TWEAK: Height (m) of the rounded foothill humps.
@export_range(0.0, 150.0, 1.0) var foothill_height: float = 38.0

## ★ TWEAK: Steady rise (m) across the foothill belt, so the land climbs
## gradually toward the mountains instead of jumping up at the last moment.
## Note: this uplift continues under the mountains too, so they sit this much
## higher. If your snow caps move, adjust snow_line.
@export_range(0.0, 100.0, 1.0) var foothill_lift: float = 14.0


@export_group("Valleys")

## ★ TWEAK: How far (m) below base_height the valley floors sit.
@export_range(0.0, 100.0, 0.5) var valley_depth: float = 20.0

## ★ TWEAK: 0 = perfectly flat valley floors, 1 = floors as bumpy as the hills.
@export_range(0.0, 1.0, 0.01) var valley_flatness: float = 0.3


@export_group("Rivers")

## ★ TWEAK: Turn rivers (and the canyons that ride on them) on/off.
@export var rivers_enabled: bool = true

## ★ TWEAK: The world is divided into square cells this wide (m), and each
## cell may start ONE river. Smaller = rivers start closer together.
@export_range(300.0, 3000.0, 10.0) var river_source_spacing: float = 800.0

## ★ TWEAK: Chance (0..1) that a cell actually gets a river. 1 = every cell
## that has high enough ground gets one.
@export_range(0.0, 1.0, 0.01) var river_density: float = 0.6

## ★ TWEAK: A river can only begin at least this high (m above base_height),
## i.e. up in the foothills or mountains. Lower = rivers can start in hill
## country too; higher = only the upper mountains feed rivers.
@export_range(0.0, 250.0, 1.0) var river_source_altitude: float = 55.0

## ★ TWEAK: Maximum length (m) of a river from source to end. Longer rivers
## cost more the first time they're generated. Very large values make the
## first chunks load slower (each source cell within this distance is traced).
@export_range(500.0, 10000.0, 50.0) var river_max_length: float = 4500.0

## ★ TWEAK: Width (m) of the water channel itself. Keep this at 3+ vertex
## spacings (chunk_size / chunk_resolution) or the channel gets jagged.
@export_range(4.0, 80.0, 0.5) var river_width: float = 12.0

## ★ TWEAK: Distance (m) from the river centre where the gently sloping banks
## blend back into normal terrain. Bigger = wider, softer floodplain.
@export_range(10.0, 300.0, 1.0) var river_bank_width: float = 45.0

## ★ TWEAK: How deep (m) the river is cut below the surrounding land
## (before any canyon deepening).
@export_range(0.0, 30.0, 0.5) var river_depth: float = 5.0

## ★ TWEAK: Ground gentler than this counts as "flat", and the river meanders
## freely across it. Slope is rise / run (0.05 is about 3 degrees). Raise it
## and rivers wind across more of the land, including gentle hills.
@export_range(0.0, 0.5, 0.005) var river_flat_slope: float = 0.05

## ★ TWEAK: Ground steeper than THIS (0.28 is about 16 degrees) makes the river
## run straight down the slope with no meandering. Between the two slopes the
## meandering fades out gradually.
@export_range(0.01, 1.0, 0.005) var river_steep_slope: float = 0.28

## ★ TWEAK: The most (degrees) a river can swing away from straight downhill
## when wandering across flat land. Keep under 90 so it never turns uphill.
## Higher = looser, snakier meanders.
@export_range(0.0, 85.0, 1.0) var river_meander_angle: float = 65.0

## ★ TWEAK: Length (m) of each bend along flat stretches. Smaller = tight,
## frequent curves; larger = long lazy S-bends.
@export_range(60.0, 1500.0, 5.0) var river_meander_wavelength: float = 320.0

## ★ TWEAK: How much a river resists changing direction (0..0.9). Higher =
## smoother, rounder curves. Lower = more jittery path.
@export_range(0.0, 0.9, 0.01) var river_smoothness: float = 0.6

## ★ TWEAK: If the ground ahead rises more than this (m) above what the
## river bed can reach, the river is "blocked" and ends there. Higher =
## rivers cut straight through bigger hills instead of stopping.
@export_range(0.0, 150.0, 1.0) var river_blockage_limit: float = 30.0


@export_group("Canyons (carved along rivers in mountains)")

## ★ TWEAK: Turn canyons on/off. They only ever appear along rivers.
@export var canyons_enabled: bool = true

## ★ TWEAK: How "mountainous" (0..1) the land must be before a river starts
## cutting a canyon. Higher = canyons only deep inside the mountains; lower =
## canyons begin earlier, out in the foothills.
@export_range(0.0, 1.0, 0.01) var canyon_mountain_threshold: float = 0.35

## ★ TWEAK: Floor width (m) of the canyon.
@export_range(8.0, 150.0, 1.0) var canyon_width: float = 30.0

## ★ TWEAK: How far (m) the walls take to rise from the floor to the rim.
## Small = near-vertical cliffs, big = sloping V-shaped valleys.
@export_range(2.0, 80.0, 1.0) var canyon_wall_softness: float = 10.0

## ★ TWEAK: Extra depth (m) the river bed is cut below the land inside a full
## canyon (added on top of river_depth).
@export_range(0.0, 200.0, 1.0) var canyon_depth: float = 55.0

## ★ TWEAK: Number of stepped ledges in the canyon walls.
@export_range(1, 12) var canyon_terraces: int = 5

## ★ TWEAK: 0 = smooth walls, 1 = fully stepped, layered walls.
@export_range(0.0, 1.0, 0.01) var canyon_terracing: float = 0.6


@export_group("Colours (painted per-vertex, no textures needed)")

## ★ TWEAK: Grass colour at the lowest ground (valleys).
@export var lowland_color: Color = Color(0.18, 0.38, 0.12)
## ★ TWEAK: Grass colour on hill tops / higher ground.
@export var highland_color: Color = Color(0.42, 0.52, 0.20)
## ★ TWEAK: Cliff and high-altitude rock colour.
@export var rock_color: Color = Color(0.38, 0.36, 0.34)
## ★ TWEAK: Snow-cap colour.
@export var snow_color: Color = Color(0.95, 0.97, 1.0)
## ★ TWEAK: River water colour. (Painted onto the riverbed - see notes on water.)
@export var water_color: Color = Color(0.10, 0.27, 0.38)
## ★ TWEAK: Muddy/sandy colour along river banks.
@export var bank_color: Color = Color(0.52, 0.47, 0.32)
## ★ TWEAK: Two sandstone colours that alternate in bands up canyon walls.
@export var canyon_color: Color = Color(0.60, 0.34, 0.20)
@export var canyon_color_alt: Color = Color(0.74, 0.52, 0.32)
## ★ TWEAK: How fast the canyon bands repeat as you go up (radians per metre).
## 0.5 = a new band roughly every 12 m. Keep it under ~1.0, since bands thinner
## than 2 vertex spacings will look noisy.
@export_range(0.05, 1.5, 0.05) var canyon_strata_frequency: float = 0.5

## Slope amount where rock starts to show through grass. Slope here is
## (1 - normal.y): 0 = flat ground, ~0.3 = 45 degrees, 0.5 = 60 degrees.
@export_range(0.0, 1.0, 0.01) var rock_slope_start: float = 0.14
## Slope amount where the ground is 100% rock.
@export_range(0.0, 1.0, 0.01) var rock_slope_end: float = 0.32

## ★ TWEAK: Height (m, world Y) where snow begins to appear.
@export var snow_line: float = 110.0
## ★ TWEAK: Distance (m) over which snow fades from none to full cover.
@export var snow_blend: float = 30.0
## Snow won't stick to slopes steeper than this (same slope scale as above).
@export_range(0.0, 1.0, 0.01) var snow_max_slope: float = 0.30

## Optional: assign your own material (e.g. a triplanar/texture shader).
## Vertex colour is available in shaders as COLOR. Leave empty to use the
## built-in vertex-colour material.
@export var terrain_material: Material


@export_group("Player Spawn")

## ★ TWEAK: Move the player to the terrain surface at its current X/Z on start,
## so you never spawn inside a mountain or in mid-air.
@export var snap_player_to_ground_on_start: bool = true

## How many metres above the ground to place the player when snapping.
@export var spawn_height_above_ground: float = 2.0

## Pause the player's physics until collision exists under it, so it
## doesn't fall through the world while the first chunks are generating.
@export var freeze_player_until_ground_ready: bool = true


# =============================================================================
# INTERNALS  (you shouldn't need to change anything below this line)
# =============================================================================

## One streamed section of terrain. Plain data holder; the generated arrays are
## filled by a worker thread, then consumed by the main thread.
class Chunk:
	enum State { GENERATING, ACTIVE }

	var coord: Vector2i                 # Chunk grid coordinate (not metres)
	var state: State = State.GENERATING
	var task_id: int = -1               # WorkerThreadPool task handle

	# Filled by the worker thread:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	# Filled on the main thread:
	var mesh_instance: MeshInstance3D = null
	var body: StaticBody3D = null       # Only exists while the player is near


## One traced river: a polyline from its source down to where it ends.
## Created once, then never modified, so worker threads can read it freely.
class River:
	var xs := PackedFloat32Array()      # World X of each path point
	var zs := PackedFloat32Array()      # World Z of each path point
	var beds := PackedFloat32Array()    # River-bed height (Y). Only ever decreases.
	var canyon := PackedFloat32Array()  # 0..1: how canyon-like the channel is here
	var fade := PackedFloat32Array()    # 0..1: eases the river in at its source and out at its end
	var min_x: float = 0.0              # Bounding box, for quick "is it near?" checks
	var max_x: float = 0.0
	var min_z: float = 0.0
	var max_z: float = 0.0


## The river segments near one chunk, flattened into a single array (10 floats
## per segment) so the per-vertex carving loop stays fast.
## Layout: ax, az, bx, bz, bed_a, bed_b, canyon_a, canyon_b, fade_a, fade_b
class RiverSegs:
	const STRIDE := 10
	var data := PackedFloat32Array()
	var count: int = 0


## Distance (m) between points along a traced river.
const RIVER_STEP := 20.0
## Offset (m) used to measure the ground's slope while tracing a river. Wide
## enough that tiny bumps don't count, so rivers follow the overall lie of the land.
const GRADE_SAMPLE := 20.0
## Minimum downhill grade (m of drop per m of river) forced on the bed, so
## water keeps flowing even across perfectly flat ground.
const RIVER_MIN_FALL := 0.0006

var _region_noise: FastNoiseLite
var _hill_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite
var _foothill_noise: FastNoiseLite
var _meander_noise: FastNoiseLite       # Drives side-to-side wandering on flat ground

# Cache of traced rivers: Vector2i (source cell) -> River (or null = no river).
# Rivers are generated on demand by whichever thread needs them first, so all
# access goes through the mutex.
var _rivers: Dictionary = {}
var _river_mutex := Mutex.new()
var _river_influence: float = 0.0       # How far (m) from a river's centre it can alter terrain

var _material: Material
var _indices := PackedInt32Array()      # Triangle indices, identical for every chunk

var _chunks: Dictionary = {}            # Vector2i -> Chunk
var _pending: Array[Vector2i] = []      # Chunks waiting to start generating, nearest first
var _generating_count: int = 0

var _focus_pos := Vector3.ZERO          # Position we're streaming around
var _timer: float = 0.0
var _spawn_ready: bool = false


func _ready() -> void:
	_setup_noise()
	_build_shared_indices()
	_build_material()
	_resolve_player()

	# Put the player on the surface (terrain height is unknown at design time).
	# The first call also traces the nearby rivers, so expect a brief pause here.
	if player and snap_player_to_ground_on_start:
		var p := player.global_position
		player.global_position = Vector3(
			p.x, get_height(p.x, p.z) + spawn_height_above_ground, p.z)

	# Hold the player in place until the ground under it is solid.
	if player and freeze_player_until_ground_ready:
		player.set_physics_process(false)

	_focus_pos = _get_focus_position()
	_update_streaming()


func _process(delta: float) -> void:
	_focus_pos = _get_focus_position()

	# Re-scan which chunks are needed a few times per second (not every frame).
	_timer += delta
	if _timer >= update_interval:
		_timer = 0.0
		_update_streaming()

	_start_pending_chunks()
	_finish_generated_chunks()
	_update_collisions()
	_check_spawn_ready()


func _exit_tree() -> void:
	# Never leave worker threads running against freed data.
	for key in _chunks.keys():
		var chunk: Chunk = _chunks[key]
		if chunk.state == Chunk.State.GENERATING and chunk.task_id != -1:
			WorkerThreadPool.wait_for_task_completion(chunk.task_id)


# -----------------------------------------------------------------------------
# PUBLIC API
# -----------------------------------------------------------------------------

## Terrain height (world Y) at a world-space X/Z position, including carved
## rivers and canyons. Handy for placing trees, rocks, or enemies:
##     var y := terrain.get_height(x, z)
## Each call looks up nearby rivers, so it's fine for occasional queries but
## not meant for thousands of calls per frame.
func get_height(x: float, z: float) -> float:
	return _sample(x, z, null).x


## World-space point lying on the terrain surface at X/Z.
func get_ground_position(x: float, z: float) -> Vector3:
	return Vector3(x, get_height(x, z), z)


## Throw away every chunk (and cached river) and rebuild from current settings.
## Call after changing seed / noise / river settings at runtime. Pass a seed
## >= 0 to also change the world seed:  terrain.regenerate(randi())
func regenerate(new_seed: int = -1) -> void:
	for key in _chunks.keys():
		var chunk: Chunk = _chunks[key]
		if chunk.state == Chunk.State.GENERATING and chunk.task_id != -1:
			WorkerThreadPool.wait_for_task_completion(chunk.task_id)
		if chunk.mesh_instance:
			chunk.mesh_instance.queue_free()
	_chunks.clear()
	_pending.clear()
	_generating_count = 0

	if new_seed >= 0:
		world_seed = new_seed
	_setup_noise()
	_build_shared_indices()
	_build_material()
	_update_streaming()


# -----------------------------------------------------------------------------
# THE TERRAIN RECIPE
# -----------------------------------------------------------------------------

## The land shape WITHOUT rivers. Returns a Vector2:
##   x = height (world Y)
##   y = mountain weight (0 = not mountainous, 1 = deep in the mountains)
## Rivers are traced on this surface, so it must not depend on them.
func _base_sample(x: float, z: float) -> Vector2:
	# --- 1. Which kind of land is this? (0 = valley-ish ... 1 = mountain-ish)
	# Simplex noise is -1..1; stretch by contrast, then remap to 0..1.
	var region := clampf(
		_region_noise.get_noise_2d(x, z) * region_contrast * 0.5 + 0.5, 0.0, 1.0)

	# Turn that single number into two smooth 0..1 "weights".
	# valley_w is 1 deep inside valleys, fading to 0 as we approach hill country.
	var valley_w := 1.0 - smoothstep(
		valley_level - zone_blend, valley_level + zone_blend, region)
	# mountain_w is 0 in hill country, rising to 1 inside mountain zones.
	var mountain_w := smoothstep(
		mountain_level - zone_blend, mountain_level + zone_blend, region)

	# --- 2. Rolling hills (the baseline everywhere). Noise is -1..1, so the
	# result swings +/- hill_height around base_height.
	var hills := _hill_noise.get_noise_2d(x, z)
	var h := base_height + hills * hill_height

	# --- 3. Valleys: blend toward a lower, flatter version of the hills.
	var valley_floor := base_height - valley_depth + hills * hill_height * valley_flatness
	h = lerpf(h, valley_floor, valley_w)

	# --- 3b. Foothills: a belt of rounded humps that fades in BEFORE the
	# mountains begin. foothill_w climbs from 0 (hill country) to 1 (the edge of
	# the mountain zone), so the land rises steadily instead of jumping up.
	if foothill_width > 0.001:
		var foothill_w := smoothstep(mountain_level - foothill_width, mountain_level, region)
		if foothill_w > 0.0:
			var bump := _foothill_noise.get_noise_2d(x, z) * 0.5 + 0.5   # 0..1, rounded
			h += foothill_w * (foothill_lift + bump * foothill_height)

	# --- 4. Mountains: "ridged" noise. Taking 1 - |noise| folds the noise at its
	# zero-crossings into sharp crest lines (like real mountain ridges).
	var r := absf(_ridge_noise.get_noise_2d(x, z)) * ridge_spread
	var ridge := pow(clampf(1.0 - r, 0.0, 1.0), ridge_sharpness)
	h += mountain_w * (mountain_lift + ridge * mountain_height)

	return Vector2(h, mountain_w)


## Full terrain at a point: the land shape with nearby rivers/canyons carved in.
## `segs` holds the river segments near the point. Chunk generation passes in
## one set for the whole chunk; pass null to look them up for a single point.
## Returns a Vector4:
##   x = height (world Y)
##   y = river bank weight   (0..1, used to paint sand/mud)
##   z = river water weight  (0..1, used to paint water)
##   w = canyon weight       (0..1, used to paint sandstone strata)
func _sample(x: float, z: float, segs: RiverSegs) -> Vector4:
	var base := _base_sample(x, z)
	if segs == null:
		segs = _collect_segments(
			x - _river_influence, z - _river_influence,
			x + _river_influence, z + _river_influence)
	return _carve(x, z, base.x, segs)


## Carves rivers and canyons into the land at one point.
## The idea: find the closest bit of river. The river's bed height there tells
## us how low the channel is. Then a "profile" based on distance decides how
## much of the way down we are: right at the centre we sit at the bed, and
## further out we blend back up to the original ground.
func _carve(x: float, z: float, base_h: float, segs: RiverSegs) -> Vector4:
	if segs.count == 0:
		return Vector4(base_h, 0.0, 0.0, 0.0)

	# --- Find the nearest river segment (distance to a line segment).
	var data := segs.data
	var best_d2 := INF
	var best := -1
	var best_t := 0.0
	for i in segs.count:
		var o := i * RiverSegs.STRIDE
		var ax := data[o]
		var az := data[o + 1]
		var abx := data[o + 2] - ax
		var abz := data[o + 3] - az
		var len2 := maxf(abx * abx + abz * abz, 0.0001)
		# t = how far along the segment the closest point is (0 = start, 1 = end)
		var t := clampf(((x - ax) * abx + (z - az) * abz) / len2, 0.0, 1.0)
		var dx := ax + abx * t - x
		var dz := az + abz * t - z
		var d2 := dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best = i
			best_t = t

	if best < 0 or best_d2 > _river_influence * _river_influence:
		return Vector4(base_h, 0.0, 0.0, 0.0)

	# --- Read the river's properties at that closest point (blend the two ends).
	var o2 := best * RiverSegs.STRIDE
	var bed_y := lerpf(data[o2 + 4], data[o2 + 5], best_t)   # Channel floor height
	var k := lerpf(data[o2 + 6], data[o2 + 7], best_t)       # Canyon strength 0..1
	var fade := lerpf(data[o2 + 8], data[o2 + 9], best_t)    # Source/end fade 0..1
	var d := sqrt(best_d2)                                   # Distance to river centre (m)

	# --- Ordinary river profile: s = 0 inside the channel, rising smoothly to 1
	# (= untouched ground) at river_bank_width. Gentle sloping banks.
	var half := river_width * 0.5
	var bank_edge := maxf(river_bank_width, half + 1.0)
	var s := smoothstep(half, bank_edge, d)

	# --- Canyon profile, blended in by how mountainous this stretch is: a wider
	# flat floor, then steep walls that climb in terraced steps.
	var canyon_w := 0.0
	if k > 0.001:
		var c_half := maxf(canyon_width * 0.5, half)
		var wall := smoothstep(c_half, c_half + canyon_wall_softness, d)  # 0 floor -> 1 rim
		var cut := 1.0 - wall                                              # 1 floor -> 0 rim
		# Terracing: snap `cut` to ledges, rounding the steps slightly.
		var steps := float(canyon_terraces)
		var st := cut * steps
		var stepped := (floorf(st) + smoothstep(0.3, 0.7, st - floorf(st))) / steps
		cut = lerpf(cut, stepped, canyon_terracing)
		s = lerpf(s, 1.0 - cut, k)
		canyon_w = k * fade * (1.0 - smoothstep(c_half, c_half + canyon_wall_softness * 1.5, d))

	# --- Apply: blend from the bed height (s = 0) up to the original ground
	# (s = 1). Ground that is already lower than the bed is left alone.
	var carved := base_h
	if base_h > bed_y:
		carved = lerpf(bed_y, base_h, s)
	var h := lerpf(base_h, carved, fade)

	# --- Paint weights: sand on the banks (not in canyons), water in the channel.
	var sand_w := (1.0 - smoothstep(half, bank_edge, d)) * fade * (1.0 - k)
	var water_w := (1.0 - smoothstep(half * 0.6, half, d)) * fade
	return Vector4(h, sand_w, water_w, canyon_w)


# -----------------------------------------------------------------------------
# RIVER TRACING
# -----------------------------------------------------------------------------

## Cheap deterministic "random" integer for a world cell. The same inputs always
## give the same output, so rivers are identical every run and on every thread.
func _cell_hash(cx: int, cz: int, salt: int) -> int:
	var n := cx * 374761393 + cz * 668265263 + (world_seed + salt * 7919) * 1274126177
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return n & 0x7fffffff


## Same as above but as a float in 0..1.
func _hash01(cx: int, cz: int, salt: int) -> float:
	return float(_cell_hash(cx, cz, salt) % 10000) / 10000.0


## Decides whether a world cell starts a river, and if so traces it.
## Returns null when the cell has no river.
func _make_river_for_cell(cx: int, cz: int) -> River:
	# Not every cell gets a river.
	if _hash01(cx, cz, 0) >= river_density:
		return null

	# Try a few random spots in the cell. A river may only begin on high ground,
	# so the first spot that's high enough becomes the source.
	var cs := river_source_spacing
	for attempt in 4:
		var sx := (cx + _hash01(cx, cz, 1 + attempt * 2)) * cs
		var sz := (cz + _hash01(cx, cz, 2 + attempt * 2)) * cs
		if _base_sample(sx, sz).x - base_height >= river_source_altitude:
			return _trace_river(sx, sz, _hash01(cx, cz, 99) * 1000.0)
	return null


## Walks downhill from (sx, sz), recording the river's path and bed height.
##   - Direction: straight down the steepest slope, but on flat ground the path
##     swings side to side (meanders). The flatter the ground, the bigger the swing.
##   - Bed height: never rises. Each point's bed is the LOWER of "a bit below the
##     ground here" and "just under the previous point", so water always flows
##     downhill, even where the ground bumps up (the river cuts through).
##   - Ends when the ground rises too far above the bed (blocked), or at max length.
func _trace_river(sx: float, sz: float, river_key: float) -> River:
	var river := River.new()
	var pos := Vector2(sx, sz)
	var heading := Vector2.ZERO          # Smoothed direction of travel
	var prev_bed := 0.0
	var max_steps := int(river_max_length / RIVER_STEP)
	var wander_max := deg_to_rad(river_meander_angle)

	for i in max_steps:
		var b := _base_sample(pos.x, pos.y)
		var ground := b.x

		# How canyon-like is the channel here? Only inside mountainous land.
		var ck := 0.0
		if canyons_enabled:
			ck = smoothstep(canyon_mountain_threshold, canyon_mountain_threshold + 0.25, b.y)
			# Ease the canyon in over the first ~240 m, so a river doesn't
			# start out of a deep pit at its source.
			ck *= clampf(float(i) / 12.0, 0.0, 1.0)
		var depth := river_depth + canyon_depth * ck

		# Bed height: below the ground, but never above the previous bed.
		var bed := ground - depth
		if i > 0:
			bed = minf(bed, prev_bed - RIVER_MIN_FALL * RIVER_STEP)
			# Ground rose too far above the bed: the river is blocked and ends.
			if ground - bed > depth + river_blockage_limit:
				break

		river.xs.push_back(pos.x)
		river.zs.push_back(pos.y)
		river.beds.push_back(bed)
		river.canyon.push_back(ck)
		prev_bed = bed

		# --- Choose the next step. Measure the slope with two extra samples.
		var gx := (_base_sample(pos.x + GRADE_SAMPLE, pos.y).x - ground) / GRADE_SAMPLE
		var gz := (_base_sample(pos.x, pos.y + GRADE_SAMPLE).x - ground) / GRADE_SAMPLE
		var grade := Vector2(gx, gz)             # Points uphill
		var slope := grade.length()

		var down: Vector2
		if slope > 0.00001:
			down = -grade / slope                # Straight downhill
		elif heading != Vector2.ZERO:
			down = heading                       # Dead flat: keep going
		else:
			down = Vector2.RIGHT

		# flat = 1 on nearly level ground, 0 on steep ground.
		var flat := 1.0 - smoothstep(river_flat_slope, river_steep_slope, slope)

		# Wander: a smooth noise value, sampled along the river's length, turns
		# the heading left/right. Scaled by `flat`, so steep slopes don't meander.
		var wander := _meander_noise.get_noise_2d(float(i) * RIVER_STEP, river_key) \
			* wander_max * flat
		var desired := down.rotated(wander)

		# Blend with the previous heading for smooth curves (less so on steep
		# ground, where following the slope matters more than smoothness).
		if heading == Vector2.ZERO:
			heading = desired
		else:
			var inertia := river_smoothness * lerpf(0.5, 1.0, flat)
			var blended := heading * inertia + desired * (1.0 - inertia)
			heading = blended.normalized() if blended.length_squared() > 0.0001 else desired

		pos += heading * RIVER_STEP

	# Too short to be worth keeping.
	var n := river.xs.size()
	if n < 6:
		return null

	# Ease the river in at its source and out at its end, so it starts as a
	# trickle and fades into the ground instead of stopping abruptly.
	river.fade.resize(n)
	for i in n:
		river.fade[i] = clampf(minf(float(i) / 4.0 + 0.25, float(n - 1 - i) / 8.0), 0.0, 1.0)

	# Bounding box for quick rejection later.
	river.min_x = river.xs[0]
	river.max_x = river.xs[0]
	river.min_z = river.zs[0]
	river.max_z = river.zs[0]
	for i in n:
		river.min_x = minf(river.min_x, river.xs[i])
		river.max_x = maxf(river.max_x, river.xs[i])
		river.min_z = minf(river.min_z, river.zs[i])
		river.max_z = maxf(river.max_z, river.zs[i])
	return river


## Gathers every river segment that could touch the rectangle (min..max in X/Z),
## tracing any rivers that haven't been generated yet. Safe to call from any thread.
func _collect_segments(min_x: float, min_z: float, max_x: float, max_z: float) -> RiverSegs:
	var out := RiverSegs.new()
	if not rivers_enabled:
		return out

	# A river can't wander further than river_max_length from its source cell,
	# so only source cells within that distance can matter.
	var cs := river_source_spacing
	var reach := river_max_length + cs
	var c0x := floori((min_x - reach) / cs)
	var c1x := floori((max_x + reach) / cs)
	var c0z := floori((min_z - reach) / cs)
	var c1z := floori((max_z + reach) / cs)

	# Only the cache lookup / tracing happens under the lock. Rivers never change
	# once built, so everything after the unlock can run in parallel.
	var found: Array = []
	_river_mutex.lock()
	for cz in range(c0z, c1z + 1):
		for cx in range(c0x, c1x + 1):
			var key := Vector2i(cx, cz)
			if not _rivers.has(key):
				_rivers[key] = _make_river_for_cell(cx, cz)
			if _rivers[key] != null:
				found.append(_rivers[key])
	_river_mutex.unlock()

	# Keep only the segments that are actually near the rectangle.
	var m := _river_influence
	for entry in found:
		var r: River = entry
		if r.max_x < min_x - m or r.min_x > max_x + m \
				or r.max_z < min_z - m or r.min_z > max_z + m:
			continue
		for i in r.xs.size() - 1:
			var ax := r.xs[i]
			var az := r.zs[i]
			var bx := r.xs[i + 1]
			var bz := r.zs[i + 1]
			if maxf(ax, bx) < min_x - m or minf(ax, bx) > max_x + m \
					or maxf(az, bz) < min_z - m or minf(az, bz) > max_z + m:
				continue
			out.data.push_back(ax)
			out.data.push_back(az)
			out.data.push_back(bx)
			out.data.push_back(bz)
			out.data.push_back(r.beds[i])
			out.data.push_back(r.beds[i + 1])
			out.data.push_back(r.canyon[i])
			out.data.push_back(r.canyon[i + 1])
			out.data.push_back(r.fade[i])
			out.data.push_back(r.fade[i + 1])
			out.count += 1
	return out


# -----------------------------------------------------------------------------
# SETUP HELPERS
# -----------------------------------------------------------------------------

func _setup_noise() -> void:
	# Each layer gets a different seed offset so they aren't correlated.
	_region_noise = _make_noise(0, region_size, 2)
	_hill_noise = _make_noise(1, hill_size, hill_octaves)
	_ridge_noise = _make_noise(2, mountain_size, mountain_octaves)
	_foothill_noise = _make_noise(3, foothill_size, 3)
	# One smooth octave: we sample it along a river's length for gentle bends.
	_meander_noise = _make_noise(4, river_meander_wavelength, 1)

	# Rivers depend on every setting above, so drop any that were already traced.
	_river_mutex.lock()
	_rivers.clear()
	_river_mutex.unlock()

	# The furthest (m) from a river's centre that it can change the terrain.
	_river_influence = maxf(river_bank_width, canyon_width * 0.5 + canyon_wall_softness * 1.5) \
		+ RIVER_STEP


func _make_noise(seed_offset: int, feature_size: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = world_seed + seed_offset
	# Frequency is "cycles per metre", so 1 / feature_size gives features of
	# roughly feature_size metres across.
	n.frequency = 1.0 / feature_size
	# FBM = Fractal Brownian Motion: stack octaves of noise, each one smaller
	# (lacunarity) and weaker (gain) than the last, for natural-looking detail.
	n.fractal_type = FastNoiseLite.FRACTAL_FBM if octaves > 1 else FastNoiseLite.FRACTAL_NONE
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5
	return n


## Every chunk has the same grid topology, so the triangle index list is built
## once and shared. Vertex (x, z) has index  z * (resolution + 1) + x.
func _build_shared_indices() -> void:
	var res := chunk_resolution
	var row := res + 1
	_indices = PackedInt32Array()
	_indices.resize(res * res * 6)
	var i := 0
	for z in res:
		for x in res:
			var i00 := z * row + x      # this vertex
			var i10 := i00 + 1          # +x neighbour
			var i01 := i00 + row        # +z neighbour
			var i11 := i01 + 1          # diagonal neighbour
			# Godot treats clockwise (seen from outside) as the front face,
			# so these wind clockwise when viewed from above.
			_indices[i + 0] = i00
			_indices[i + 1] = i10
			_indices[i + 2] = i01
			_indices[i + 3] = i10
			_indices[i + 4] = i11
			_indices[i + 5] = i01
			i += 6


func _build_material() -> void:
	_material = terrain_material
	if _material == null:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true   # Use our painted colours
		m.vertex_color_is_srgb = true         # Colours above are sRGB
		m.roughness = 0.95                    # Matte, no shiny ground
		_material = m


func _resolve_player() -> void:
	if player == null:
		player = get_tree().get_first_node_in_group("player") as Node3D
	if player == null:
		push_warning("TerrainManager: no player assigned (and none in group 'player'). "
			+ "Streaming around the active camera instead.")


func _get_focus_position() -> Vector3:
	if is_instance_valid(player):
		return player.global_position
	var cam := get_viewport().get_camera_3d()
	if cam:
		return cam.global_position
	return Vector3.ZERO


# -----------------------------------------------------------------------------
# STREAMING: decide which chunks should exist
# -----------------------------------------------------------------------------

func _world_to_chunk(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / chunk_size), floori(pos.z / chunk_size))


## Distance from the focus point to a chunk's centre, measured in chunks.
func _chunk_distance(coord: Vector2i) -> float:
	var centre := Vector2((coord.x + 0.5) * chunk_size, (coord.y + 0.5) * chunk_size)
	return centre.distance_to(Vector2(_focus_pos.x, _focus_pos.z)) / chunk_size


func _update_streaming() -> void:
	# --- Load: find missing chunks inside the view radius, nearest first.
	var centre := _world_to_chunk(_focus_pos)
	var r := ceili(view_distance_chunks) + 1
	var needed: Array = []
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var coord := Vector2i(centre.x + dx, centre.y + dz)
			if _chunks.has(coord):
				continue
			var d := _chunk_distance(coord)
			if d <= view_distance_chunks:
				needed.append([d, coord])
	needed.sort_custom(func(a, b): return a[0] < b[0])

	_pending.clear()
	for entry in needed:
		_pending.append(entry[1])

	# --- Unload: free chunks that drifted out of range (plus hysteresis buffer).
	# Chunks still generating are left alone; they're checked when they finish.
	var unload_dist := view_distance_chunks + unload_buffer_chunks
	for key in _chunks.keys():
		var chunk: Chunk = _chunks[key]
		if chunk.state == Chunk.State.GENERATING:
			continue
		if _chunk_distance(key) > unload_dist:
			if chunk.mesh_instance:
				chunk.mesh_instance.queue_free()   # Also frees the collision body child
			_chunks.erase(key)


## Kick off background generation for pending chunks, up to the thread limit.
func _start_pending_chunks() -> void:
	while _generating_count < max_chunks_generating and not _pending.is_empty():
		var coord: Vector2i = _pending.pop_front()
		if _chunks.has(coord):
			continue
		var chunk := Chunk.new()
		chunk.coord = coord
		_chunks[coord] = chunk
		_generating_count += 1
		chunk.task_id = WorkerThreadPool.add_task(
			_generate_chunk_data.bind(chunk), false, "Terrain chunk " + str(coord))


# -----------------------------------------------------------------------------
# GENERATION (runs on a worker thread - touches only data, never the scene tree)
# -----------------------------------------------------------------------------

func _generate_chunk_data(chunk: Chunk) -> void:
	var res := chunk_resolution
	var step := chunk_size / float(res)               # Metres between vertices
	var origin_x := chunk.coord.x * chunk_size        # World position of chunk corner
	var origin_z := chunk.coord.y * chunk_size

	# Find the river segments near this chunk once, up front (this is also what
	# triggers tracing of any rivers that don't exist yet).
	var segs := _collect_segments(
		origin_x - step, origin_z - step,
		origin_x + (res + 1) * step, origin_z + (res + 1) * step)

	# Sample the terrain on a grid with a 1-vertex BORDER all around the chunk.
	# The border lets us compute normals with central differences that use the
	# same heights the neighbouring chunk will compute, so lighting is seamless
	# across chunk edges. Grid index (gx, gz) maps to vertex (gx - 1, gz - 1).
	var stride := res + 3
	var heights := PackedFloat32Array()
	var sand := PackedFloat32Array()      # River bank weight per grid point
	var water := PackedFloat32Array()     # River water weight per grid point
	var canyon := PackedFloat32Array()    # Canyon weight per grid point
	heights.resize(stride * stride)
	sand.resize(stride * stride)
	water.resize(stride * stride)
	canyon.resize(stride * stride)
	for gz in stride:
		for gx in stride:
			var s := _sample(
				origin_x + (gx - 1) * step,
				origin_z + (gz - 1) * step,
				segs)
			var gi := gz * stride + gx
			heights[gi] = s.x
			sand[gi] = s.y
			water[gi] = s.z
			canyon[gi] = s.w

	var row := res + 1
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(row * row)
	normals.resize(row * row)
	colors.resize(row * row)

	for z in row:
		for x in row:
			var gi := (z + 1) * stride + (x + 1)       # Index into the bordered grid
			var h := heights[gi]

			# Surface normal from the height difference of the 4 neighbours.
			var normal := Vector3(
				heights[gi - 1] - heights[gi + 1],         # left  - right
				2.0 * step,
				heights[gi - stride] - heights[gi + stride] # back  - front
			).normalized()

			var vi := z * row + x
			verts[vi] = Vector3(x * step, h, z * step)  # Local to the chunk node
			normals[vi] = normal
			colors[vi] = _get_color(h, normal.y, sand[gi], water[gi], canyon[gi])

	# Hand results to the main thread (it only reads these after the task ends).
	chunk.verts = verts
	chunk.normals = normals
	chunk.colors = colors


## Picks a ground colour from height, steepness, and river/canyon weights.
func _get_color(h: float, normal_y: float, sand_w: float, water_w: float, canyon_w: float) -> Color:
	# Grass tint: darker in low valleys, lighter on hilltops.
	var t := clampf(inverse_lerp(base_height - valley_depth, base_height + hill_height, h), 0.0, 1.0)
	var c := lowland_color.lerp(highland_color, t)

	# Rock: steep slopes show bare stone instead of grass.
	var slope := 1.0 - normal_y
	var rock_t := smoothstep(rock_slope_start, rock_slope_end, slope)
	c = c.lerp(rock_color, rock_t)

	# Canyons: banded sandstone. The stripes follow world height, so the layers
	# line up across chunk borders.
	var strata := 0.5 + 0.5 * sin(h * canyon_strata_frequency)
	c = c.lerp(canyon_color.lerp(canyon_color_alt, strata), canyon_w)

	# Snow: above the snow line, but not on slopes too steep to hold it.
	var snow_t := smoothstep(snow_line, snow_line + snow_blend, h) \
		* (1.0 - smoothstep(snow_max_slope - 0.12, snow_max_slope, slope))
	c = c.lerp(snow_color, snow_t)

	# Rivers go last so they always show on top: sandy banks, then water.
	c = c.lerp(bank_color, sand_w * 0.85)
	c = c.lerp(water_color, water_w)
	return c


# -----------------------------------------------------------------------------
# MAIN-THREAD STEPS: turn finished data into scene nodes
# -----------------------------------------------------------------------------

func _finish_generated_chunks() -> void:
	var built := 0
	for key in _chunks.keys():
		if built >= max_mesh_builds_per_frame:
			break
		var chunk: Chunk = _chunks[key]
		if chunk.state != Chunk.State.GENERATING:
			continue
		if not WorkerThreadPool.is_task_completed(chunk.task_id):
			continue

		WorkerThreadPool.wait_for_task_completion(chunk.task_id)   # Releases the task
		_generating_count -= 1

		# The player may have moved on while this was generating: skip the work.
		if _chunk_distance(key) > view_distance_chunks + unload_buffer_chunks:
			_chunks.erase(key)
			continue

		_build_mesh(chunk)
		built += 1


func _build_mesh(chunk: Chunk) -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = chunk.verts
	arrays[Mesh.ARRAY_NORMAL] = chunk.normals
	arrays[Mesh.ARRAY_COLOR] = chunk.colors
	arrays[Mesh.ARRAY_INDEX] = _indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.name = "Chunk_%d_%d" % [chunk.coord.x, chunk.coord.y]
	mi.mesh = mesh
	mi.material_override = _material
	mi.position = Vector3(chunk.coord.x * chunk_size, 0.0, chunk.coord.y * chunk_size)
	add_child(mi)

	chunk.mesh_instance = mi
	chunk.state = Chunk.State.ACTIVE

	# The raw arrays now live in the mesh; release our copies.
	chunk.verts = PackedVector3Array()
	chunk.normals = PackedVector3Array()
	chunk.colors = PackedColorArray()


## Adds collision to chunks close to the player and removes it from chunks that
## are far away. Trimesh collision is accurate but costly, so it's budgeted.
func _update_collisions() -> void:
	var near := maxf(collision_distance_chunks, 1.0)
	var wanted: Array = []

	for key in _chunks.keys():
		var chunk: Chunk = _chunks[key]
		if chunk.state != Chunk.State.ACTIVE:
			continue
		var d := _chunk_distance(key)
		if chunk.body == null and d <= near:
			wanted.append([d, chunk])
		elif chunk.body != null and d > near + 1.0:
			chunk.body.queue_free()
			chunk.body = null

	wanted.sort_custom(func(a, b): return a[0] < b[0])   # Nearest first
	for i in mini(wanted.size(), max_collision_builds_per_frame):
		_add_collision(wanted[i][1])


func _add_collision(chunk: Chunk) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = collision_layer
	body.collision_mask = 0                 # Static terrain doesn't need to detect anything
	var shape := CollisionShape3D.new()
	shape.shape = chunk.mesh_instance.mesh.create_trimesh_shape()
	body.add_child(shape)
	chunk.mesh_instance.add_child(body)     # Freed automatically with the chunk
	chunk.body = body


## Releases the player once the chunk beneath it has collision.
func _check_spawn_ready() -> void:
	if _spawn_ready:
		return
	var key := _world_to_chunk(_focus_pos)
	if not _chunks.has(key):
		return
	var chunk: Chunk = _chunks[key]
	if chunk.body == null:
		return

	_spawn_ready = true
	if is_instance_valid(player) and freeze_player_until_ground_ready:
		player.set_physics_process(true)
	spawn_ground_ready.emit()
