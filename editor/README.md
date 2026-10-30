# LP2 Map Editor

A map editor for Lost Planet 2 (Recolonised) custom maps, built with Godot 4.7. It's a GUI over the
lp2-tools map pipeline: a map is a **project folder** (`lp2project.py`), which `lp2mapc.py` compiles into a
`Maps\*.zip` package the game loads. The plan is in `lp2-tools/notes/map-editor-plan.md`.

Start it from the app menu ("LP2 Map Editor") or with `./run.sh [--project DIR]`. It reopens the last
project.

## What works
- **Open** a `.lpme` map (a zip of the project, unpacked into a workspace under the editor's data folder and
  packed back on every save; a bare `project.json` still opens). **Import map from LP/LP2...** starts one from an
  LP1 or stock LP2 map. The stage preview (`.preview/geo.json` + `geo.bin` + `tex/`) is built the first
  time, which takes about 2 minutes (progress bar, top right), then cached.
- **Viewport:** the stage with its textures and LP1 baked light (toggle **Baked light** for sun lighting).
  - Hold the right mouse button to look; WASD to move, Q / E down / up, Shift for faster, mouse wheel
    (while looking) to change speed.
- **Outliner** (left), grouped: Spawns & game logic, Pickups, Vehicles, Level geometry.
- **Markers** for the layout picked with **Layout 1-4**, and the marker set within it:
  - spawns as capsules: red = team A, blue = team B, green = other
  - VS = orange boxes, weapons = yellow, other objects (posts...) = purple
  - every marker has a dot that stays visible from across the map
- **Level geometry:** the stage is split into pieces (lp2pieces.py: connected parts, near ones joined).
  - Click to select (Shift / Ctrl+click adds); clicking never moves anything.
  - **Gizmo:** W move, E rotate, R scale; drag an axis handle, or the centre ball (move on the view plane /
    uniform scale). Hold Ctrl (or tick **Snap**) for 50 cm / 15 degree / 0.1 steps. Markers move and turn
    (about Y) only.
  - Inspector: name, position (cm), rotation, scale; Drop to floor (End), Frame (F).
  - Duplicate (Ctrl+D), Delete, Reset (back where the map had it), Group (Ctrl+G), Ungroup
    (Ctrl+Shift+G: a piece splits into its parts, then into single atoms), Restore deleted.
  - Ctrl+Z / Ctrl+Y undo / redo.
- Selected pieces show a wireframe of their edges (bright, and faint through walls).
- **Browser (B)**: a floating window with thumbnails. Prefabs: make one from the selected pieces, place
  copies (where the view points) or double-click; copies reuse the stage's own geometry and textures.
  In the level: every piece, filterable; click selects, double-click frames.
  Game assets > LP2 objects: the game's object models (crates, walls, trees, towers; lp2props.py), one piece
  each: double-click places one; it is built into the stage with its textures and its own triangles as collision.
- **Preview (P)**: walk the map from where the view points: a soldier-sized capsule with an over-the-shoulder camera,
  colliding with the stage preview's triangles. WASD, mouse look, Space jump, C crouch, Shift walk, F grapple, R back to
  the start, Esc back to the editor. The speeds / heights are guesses to tune against the game (settings.cfg
  [preview]: run, walk, crouch_speed, jump, gravity, height, crouch_height, radius, grapple_range, grapple_speed,
  slope, step, fov).
