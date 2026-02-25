# Repository Guidelines

## Project Overview
- **Twin** is a 2D top-down game built with Odin and Raylib.
- The project intentionally uses a single-package layout so gameplay iteration stays fast (`src/main.odin`).

## Project Structure & Module Organization
- `src/main.odin`: Main game package and entry point (gameplay, weapons, update loop, rendering).
- `res/`: Runtime assets (textures and audio). Add assets here and wire paths in `VizDB`/`WeaponDB`.
- `bin/`: Build output directory (`twin.exe`). Run Odin build/test commands from this directory.
- `tools/`: Helper scripts for local run/watch workflows.
- `doc/`: Notes and platform resource files (icons, `.rc`, etc.).
- `doc/TODO.md`: Prioritized backlog for upcoming gameplay and tech tasks.

## Build, Test, and Development Commands
Run `odin` commands from `bin/`:
- `cd bin && odin run ../src -out:twin.exe -debug`: Run a debug build.
- `cd bin && odin build ../src -out:twin.exe -debug`: Build debug binary only.
- `cd bin && odin check ../src`: Type-check without producing a binary.
- `cd bin && odin test ../src`: Run Odin tests.
- `odinfmt -w src/main.odin` (run from repo root): Format source.
- Preferred verification order for fast iteration: `odin check` -> targeted `odin test` -> manual `odin run` smoke check for gameplay/audio/visual changes.

## Architecture
- `Entity`/`EntityType` are core world actor types (`Player`, `Enemy`, `Crosshair`) and hold gameplay-facing state.
- `VisualData`/`VizDB` contain static render and animation tuning per entity type.
- `WeaponDef` stores static tuning; `WeaponInstance` stores per-weapon runtime FSM state.
- `GameState` (`st`) is the shared mutable runtime state for gameplay, rendering, audio triggers, and debug metrics.
- The frame pipeline follows a standard input → update → render loop.
- Keep input collection and gameplay state mutation in update; keep rendering as a separate pass that consumes state.
- Movement/friction uses Doom-style per-tick friction converted and scaled for frame-rate-independent behavior.

## Coding Style & Naming Conventions
- Use spaces (4-space indent), not tabs (`.editorconfig`, `odinfmt.json`).
- `odinfmt` config is authoritative (`character_width=200`, `sort_includes`, `inline_single_stmt_case`).
- Keep naming consistent with surrounding code in `src/main.odin`.
- Types/enums use `PascalCase` (example: `GameState`, `WeaponType`).
- Procedures/locals may use snake_case where already established.
- Prefer scoped blocks (`{ // Camera ... }`) to group related logic inside larger procedures.
- Avoid one-off helper procedures when scoped blocks keep related logic easier to maintain in-place.
- Keep static data tables (`VizDB`, `WeaponDB`) centralized and update them atomically with gameplay changes.
- Keep game data (for example, weapon/enemy balance) baked into source code, not external config files.
- `#+feature dynamic-literals` is enabled in `src/main.odin`.

## Testing Guidelines
- Prefer Odin built-in tests with `@(test)` procedures; run with `cd bin && odin test ../src`.
- Focus tests on deterministic gameplay logic (state transitions, damage math, reload/switch timing).
- Use descriptive test names that state behavior, e.g., `weapon_switch_blocks_fire`.

## Commit & Pull Request Guidelines
- Follow history style: `<scope>: <concise summary>` (examples: `fix: ...`, `weapons: ...`, `doc: ...`, `res: ...`).
- Keep commits focused; separate gameplay logic, assets, and docs when practical.
- PRs should state what changed and why.
- Include commands run (`odin check`, `odin test`, build/run smoke check).
- Add screenshot/video for visual or audio-impacting changes.

## Workflow Notes
- For gameplay tasks, default to one task at a time and pause for playtest feedback before starting the next.
- Update `doc/TODO.md` after each task (status/priority changes and Recently Completed entries when done).
- Keep `AGENTS.md` and `CLAUDE.md` aligned; when one changes, mirror the same repo-level guidance in the other.

## Tooling
- Formatter: `odinfmt` (configured in `odinfmt.json`).
