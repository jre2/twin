# TODO

Prioritized backlog for the current combat prototype. Keep this file focused on concrete, shippable tasks.

## Now
- [ ] Not enough Entity update is unified. Particles have their own collision detection but we do a generic Entity x Entity loop later. Similar for handling death and removal of entities.
- [ ] Collision detection should use squared distance so we can avoid sqrt(), as a performance gain. Odin core library has a variant for this.
- [ ] Add lightweight profiling/debug overlays for entity counts, frame timings, and particle counts.

## Next
- [ ] Medium priority: do a full loop-style pass across the codebase; make loops more idiomatic Odin (`for x in xs` where feasible, cleaner index loops where mutation/removal requires indices).
- [ ] Add game flow states (`Playing`, `Dead`, `Restarting`) instead of running until window close only.
- [ ] Add baseline enemy AI: chase player, keep spacing, and apply simple steering to avoid clumping.
- [ ] Implement wave spawning and scaling (enemy count, speed, health, contact damage).
- [ ] Add pickup/ammo economy hooks to support longer runs.
- [ ] Prevent enemy-vs-enemy collision damage; keep friendly fire enabled for enemy-fired projectiles.
- [ ] Add a simple pause/settings screen (audio sliders, controls legend, restart button).

## Later
- [ ] Add Odin tests (`@(test)`) for deterministic logic: weapon transitions, ammo accounting, and damage math.
- [ ] Replace temporary enemy art link (`res/enemy.png -> char2.png`) with final art asset pipeline.
- [ ] Revisit weapon FSM structure to reduce `Idle`/`Firing` coupling while preserving no-frame-delay first shot behavior.

## Recently Completed
- [x] Cleaned up non-idiomatic index loops in damage/cleanup paths to idiomatic Odin `for i := ...` form.
- [x] Added reload minigame during `ClipInsert` with perfect timing that instantly completes insert.
- [x] Added perfect-reload fanfare (SFX + VFX + HUD `PERFECT CLIP` state).
- [x] VFX updates like camera shake decay are now separated from weapon logic.
- [x] Replace purely visual kickback with movement impulse kickback (player first, optional enemy support).
- [x] Improve combat feedback with hit flash and impact sparks.
- [x] Clean up asset/bootstrap setup into dedicated init and cleanup procedures.
- [x] Refactor `main()` into explicit `update_gameplay()` and `render_frame()` systems.
- [x] Audit weapon FSM transitions and move ballistic bullet emission fully under `Firing` state control.
- [x] Align cannon charge/beam/cooldown timing with current SFX durations.
- [x] Allow player movement during beam cannon cooldown (while keeping charge/beam movement lock).
- [x] Add runtime ballistic fire-mode toggle (`Immediate/Cooldown` vs `Windup/Delay`) with HUD indicator.
- [x] Make SMG sound cut immediately when trigger is released (no trailing sample tail).
