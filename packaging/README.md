# Building the releases

1. `packaging/sync.py`: copies the editor and the tools it needs in from the working folders.
2. Put these in `.dl/`:
   - `Godot_v4.7-stable_linux.x86_64` (the standard build, not .NET)
   - the 4.7 export templates `linux_release.x86_64` and `windows_release_x86_64.exe`, in
     `~/.local/share/godot/export_templates/4.7.stable/`
   - `cpython-3.12.*-x86_64-unknown-linux-gnu-install_only.tar.gz` and
     `cpython-3.12.*-x86_64-pc-windows-msvc-install_only.tar.gz` from
     [python-build-standalone](https://github.com/astral-sh/python-build-standalone/releases)
   - `appimagetool-x86_64.AppImage` from [appimagetool](https://github.com/AppImage/appimagetool/releases)
3. `packaging/build.sh 0.1.0`: writes `dist/lp2-mapedit-0.1.0-windows-x64.zip` and
   `dist/lp2-mapedit-0.1.0-x86_64.AppImage`.