- **Lighting (L)**, work in progress (doesn't fully match the game yet): sun (direction, colour x brightness), sky light from above / below and ambient (the game's
  hemisphere and ambient lights), a stock map's day as a preset, the sky dome (the map's own, a stock map's sky,
  or a panorama image copied into `assets/`) and atmosphere (scattering preset, haze, sky tint). Placed point and
  spot lights (the engine's placeable types) are markers under Lights in the outliner: gizmo to move / turn,
  Delete, Ctrl+D; colour, brightness, range, cone, soft edge and pitch in the window, or right-click a light
  (a quick click, no turn) for the same settings in a popup. Export: lp2light.py --env
  (Light / Filter schedulers) and lp2sky.py (sky model in the online00_car1 slot). The preview shows the sun,
  ambient, the sky and placed lights (in baked mode they add on top of the bake).
- **Mesh builder (M)**, experimental (WIP): a floating window to import OBJ / glTF files (Y up, metres: Blender's
  default export) as pieces (lp2mesh.py; kept in the project's `imports/`). Each file is one piece; double-click (or
  Place) puts a copy where the view points, and the Browser lists them under My assets (New custom mesh, folders).
  - Collision objects: a Blender object named `COL_<name>` (any `.001` suffix) is the collision of `<name>` and isn't
    drawn; objects without one collide with their own triangles.
  - Per mesh: collision (own mesh / COL_ objects, its box, or none), scale, and which project material each of the file's materials uses.
    Apply rebuilds it; Re-import reads the file again from where it came from. Placed copies follow either way.
  - Materials (the project's `materials/`): colour map, normal map (OpenGL style), specular mask (white = shiny), or a
    plain colour; largest side 256-2048 px. A file's own materials become project materials of the same name (an
    existing one is reused), so meshes that share a trim sheet load its textures once per map. Preview: a lit sphere.
- **Kill floor** (Map info): a height, shown as a red sheet and saved in the project. The game does not
  use it yet (it needs the DLL's map volumes).
- **Pickup** (select weapon pickups): a fixed weapon (always that one, whatever the loadouts) or a slot (Standard /
  Short / Long / Heavy / Special / grenades: the match settings choose). "Layout default" keeps the stock record's.
  Saved as `"item"`. Fixed names follow the game's weapon list and are unconfirmed in game; heavy weapons (Rocket
  Launcher etc.) only exist as the Heavy slot.
- **Buried: digs** (select pickups and / or VS, weapons and grenades included): they start under a "dig here" pile
  that players dig up, with the number of digs and the pile model (A / B / C, the ones the stock maps use). Untick to
  unbury. Exported to the layout as `"dig"` / `"dig_pile"` (lp2layout writes the object record's mUserData[2..3]).
- **VS models** stand as in game: posed in their motion 0 (standing idle) first frame by `lp2library.py get --force`;
  types where that doesn't fit (flying, bosses) keep the bind pose, lowest point on the floor.
- **Rebuild physics on export** (Map info): grenades, debris and ragdolls follow moved, hidden and placed
  pieces (a new physics tree; adds about 15 s to the export). Off: physics keeps the map's original shape.
- **Performance:** the strip above the log shows the stage memory (model + textures) against the stock
  map's; click it for the full stats.
- **Map info:** name, size class, water height (water is off unless ticked).
- **Save** (Ctrl+S) writes `project.json`, the layout and `geometry.json` (the geometry edits).
- **Export** compiles the package to `PROJECT/build/<tag>.zip`; moved, deleted and copied pieces take their
  collision with them. Grenade / debris physics keeps the original shapes for now.
- **Install to game** copies it into the game's `Maps` folder. It refuses while the game is running and
  backs up the package it replaces.

## Make a project
```
python3 ~/Projects/lp2-tools/lp2project.py import-lp1 sNNN.arc ~/Projects/lp2-assets/projects/Name --name "Name" --exclude _sky
```
Or `lp1map.py ... --project DIR`, which imports and also builds the package.

## Settings
`~/.local/share/godot/app_userdata/LP2 Map Editor/settings.cfg`, section `[paths]`:
- `tools`: lp2-tools folder
- `game`: Lost Planet 2 folder
- `python`

## Not yet (see the plan)
- Adding or deleting markers (marker counts follow the stock files for now).
- Real ? Man / VS / weapon models.
- Collision options per placed LP2 object (they always collide with their own triangles; imported meshes have
  the choice).
- Ground types (snow, metal...) on imported meshes' collision: painting.
- Painting, lights, volumes, navmesh.
- Stock LP2 map import.
- Physics (grenades, debris) following moved geometry (needs a Havok MOPP builder).
