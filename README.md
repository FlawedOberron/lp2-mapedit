# LP2 Map Editor

A map editor for **Lost Planet 2** custom multiplayer maps. Start from a Lost Planet 1 map, move and copy its
level geometry, place spawns, weapons, VS and lights, set the sky, fog and weather, walk it in a preview, then
install it into the game in one click.

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
- **Lost Planet: Extreme Condition** (PC), only if you want to import its maps. That's the only way to start a
  new map for now.

No game files are included or uploaded anywhere. The editor reads the models and maps it needs from your own
installs.

## First run

1. The **Settings** window opens. Check the Lost Planet 2 folder (Steam installs are found automatically) and,
   if you have it, the Lost Planet 1 folder. Click **Save**.
2. The editor then builds its **asset library** from your games (game models for the markers and the Browser).
   This takes a few minutes, once.
3. **New...**: pick an LP1 map, give it a name, then **Create**. Importing takes a couple of minutes, and so does
   the first preview build.
4. Edit, **Save**, then **Install to game** (with the game closed). The map shows up in the game's map list.

Map projects go in `Documents/LP2 Maps` by default. A project is a folder (`project.json`, `layout.json` and
`assets/`), so you can zip it up and share it, or keep it in git.

## Controls

- Hold the right mouse button to look; WASD to move, Q or Ctrl / E or Space down / up, Shift for faster, wheel for speed.
- Left click selects (Shift / Ctrl adds). W / E / R: move / rotate / scale. F frames, End drops to the floor.
- Ctrl+D duplicates, Ctrl+G groups, Delete deletes, Ctrl+Z / Ctrl+Y undo / redo.
- Ctrl+S saves from any window.
- Windows: B Browser, M Mesh builder, P Preview (walk the map), L Lighting, I Map info, H Fog & weather, T Place.

There's more detail in [editor/README.md](editor/README.md).

## Status

Work in progress, and the game side is still being reverse-engineered. Expect rough edges: lighting doesn't
fully match the game yet, and some LP1 VS don't work in LP2 yet.

## Repository

- `editor/`: the Godot 4.7 project (GDScript).
- `tools/`: the Python map pipeline the editor runs (importing, previews, collision, compiling the map package).
- `packaging/`: release builds (`build.sh`) and `sync.py`, which copies the editor and tools in from the
  working folders.

To run from source: Godot 4.7, plus Python 3.10 or newer with `numpy` and `Pillow` (`python3` on the PATH).
Open `editor/` in Godot, or run `editor/run.sh`; it uses `tools/` next to it.

Not affiliated with or endorsed by Capcom. Lost Planet is a trademark of Capcom.
