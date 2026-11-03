#!/bin/sh
# Start the LP2 Map Editor (standard Godot 4.7 from ~/Applications: the .NET build hangs on quit, the process
# staying behind with no window). Extra arguments go to the editor, e.g.
#   ./run.sh --project ~/Projects/LostPlanet2Maps/Ports/Area921.lpme (or an older project folder)
GODOT="${GODOT:-$HOME/Applications/Godot_v4.7/Godot_v4.7-stable_linux.x86_64}"
exec "$GODOT" --path "$(dirname "$(readlink -f "$0")")" -- "$@"
