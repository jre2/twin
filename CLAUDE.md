# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Twin** is a 2D top-down game written in [Odin](https://odin-lang.org/), using [Raylib](https://www.raylib.com/) for rendering. It's a single-package project — all source lives in `src/main.odin`.

## Commands

All build/run commands must be executed from the `bin/` directory. The output binary is `bin/twin.exe`.

**Run (debug):**
```sh
cd bin && odin run ../src -out:twin.exe -debug
```

**Build only (debug):**
```sh
cd bin && odin build ../src -out:twin.exe -debug
```

**Build (release):**
```sh
cd bin && odin build ../src -out:twin.exe
```

**Type-check without building:**
```sh
cd bin && odin check ../src
```

**Run tests:**
```sh
cd bin && odin test ../src
```

**Format source:**
```sh
odinfmt -w src/main.odin
```

The `tools/run.sh` script is a convenience wrapper that handles the `cd` automatically.

## Architecture

Everything is in `src/main.odin` as `package main`. The structure:

- **`Entity`** — central data type with `id`, `type` (`EntityType` enum), `pos`/`vel`/`radius`, `aim_angle`, `max_vel`, `accel`
- **`EntityType`** — `Player`, `Enemy`, `Crosshair`
- **`VisualData`** / **`VizDB`** — static lookup table (`[EntityType]VisualData`) mapping entity types to textures and animation parameters (bob, squash/stretch). All visual configuration lives here.
- **`GameState`** (`st`) — global mutable state: render size, DPI scaling, mouse pos, camera, and the `entities` dynamic array
- **`main()`** — single game loop: input → physics → render

Physics uses Doom-style per-tick friction applied continuously via `math.pow(friction_per_tick, 35.0)` to convert to per-second values, then scaled by `GetFrameTime()` for frame-rate independence.

## Code Style

- 4-space indentation (spaces, not tabs — despite Odin convention)
- `odinfmt` config: 200-char line width, `sort_includes`, `inline_single_stmt_case`
- Scoped blocks (`{ // Camera ... }`) are used to visually group related logic within `main()`
- `#+feature dynamic-literals` is enabled at the top of the file

## Tooling

- **Language server:** `ols` (Odin Language Server) — configured in `ols.json`
- **Formatter:** `odinfmt` — configured in `odinfmt.json`
- **Watch mode:** `tools/watch.sh` uses `inotifywait` (Linux only) to re-run on `.odin` file changes
