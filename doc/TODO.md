# TODO

Prioritized backlog for the current combat prototype. Keep this file focused on concrete, shippable tasks.

## Now
- [ ] Resolve weapon ownership source-of-truth (`starting_weapons` vs `owned_weapons`) and remove redundant ownership checks from weapon switch/fire logic.
- [ ] Define and enforce one ownership rule for empty weapons (owned-but-empty vs unavailable), including Strafer rifle/tesla fallback behavior.
- [ ] Implement wave spawning and scaling (enemy count, speed, health, contact damage).
- [ ] Review enemy sounds and whether toggles like `auto_reload`/fire mode should live per-entity or in global game state.
- [ ] Tune new enemy archetype balance (Chaser/Rusher/Strafer movement constants, fire ranges, and starting weapon mix/pacing) after playtesting.

## Next
- [ ] Add game flow states (`Playing`, `Dead`, `Restarting`) instead of running until window close only.
- [ ] Player death VFX and respawn animation (depends on game flow states).
- [ ] Damage number popups (floating text particles on hit showing damage dealt).
- [ ] Empty-clip auto-reload: when firing empties the clip, auto-chain into `ClipDrop` → `ClipInsert`.
- [ ] Implement a real gameplay effect for `perfect_reload_clip` (currently HUD/state only).
- [ ] Unify beam damage with the shared damage/collision pipeline so bullets, beam, and contact hits use consistent rules/feedback and remain co-located.
- [ ] Add pickup/ammo economy hooks to support longer runs.
- [ ] Add a simple pause/settings screen (audio sliders, controls legend, restart button), including controls for toggles like debug overlay and fire mode.
- [ ] Full loop-style pass across the codebase; make loops more idiomatic Odin (`for x in xs` where feasible, cleaner index loops where mutation/removal requires indices).
- [ ] Add AI regression tests for enemy behavior (rusher dash state transitions/trigger conditions and strafer orbit-range + weapon-switch decisions).

## Later
- [ ] Expand test coverage beyond FSM regressions (ammo economy, wave scaling math, and collision edge cases).
- [ ] Replace temporary enemy art link (`res/enemy.png -> char2.png`) with final art asset pipeline.
- [ ] Revisit weapon FSM structure to reduce `Idle`/`Firing` coupling while preserving no-frame-delay first shot behavior.
- [ ] Consider fully separating Entities and Particles. Bullets become Entities, particles have no collision, etc.
- [ ] Screen-space HUD refactor: move all HUD drawing into a dedicated `render_hud()` proc.
- [ ] Entity pooling / free-list for enemies to avoid allocation churn at higher enemy counts.

## Recently Completed
- [x] Standardized gameplay timing to one `dt := GetFrameTime()` read per update step (frame-ms timing remains separate for debug overlay).
- [x] Unified enemy radii across archetypes so differentiation is driven by tint/behavior instead of size differences.
- [x] Reworked movement into separate volitional and impulse velocity channels, so kickback/explosions/dashes are no longer constrained by normal movement speed caps.
- [x] Improved rusher dash behavior (smarter charge timing/targeting, stronger dash travel, and clearer dash-state VFX/debug feedback).
- [x] Implemented baseline enemy AI with steering/separation, shared weapon FSM usage, and data-driven EnemyDB spawning.
- [x] Added enemy movement variety: Chaser pursuit, Rusher charge/dash FSM, and Strafer orbit/range behavior with weapon switching.
- [x] Prevented enemy-vs-enemy contact damage while keeping enemy projectile friendly fire vs player.
- [x] Added regression tests for weapon/reload FSM: extracted `calc_reload_action`, `calc_clip_insert_ammo`, `check_reload_window` as testable procs with 12 tests covering state entry, ammo math, reload decisions, and perfect reload window.
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
