#!/usr/bin/env bash
# Cross-builds zootycon2.exe for 64-bit Windows and assembles a folder that can
# be copied to (or run from) Windows. Usage: scripts/package-windows.sh [dest]
# Default destination is dist/windows in the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
dest="${1:-dist/windows}"
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -p "$dest/_build"
mkdir -p "$dest"
cp "$dest/_build/bin/zootycon2.exe" "$dest/"
rm -rf "$dest/_build"
cat > "$dest/play.bat" <<'EOF'
@echo off
rem Starts the zoo on the small alpine map. The game data is found in the usual
rem Windows install location; if yours is elsewhere, edit the line below and add:
rem   --data "D:\Games\Zoo Tycoon 2"
cd /d "%~dp0"
zootycon2.exe play
pause
EOF
cat > "$dest/play-modern.bat" <<'EOF'
@echo off
rem Same as play.bat with the optional modern look: linear lighting, filmic tone
rem mapping, anti-aliasing and sun shadows. Needs a reasonable GPU.
cd /d "%~dp0"
zootycon2.exe play --modern
pause
EOF
cat > "$dest/README.txt" <<'EOF'
zootycon2 - an open-source engine for Zoo Tycoon 2 (requires your own copy of the game).

Run play.bat (original look) or play-modern.bat (better lighting, shadows,
anti-aliasing; the same toggles are in the in-game Settings menu). It finds the game in C:\Program Files (x86)\Microsoft Games\Zoo Tycoon 2.
Elsewhere? Use:  zootycon2.exe --data "D:\path\to\Zoo Tycoon 2" play maps/default/alpinesml.zt2
Other maps:      zootycon2.exe play maps/default/amazonbasin.zt2   (see: zootycon2.exe list maps)

Saves go to %LOCALAPPDATA%\zootycon2\saves. Controls are shown on screen (F1 hides them).
EOF
echo "packaged in $dest"
