# Vendored third-party code

Everything needed to build lives in this repository; no network access or
system development packages are required.

| Directory | What | Upstream | Version | License |
|---|---|---|---|---|
| `SDL/` | SDL 3.4.18 source with a Zig build port | https://github.com/castholm/SDL (commit `88f45bb`) | 0.6.1-dev+3.4.18 | SDL: zlib. Build scripts: MIT. Per-file licenses in `SDL/LICENSES/` and `SDL/REUSE.toml` (HIDAPI is offered as GPL-3.0 OR BSD-3-Clause OR HIDAPI; we use it under BSD-3-Clause). |
| `SDL_linux_deps/` | Header-only X11, Wayland, ALSA, PulseAudio, libdrm, etc. headers, used only at compile time | https://github.com/castholm/SDL_linux_deps (commit `86b2445`) | 0.0.0 | MIT; some headers are LGPL-2.1-or-later (ALSA, glib, ibus, fribidi). They are only included at build time: SDL loads the libraries with `dlopen` at runtime, so nothing LGPL is linked into the binary. See `SDL_linux_deps/REUSE.toml`. |

## Local modifications

- `SDL/build.zig.zon`: the `sdl_linux_deps` dependency was changed from a
  fetched URL to `.path = "../SDL_linux_deps"` so the build needs no network.

## Updating

Replace the directories from upstream at a new pinned commit, reapply the
modification above, and update the table.
