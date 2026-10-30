#!/bin/sh
# Start the LP2 Map Editor (Godot 4.7 from ~/Applications). Extra arguments go to the editor, e.g.
#   ./run.sh --project ~/Projects/LostPlanet2Maps/Ports/Area921.lpme (or an older project folder)
GODOT="${GODOT:-$HOME/Applications/Godot_v4.7_NET/Godot_v4.7-stable_mono_linux.x86_64}"
exec "$GODOT" --path "$(dirname "$(readlink -f "$0")")" -- "$@"
