Zoo Tycoon 2 Engine Reimplementation Spec
Oct 31, 2026 · @HolyFenrir
Goal and principles
Build a new, open-source engine in Zig that plays Zoo Tycoon 2 with all four expansions, reading the assets from the player's own install. It runs natively on Linux first. The first finished target is a stable freeform zoo that someone can build, run, save, and reload. The engine never runs or patches zt.exe, so no disc is needed.
This follows the model of OpenRCT2, which reimplements RollerCoaster Tycoon 2 and requires the original game's files to run.
Principles
1. Original data required. The engine ships no game assets. On first run it points at an existing install and reads the z2f files from it.
2. Linux first. Wayland and X11 on x86-64 are the release target. Windows and macOS are a bonus later, kept possible by isolating platform code behind one module.
3. Parity before enhancements. Match the original's behavior first; higher resolutions, a higher entity cap, and quality-of-life features come after. Enhancements that change gameplay sit behind settings.
4. Data-driven. Animals, objects, and rules come from the game's own XML definitions wherever possible, so expansions and community mods load without engine changes.
5. Clean code. Consistent camelCase APIs, explicit allocators, no hidden globals, and tests next to the code they cover.
Clean-room and legal rules
The project must be publishable under an open license, so where knowledge comes from matters as much as the code.
1. Allowed sources: the game's data files (z2f archives, XML, models, textures, sounds), observing the running game, the manual, and community format documentation and modding tools.
2. Not allowed: disassembly or decompilation of zt.exe or its DLLs translated into engine code. No copied code, constants tables, or algorithms lifted from the binary.
3. Community tools as references only. For example, the bfb-blender toolset imports and exports ZT2 models and animations. We check our readers' output against it, but we don't port its code unless its license allows and we credit it.
4. No assets in the repo. Test fixtures are synthetic files we author, or are generated at test time from the user's install.
5. No copy-protection work. The engine reads the installed data files only; it never touches the disc check.
6. Trademarks. The project gets its own name and logo, and says "requires Zoo Tycoon 2" rather than presenting itself as the game.
