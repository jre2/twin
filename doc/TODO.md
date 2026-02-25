# TODO

Prioritized backlog for the current combat prototype. Keep this file focused on concrete, shippable tasks.

## Recently Completed
- [x] Replace purely visual kickback with movement impulse kickback (player first, optional enemy support).
- [x] Improve combat feedback with hit flash and impact sparks.
- [x] Clean up asset/bootstrap setup into dedicated init and cleanup procedures.
- [x] Refactor `main()` into explicit `update_gameplay()` and `render_frame()` systems.
- [x] Audit weapon FSM transitions and move ballistic bullet emission fully under `Firing` state control.
- [x] Align cannon charge/beam/cooldown timing with current SFX durations.
- [x] Allow player movement during beam cannon cooldown (while keeping charge/beam movement lock).
- [x] Add runtime ballistic fire-mode toggle (`Immediate/Cooldown` vs `Windup/Delay`) with HUD indicator.
- [x] Make SMG sound cut immediately when trigger is released (no trailing sample tail).

## Project Direction
- [ ] Keep weapon/enemy balance data baked directly into program source.
- [ ] Do not move balance data to an external config file; Odin compile times are fast enough for direct code iteration.

## Now
- [ ] Revisit weapon FSM structure to reduce `Idle`/`Firing` coupling while preserving no-frame-delay first shot behavior.

## Next
- [ ] Add baseline enemy AI: chase player, keep spacing, and apply simple steering to avoid clumping.
- [ ] Add game flow states (`Playing`, `Dead`, `Restarting`) instead of running until window close only.
- [ ] Implement wave spawning and scaling (enemy count, speed, health, contact damage).
- [ ] Add pickup/ammo economy hooks to support longer runs.

## Later
- [ ] Add Odin tests (`@(test)`) for deterministic logic: weapon transitions, ammo accounting, and damage math.
- [ ] Add a simple pause/settings screen (audio sliders, controls legend, restart button).
- [ ] Prevent enemy-vs-enemy collision damage; keep friendly fire enabled for enemy-fired projectiles.
- [ ] Replace temporary enemy art link (`res/enemy.png -> char2.png`) with final art asset pipeline.
- [ ] Add lightweight profiling/debug overlays for entity counts, frame timings, and particle counts.
- [ ] Collision detection should use squared distance so we can avoid sqrt(), as a performance gain. Odin core library has a variant for this.
- [ ] Not enough Entity update is unified. Particles have their own collision detection but we do a generic Entity x Entity loop later. Similar for handling death and removal of entities.
- [ ] VFX updates like camera shake decay should be separated from weapon logic.
