# TODO

Prioritized backlog for the current combat prototype. Keep this file focused on concrete, shippable tasks.

## Now
- [ ] Add game flow states (`Playing`, `Dead`, `Restarting`) instead of running until window close only.
- [ ] Add baseline enemy AI: chase player, keep spacing, and apply simple steering to avoid clumping.
- [ ] Store `dt` on `GameState` once per frame and use `st.dt` everywhere instead of repeated `GetFrameTime()` calls.
- [ ] Add focused regression tests for weapon/reload transitions (especially `ClipDrop`/`ClipInsert`, perfect timing path, and fire-mode toggle behavior).
- [ ] Implement a real gameplay effect for `perfect_reload_clip` (currently HUD/state only).
- [ ] Empty-clip auto-reload: when firing empties the clip, auto-chain into `ClipDrop` → `ClipInsert`.

## Next
- [ ] Implement wave spawning and scaling (enemy count, speed, health, contact damage).
- [ ] Player death VFX and respawn animation (depends on game flow states).
- [ ] Finalize the unified damage/collision/cleanup section so particle and entity damage rules stay co-located and evolve together.
- [ ] Prevent enemy-vs-enemy collision damage; keep friendly fire enabled for enemy-fired projectiles.
- [ ] Enemy movement variety (ranged strafers, melee rushers) once baseline chase AI exists.
- [ ] Damage number popups (floating text particles on hit showing damage dealt).
- [ ] Add pickup/ammo economy hooks to support longer runs.
- [ ] Add a simple pause/settings screen (audio sliders, controls legend, restart button), including controls for toggles like debug overlay and fire mode.
- [ ] Full loop-style pass across the codebase; make loops more idiomatic Odin (`for x in xs` where feasible, cleaner index loops where mutation/removal requires indices).

## Later
- [ ] Expand test coverage beyond FSM regressions (ammo economy, wave scaling math, and collision edge cases).
- [ ] Replace temporary enemy art link (`res/enemy.png -> char2.png`) with final art asset pipeline.
- [ ] Revisit weapon FSM structure to reduce `Idle`/`Firing` coupling while preserving no-frame-delay first shot behavior.
- [ ] Consider fully separating Entities and Particles. Bullets become Entities, particles have no collision, etc.
- [ ] Screen-space HUD refactor: move all HUD drawing into a dedicated `render_hud()` proc.
- [ ] Entity pooling / free-list for enemies to avoid allocation churn at higher enemy counts.

## Recently Completed
- [x] Added lightweight debug/profiling overlay (entity/enemy/particle counts + frame/update/render ms) with `U` toggle.
- [x] Collision checks now use `linalg.length2` squared-distance comparisons (no sqrt in hot paths).
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
