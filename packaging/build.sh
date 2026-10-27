#!/bin/sh
# Build the releases into dist/: lp2-mapedit-windows-x64.zip and lp2-mapedit-x86_64.AppImage.
#
#   packaging/build.sh [VERSION]
#
# Needs (in .dl/, see packaging/README.md): Godot_v4.7-stable_linux.x86_64 with the 4.7 export templates installed,
# python-build-standalone 3.12 install_only tarballs for Linux and Windows, appimagetool-x86_64.AppImage.
# Each release: the editor executable, python/ (with numpy and Pillow) and tools/ side by side.
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-dev}
DL=$REPO/.dl
GODOT=$DL/Godot_v4.7-stable_linux.x86_64
WORK=$REPO/build
DIST=$REPO/dist
PKGS="numpy pillow"
rm -rf "$WORK" && mkdir -p "$WORK" "$DIST"

tools() {   # $1: destination; the tools, byte-compiled with the bundle's Python where it can run
	mkdir -p "$1/tools"
	cp "$REPO"/tools/* "$1/tools/"
}

# ---- Godot exports (import first: a fresh checkout has no .godot/)
mkdir -p "$WORK/win" "$WORK/AppDir"
"$GODOT" --headless --path "$REPO/editor" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$REPO/editor" --export-release "Windows Desktop" "$WORK/win/lp2-mapedit.exe"
"$GODOT" --headless --path "$REPO/editor" --export-release "Linux" "$WORK/AppDir/lp2-mapedit"

# ---- Windows: python/ with numpy + Pillow wheels unpacked into site-packages (no pip on the target)
tar -xzf "$DL"/cpython-3.12.*-x86_64-pc-windows-msvc-install_only.tar.gz -C "$WORK/win"
python3 -m pip download -q --only-binary=:all: --platform win_amd64 --python-version 3.12 -d "$WORK/wheels-win" $PKGS
for w in "$WORK"/wheels-win/*.whl; do python3 -m zipfile -e "$w" "$WORK/win/python/Lib/site-packages"; done
rm -rf "$WORK/win/python/Lib/test" "$WORK/win/python/Lib/idlelib" "$WORK/win/python/Lib/tkinter" "$WORK/win/python/tcl" \
	"$WORK/win/python/include"
tools "$WORK/win"
cp "$REPO/README.md" "$WORK/win/README.md"
cp "$REPO/LICENSE" "$WORK/win/LICENSE.txt"
echo "$VERSION" > "$WORK/win/version.txt"   # the editor's update check compares it with the newest release
(cd "$WORK/win" && rm -f "$DIST/lp2-mapedit-$VERSION-windows-x64.zip" && zip -qr9 "$DIST/lp2-mapedit-$VERSION-windows-x64.zip" .)

# ---- Linux AppImage
A=$WORK/AppDir
tar -xzf "$DL"/cpython-3.12.*-x86_64-unknown-linux-gnu-install_only.tar.gz -C "$A"
"$A/python/bin/python3" -m pip install -q --no-warn-script-location --disable-pip-version-check $PKGS
rm -rf "$A/python/lib/python3.12/test" "$A/python/lib/python3.12/idlelib" "$A/python/lib/python3.12/tkinter" \
	"$A/python/include" "$A"/python/lib/libtcl* "$A"/python/lib/libtk* "$A"/python/lib/tcl* "$A"/python/lib/tk*
tools "$A"
echo "$VERSION" > "$A/version.txt"
"$A/python/bin/python3" -m compileall -q "$A/tools"   # the AppImage is read-only: no .pyc written at run time
cp "$REPO/editor/icon.png" "$A/lp2-mapedit.png"
cat > "$A/lp2-mapedit.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LP2 Map Editor
Comment=Map editor for Lost Planet 2 custom maps
Exec=lp2-mapedit
Icon=lp2-mapedit
Categories=Game;Development;
Terminal=false
EOF
cat > "$A/AppRun" <<'EOF'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
export PYTHONDONTWRITEBYTECODE=1
exec "$HERE/lp2-mapedit" "$@"
EOF
chmod +x "$A/AppRun" "$A/lp2-mapedit"
ARCH=x86_64 "$DL/appimagetool-x86_64.AppImage" --no-appstream "$A" "$DIST/lp2-mapedit-$VERSION-x86_64.AppImage" >/dev/null 2>&1 \
	|| ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$DL/appimagetool-x86_64.AppImage" --no-appstream "$A" "$DIST/lp2-mapedit-$VERSION-x86_64.AppImage"
ls -la "$DIST"
