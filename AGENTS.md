# Repository Guidelines

## Project Structure & Module Organization
- `src/main.odin`: Single `package main` entry point with gameplay, entity logic, weapons, and render loop.
- `res/`: Runtime assets (textures and audio). Add new assets here and wire paths in `VizDB`/`WeaponDB`.
- `bin/`: Build output directory (`twin.exe`). Run Odin build/test commands from this folder.
- `tools/`: Helper scripts for local run/watch workflows.
- `doc/`: Notes and platform resource files (icons, `.rc`, etc.).

## Build, Test, and Development Commands
- `cd bin && odin run ../src -out:twin.exe -debug`: Run a debug build.
- `cd bin && odin build ../src -out:twin.exe -debug`: Build debug binary only.
- `cd bin && odin build ../src -out:twin.exe`: Build release binary.
- `cd bin && odin check ../src`: Type-check without producing a binary.
- `cd bin && odin test ../src`: Run Odin tests.
- `./tools/run.sh`: Convenience wrapper for debug run.
- `./tools/watch.sh`: Re-run on `.odin` file changes (requires `inotifywait`, Linux-focused).

## Coding Style & Naming Conventions
- Use spaces (4-space indent), not tabs (`.editorconfig`, `odinfmt.json`).
- Format before committing: `odinfmt -w src/main.odin`.
- Keep naming consistent with surrounding code in `src/main.odin`.
- Types/enums use `PascalCase` (example: `GameState`, `WeaponType`).
- Procedures/locals may use snake_case where already established.
- Keep static data tables (`VizDB`, `WeaponDB`) centralized and update them atomically with related gameplay changes.
- Keep game data (eg. weapon/enemy balance) baked into game source code rather than external config files. Odin compile times are fast

## Testing Guidelines
- Prefer Odin built-in tests with `@(test)` procedures and run via `cd bin && odin test ../src`.
- Focus tests on deterministic gameplay logic (state transitions, damage math, reload/switch timing).
- Use descriptive test names that state behavior, e.g., `weapon_switch_blocks_fire`.

## Commit & Pull Request Guidelines
- Follow repository history style: `<scope>: <concise summary>` (examples: `fix: ...`, `weapons: ...`, `doc: ...`, `res: ...`).
- Keep commits focused; separate gameplay logic, assets, and docs when practical.
- PRs should include what changed and why.
- Include commands run (`odin check`, `odin test`, build/run smoke check).
- Add screenshot/video for visual or audio-impacting changes.
