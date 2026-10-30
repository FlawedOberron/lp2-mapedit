# LP2 Map Editor

A map editor for **Lost Planet 2** custom multiplayer maps. Start from a Lost Planet 1 or Lost Planet 2 map, move
and copy its level geometry, bring in your own meshes from Blender, place spawns, weapons, VS and lights, set the
sky, fog, weather and sound, walk it in a preview, then install it into the game in one click.

> **You need the map loader to play custom maps.** The game only loads them with our replacement `xlive.dll`:
> **[xlive-steamworks-lp2](https://github.com/FlawedOberron/xlive-steamworks-lp2)**. Install that first. Everyone
> in a match needs it, and the same map package.

## Download

From [Releases](https://github.com/FlawedOberron/lp2-mapedit/releases):

- **Windows:** `lp2-mapedit-<version>-windows-x64.zip`. Unzip it anywhere and run `lp2-mapedit.exe`.
- **Linux:** `lp2-mapedit-<version>-x86_64.AppImage`. Make it executable (`chmod +x`) and run it.

Everything the editor needs is inside, including its own Python, so there's nothing else to install.

## What you need

- **Lost Planet 2** (Steam, PC), with the [xlive-steamworks-lp2](https://github.com/FlawedOberron/xlive-steamworks-lp2) loader.
- **Lost Planet: Extreme Condition** (PC), only if you want to import its maps. A new map starts from an LP1 or
  LP2 map.

No game files are included or uploaded anywhere. The editor reads the models and maps it needs from your own
installs.

## First run

1. The **Settings** window opens. Check the Lost Planet 2 folder (Steam installs are found automatically) and,
   if you have it, the Lost Planet 1 folder. Click **Save**.
2. The editor then builds its **asset library** from your games (game models for the markers and the Browser).
   This takes a few minutes, once.
3. **Import map from LP/LP2...**: pick Lost Planet 1 or 2 and a map, then choose where to save it. Importing
   takes a couple of minutes, and so does the first preview build.
4. Edit, **Save**, then **Install to game** (with the game closed). The map shows up in the game's map list.

A map is one `.lpme` file (`Documents/LP2 Maps` by default): a zip of the project (`project.json`,
`layout.json`, your meshes and textures), so it's one file to share. The editor works on an unpacked copy and
packs it back on every save.

## Your own meshes (from Blender) — experimental

Work in progress: it works, but expect changes and rough edges.

1. In Blender: **File > Export > glTF 2.0 (.glb)** (or Wavefront .obj), with the default settings (Y up, metres).
2. In the editor's **Browser**, **My assets** tab: **New custom mesh** (or the Mesh builder, M), then pick the file.
   The whole file becomes one mesh.
3. Map each of the file's materials to a project material (textures, or a blockout grid), set the scale, then
   place it like any other asset.
4. Edited it in Blender? Export again over the same file and click **Re-import**: placed copies update.

**Collision:** an object named `COL_<name>` is the collision for the object `<name>`, and is never drawn. For
example, a detailed `Girder` with a few boxes named `COL_Girder`: players see the girder and collide with the
boxes, which is much cheaper. Blender's `.001` suffixes are fine (`COL_Girder.001` still goes with `Girder`).
Objects without a `COL_` partner collide with their own triangles. The Collision setting can also make the whole
mesh a simple box, or not solid at all.

## Lighting — work in progress

The Lighting window (L) sets how the map is lit. It doesn't fully match the game yet, so check your map in game.

- **Sun, sky and ground colours, ambient and sun direction** ("Sun from behind the view" puts it behind the camera).
  The game lights players, VS and objects with these live.
- **The level's own light is baked** into the stage. **LP1 lightmap** keeps the original map's lighting.
  **Ray-traced bake** computes new light from the sun, sky, your placed lights, glowing materials and light
  bouncing between surfaces. Some sliders change the preview at once; others need **Bake lighting** again
  (about half a minute; longer with more detail).
- **Placed point and spot lights** are baked into the stage and also added to the game's lights. The game only
  takes a limited number of live lights.
- **Sky** (the map's own, another LP2 map's, or a panorama image), **haze / fog** and **colour grade** presets
  come from the stock maps.
- **Volumes** can override the post-processing, weather and reverb (sound) inside an area, e.g. an indoor room
  with no rain and an echo.

## Controls

- Hold the right mouse button to look; WASD to move, Q or Ctrl / E or Space down / up, Shift for faster, wheel for speed.
- Left click selects (Shift / Ctrl adds). W / E / R: move / rotate / scale. F frames, End drops to the floor.
- Ctrl+D duplicates, Ctrl+G groups, Delete deletes, Ctrl+Z / Ctrl+Y undo / redo.
- Ctrl+S saves from any window.
- Windows: B Browser, M Mesh builder, P Preview (walk the map), L Lighting, I Map info, H Fog & weather, T Place.

There's more detail in [editor/README.md](editor/README.md).

## Status

Work in progress, and the game side is still being reverse-engineered. Expect rough edges: lighting doesn't
fully match the game yet, custom meshes are experimental, maps imported from LP2 can run over the game's memory
budget, and some LP1 VS don't work in LP2 yet.

## Repository

- `editor/`: the Godot 4.7 project (GDScript).
- `tools/`: the Python map pipeline the editor runs (importing, previews, collision, compiling the map package).
- `packaging/`: release builds (`build.sh`) and `sync.py`, which copies the editor and tools in from the
  working folders.

To run from source: Godot 4.7, plus Python 3.10 or newer with `numpy` and `Pillow` (`python3` on the PATH).
Open `editor/` in Godot, or run `editor/run.sh`; it uses `tools/` next to it.

Not affiliated with or endorsed by Capcom. Lost Planet is a trademark of Capcom.
