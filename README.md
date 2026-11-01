# zootycon2

An open-source engine for Zoo Tycoon 2, written in Zig. It plays the game from
the player's own install: **no game assets are included**, and the engine
never runs or patches `zt.exe`. See `specs.md` for goals and the clean-room
rules.

Animals get hungry and thirsty. With a feeder they can reach (inside their
fence, with food in it, and of a kind their species eats) they walk over and
eat, using the game's own task files; hungry animals are less fun to watch, so
guests enjoy them less. Feeders need refilling.

Guests arrive at the front gate, pay admission, walk the paths to spots near
animals, watch them, and leave; the top right shows guests, takings, views,
happiness and the star rating (which raises the guest cap). The numbers come
from the game's own `ai/guestmgr.xml`.

Licensed under MIT (see `LICENSE`; vendored SDL3 keeps its own zlib license
in `vendor/`). Not affiliated with or endorsed by Microsoft or Blue Fang
Games; you need your own copy of Zoo Tycoon 2.

Status: an asset pipeline (every model, texture, animation and map in the
game loads), a renderer, a small simulation, and build tools. It is not yet
a playable game. It has a basic UI, a budget (purchases cost money, keepers draw salaries) and data-driven animal AI.

## Build and run

Needs Zig 0.17. SDL3 is vendored; there is nothing else to install.

```
zig build                      # builds zig-out/bin/zootycon2
zig build test                 # unit tests
zig build run -- <command>     # run a command
```

Game data is found the way OpenMW finds its data: `--data <dir>`,
`$ZOOTYCON2_DATA`, `~/.config/zootycon2/config` (`data=<dir>`), a working copy
made by `import`, then standard Windows/Wine locations. `zootycon2 where`
shows what it would use.

## Commands

Playing and viewing

| command | what it does |
| --- | --- |
| `play <map\|save>` | Interactive zoo with build tools and the simulation. |
| `map <file.zt2>` | Look at a map (no tools, no simulation). |
| `view <model>` | View one `.nif` or `.bfm` model; `--anim <name\|file.bf>` plays an animation. |

`play` accepts a map from the game data (`maps/default/alpinesml.zt2`) or a
save on disk. Useful flags: `--no-sim`, `--view` (no tools), `--seed N`,
`--save-dir D`, `--at X Y --yaw R --pitch R --zoom F` (camera), `--shot`
(write a PPM screenshot to stdout and exit).

Data checks (all run over the whole game and print a summary)

`nifcheck`, `ddscheck`, `bfcheck`, `modelcheck`, `xmlcheck`, `mapcheck`.
Others: `list`, `cat`, `export`, `elements`, `entity`, `entities`, `info`.

## Controls in `play`

Right-drag orbits, middle-drag grabs and pans, the wheel zooms toward the
cursor, WASD or the arrow keys pan (Shift is faster), Q and E turn, Esc quits.
The camera eases towards where you point it and follows the terrain height. The window title
shows the current tool, the selected item, and the last message.

| key | action |
| --- | --- |
| `1` | select (click an object; `Delete` or `X` removes it) |
| `2` | place an object (`[` `]` choose, `R` rotates) |
| `3` | fence line (click the start, then each corner) |
| `4` | paint path tiles (click or drag) |
| `5` `6` `7` | raise, lower, flatten terrain (hold left mouse) |
| `8` | place an animal or person (`[` `]` choose) |
| `9` | place a food or water container; select it (tool 1) and press `F` to refill (Shift+F: all) |
| `Z` | undo |
| `Tab`, `,`, `.` | pause, slower, faster simulation |
| `T`, `F2`, `F3` | run or stop the clock, previous or next time of day |
| `G` | turn guest arrivals on or off |
| `M` | sound on or off (`--no-sound` disables it entirely) |
| `F5`, `F9` | save, load the last save |

An on-screen display shows the current tool, a hint for it, the simulation
status and a key reference; `F1` hides the help. The tool buttons on the left
can be clicked, and tools that choose from a catalog show a list on the right:
click an entry or scroll the wheel over it. Hold Shift with `[` `]` to
jump ten items. Saves go to
`~/.local/share/zootycon2/saves/<map>.zt2` (plus a `.dat` with the edited
terrain). They use the game's own map schema, so `play` and `map` open them;
the original game does not.

## Texture packs and mods

Folders of loose files override the game's files of the same path (case and
slashes ignored), so a replacement `textures/foo.dds` or edited XML just
works. Folders are read from `mods/<name>/` next to where you run the game,
`<user data dir>/mods/<name>/`, and any `--mod <dir>` (repeatable); later ones
win.

## Performance

Large maps have thousands of draw calls. Placed objects are frustum- and
size-culled, but there is no level-of-detail switching yet (the most detailed
model is always used). In WSL without GPU access the renderer is Mesa's
software `llvmpipe` (the title and `info` output show it), which runs the
biggest map at single-digit frames per second; a real GPU should be far
faster. Use `-Doptimize=ReleaseFast` for anything but debugging.

## Driving it without a person

`play` can be scripted, which is how most of it is tested:

* `--script "cmd; cmd"` runs build commands at startup (`prop X Y`,
  `fence X1 Y1 X2 Y2`, `raise X Y SECONDS`, `wait SECONDS`, `save`, ...).
* `--input "action; action"` plays a **virtual mouse and keyboard** through
  SDL's real event queue, one action per frame: `at X Y` (pointer over a world
  position), `click`, `down 3`, `key 2`, `keydown w`, `wheel 3`, `wait 30`,
  `cam YAW PITCH DIST [CX CY]`, `info`, `shot`, `quit`. The same code runs as
  for a person at the keyboard.
* `--shot` writes the final frame as a PPM to stdout.

```
zootycon2 play maps/default/alpinesml.zt2 --shot \
  --input "cam -1 0.9 70 60 60; key 3; at 45 45; click; at 75 45; click; shot" > out.ppm
```

## Layout

| file | purpose |
| --- | --- |
| `vfs.zig`, `archive.zig`, `config.zig` | game data: z2f archives (plain ZIP), loose files, data discovery |
| `xml.zig`, `entity.zig` | XML reader; entity definitions and their inheritance |
| `nif.zig`, `bf.zig`, `dds.zig`, `model.zig` | models, skeletal animation, textures, manifests/materials |
| `terrain.zig`, `map.zig` | `.dat` terrain and `.zt2` maps/saves |
| `world.zig` | the editable world and its save format |
| `environment.zig` | time-of-day lights, ambient and fog from the game's lighting files |
| `sim.zig` | agents, walkway graph, fence blocking; people walk the paths, animals run their data-driven brains |
| `ai.zig` | the game's task templates and behaviour sets (`ai/tasks`): need-based task choice and posture-aware behaviour execution for animals |
| `viewer.zig`, `gl.zig`, `platform/` | OpenGL 3.3 renderer, SDL3 binding |
| `audio.zig` | sound from the game's own tag files (`ui/sound/config.xml`, `entities/sound`, `world/soundtags`): wav decoding, mixer, 3D attenuation, biome ambience, animation text-key triggers |
| `uiskin.zig` | the game's own UI panel templates (`ui/template/backs/*.xml`), drawn from its textures at any size |
| `app.zig` | the interactive app: tools, picking, undo, save/load, input driver |

Format notes live in the header comment of each reader (`bf.zig` and
`terrain.zig` document formats that had no public documentation).
