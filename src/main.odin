#+feature dynamic-literals
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import rl "vendor:raylib"

// ── Compile-Time Constants ─────────────────────────────────────────────────────

DEBUG_MEMORY :: true

FrictionGroundPerTick :: 0.90625 // Doom style, per 35hz tic, applied to current speed
FrictionGroundPerSec: f32 = math.pow(f32(FrictionGroundPerTick), 35.0)
FrictionSlowdownAir :: 0.9727 // doom style, per 35hz tic, applied to current speed
FrictionAirPerSec: f32 = math.pow(f32(FrictionSlowdownAir), 35.0)
CannonChargeSfxSecs :: 4.728 // measured via afinfo
CannonFireSfxSecs :: 7.752 // measured via afinfo
ReloadMiniWindowMinPermille: i32 = 140
ReloadMiniWindowMaxPermille: i32 = 220
ReloadMiniWindowPadPermille: i32 = 80
PerfectReloadFxSecs: f32 = 0.38
PerfectReloadSfxPath :: "res/reload_perfect.mp3"

// ── Types ──────────────────────────────────────────────────────────────────────

Vec2 :: [2]f32
Vec2i :: [2]i32
EntityType :: enum {
    Player,
    Enemy,
    Crosshair,
}
EnemyType :: enum {
    Chaser,
    Rusher,
    Strafer,
}
EnemyAIState :: enum {
    Idle,
    Charging,
    Dashing,
    Cooldown,
}
WeaponType :: enum {
    SMG,
    Rifle,
    Tesla,
    Cannon,
}
WeaponState :: enum {
    Idle,
    Switching, // equipping a new weapon
    Firing, // just fired, waiting for fire_interval to elapse
    ClipDrop, // ejecting current clip
    ClipInsert, // inserting new clip from reserve
    Charging, // cannon: holding LMB to charge
    BeamActive, // cannon: beam firing
    Cooldown, // cannon: post-beam cooldown
}
ReloadAction :: enum {
    None,
    DropClip,
    InsertClip,
}
BallisticFireMode :: enum {
    ImmediateCooldown, // emit immediately; fire_interval gates next shot
    WindupDelay, // emit only after fire_interval delay
}
WeaponDef :: struct {
    name:              string,
    sound_path:        string,
    charge_sound_path: string,
    sound:             rl.Sound, // filled at init
    charge_sound:      rl.Sound, // filled at init (cannon only)
    fire_interval:     f32, // seconds between shots; 0 = not applicable (cannon)
    clip_size:         int,
    max_ammo:          int,
    bullet_damage:     f32,
    bullet_speed:      f32,
    bullet_spread:     f32, // half-angle radians
    bullet_radius:     f32,
    bullet_color:      rl.Color,
    kickback_impulse:  f32,
    shake_impulse:     f32,
    flash_size:        f32, // spatial size; 0 = arc effect (Tesla)
    flash_duration:    f32, // seconds; 0 = no flash
    charge_time:       f32, // cannon: seconds to full charge
    cooldown_time:     f32, // cannon: seconds cooldown after beam
    beam_half_width:   f32, // cannon: beam half-width in world units
    beam_damage:       f32, // cannon: damage/sec to entities in beam
    beam_duration:     f32, // cannon: seconds beam stays active
    switch_time:       f32, // seconds to equip this weapon
    clip_drop_time:    f32, // seconds to eject clip
    clip_insert_time:  f32, // seconds to load a new clip
}
EntityDef :: struct {
    type:                   EntityType,
    enemy_type:             EnemyType, // used when `type == .Enemy`
    radius:                 f32,
    move_speed:             f32,
    move_accel:             f32,
    health:                 f32,
    contact_damage:         f32,
    tint:                   rl.Color, // used when `type == .Enemy`
    separation_str:         f32,
    auto_reload:            bool,
    ballistic_fire_mode:    BallisticFireMode,
    starting_active_weapon: WeaponType,
    starting_weapons:       bit_set[WeaponType], // spawn-only ownership seed
    charge_telegraph:       f32,
    dash_speed:             f32,
    dash_duration:          f32,
    dash_cooldown:          f32,
    preferred_dist:         f32,
    strafe_speed:           f32,
}
EnemySpawnBatch :: struct {
    enemy_type: EnemyType,
    count:      int,
}
VisualData :: struct {
    texture:          rl.Texture2D,
    tex_path:         string,
    tex_scale:        Vec2, // to normalize texture to appropriate size
    bob_speed:        f32,
    bob_magnitude:    f32,
    squash_speed:     f32,
    squash_magnitude: f32,
    squash_baseline:  f32,
}
WeaponInput :: struct {
    fire_held:    bool, // LMB held (auto-fire, cannon charge)
    fire_pressed: bool, // LMB just pressed (rifle single-shot)
    reload:       bool, // R pressed
    switch_to:    Maybe(WeaponType),
}
WeaponInstance :: struct {
    ammo_in_clip:               int,
    ammo_reserve:               int,
    state:                      WeaponState,
    state_timer:                f32, // seconds elapsed in current state
    state_duration:             f32, // total duration of current state (set on entry)
    beam_angle:                 f32, // cannon: locked aim angle during beam
    charge_sfx_playing:         bool, // cannon: whether charge sound is playing
    pending_weapon:             WeaponType, // target weapon during Switching state
    fire_on_firing_enter:       bool, // immediate mode: fire once on first .Firing frame
    fire_queued:                bool, // windup mode: latches a pending shot request
    reload_window_start:        f32, // clip insert minigame timing window [0..1]
    reload_window_end:          f32, // clip insert minigame timing window [0..1]
    reload_window_spent:        bool, // whether player already attempted the minigame this cycle
    reload_perfect_this_insert: bool, // whether current clip insert got a perfect timing hit
    perfect_reload_clip:        bool, // whether the currently loaded clip was perfectly reloaded
    muzzle_flash_timer:         f32, // visual only: decays independently
}
Particle :: struct {
    pos:      Vec2,
    vel:      Vec2,
    radius:   f32,
    damage:   f32, // 0 = visual only
    color:    rl.Color,
    age:      f32,
    max_age:  f32,
    friendly: bool, // true = player-fired (hits enemies), false = enemy-fired (hits player)
}
Entity :: struct {
    id:                   int,
    type:                 EntityType,
    pos:                  Vec2,
    move_vel:             Vec2, // volitional movement only (input/AI steering)
    impulse_vel:          Vec2, // non-volitional movement (kickback, explosions, dashes)
    radius:               f32,
    aim_angle:            f32, // degrees
    move_speed:           f32, // max speed for move_vel only
    move_accel:           f32, // responsiveness multiplier for move_vel acceleration
    health:               f32,
    max_health:           f32,
    damage:               f32, // contact damage per second
    hit_flash:            f32, // seconds remaining for damage feedback
    weapon_move_locked:   bool, // derived from active weapon state
    ai_move_locked:       bool, // set by AI behavior this frame
    cant_volitional_move: bool, // final movement lock; momentum and knockback are not affected
    // Weapons (shared between player and enemies)
    active_weapon:        WeaponType,
    weapons:              [WeaponType]WeaponInstance,
    ballistic_fire_mode:  BallisticFireMode,
    auto_reload:          bool,
    owned_weapons:        bit_set[WeaponType], // runtime ownership source-of-truth
    // Enemy AI
    enemy_type:           EnemyType,
    ai_state:             EnemyAIState,
    ai_timer:             f32,
}
GameState :: struct {
    render_size:             Vec2,
    dpi_scaling:             Vec2,
    mouse_pos:               Vec2, // screen space
    camera:                  rl.Camera2D,
    entities:                [dynamic]Entity,
    player:                  ^Entity,
    crosshair:               ^Entity,
    sprite_aim_rotate:       bool,
    flip_by_aim:             bool, // true = flip sprite based on aim direction; false = flip based on movement
    particles:               [dynamic]Particle,
    camera_shake:            f32,
    perfect_reload_fx_timer: f32,
    show_debug_overlay:      bool,
    debug_update_ms:         f32,
    debug_render_ms:         f32,
    debug_frame_ms:          f32,
}


// ── Static Data ────────────────────────────────────────────────────────────────

WeaponDB := [WeaponType]WeaponDef {
    .SMG = WeaponDef {
        name = "SMG",
        sound_path = "res/smg.mp3",
        fire_interval = 0.065,
        clip_size = 30,
        max_ammo = 180,
        bullet_damage = 5,
        bullet_speed = 800,
        bullet_spread = 0.4,
        bullet_radius = 4,
        bullet_color = rl.YELLOW,
        kickback_impulse = 7,
        shake_impulse = 6,
        flash_size = 24,
        flash_duration = 0.05,
        switch_time = 0.3,
        clip_drop_time = 0.3,
        clip_insert_time = 0.8,
    },
    .Rifle = WeaponDef {
        name = "Rifle",
        sound_path = "res/rifle.mp3",
        fire_interval = 0.3,
        clip_size = 10,
        max_ammo = 60,
        bullet_damage = 25,
        bullet_speed = 1200,
        bullet_spread = 0.15,
        bullet_radius = 5,
        bullet_color = rl.RAYWHITE,
        kickback_impulse = 33,
        shake_impulse = 21,
        flash_size = 58,
        flash_duration = 0.12,
        switch_time = 0.4,
        clip_drop_time = 0.3,
        clip_insert_time = 1.0,
    },
    .Tesla = WeaponDef {
        name = "Tesla Gun",
        sound_path = "res/tesla_gun.mp3",
        fire_interval = 0.2,
        clip_size = 20,
        max_ammo = 100,
        bullet_damage = 15,
        bullet_speed = 1000,
        bullet_spread = 0.25,
        bullet_radius = 4,
        bullet_color = rl.SKYBLUE,
        kickback_impulse = 12,
        shake_impulse = 10,
        flash_size = 0,
        flash_duration = 0.1,
        switch_time = 0.35,
        clip_drop_time = 0.3,
        clip_insert_time = 0.7,
    },
    .Cannon = WeaponDef {
        name              = "Particle Cannon",
        sound_path        = "res/cannon_fire.mp3",
        charge_sound_path = "res/cannon_charge.mp3",
        clip_size         = 3,
        max_ammo          = 9,
        kickback_impulse  = 47,
        shake_impulse     = 55,
        // Keep timings close to SFX envelope: charge ~= charge SFX, beam+cooldown ~= fire SFX.
        charge_time       = CannonChargeSfxSecs *
        0.98,
        cooldown_time     = CannonFireSfxSecs *
        0.35,
        beam_half_width   = 60,
        beam_damage       = 300,
        beam_duration     = CannonFireSfxSecs *
        0.63,
        switch_time       = 0.6,
        clip_drop_time    = 0.4,
        clip_insert_time  = 1.6,
    },
}
PlayerDB := EntityDef {
    type                   = .Player,
    radius                 = 50,
    move_speed             = 700,
    move_accel             = 1.0,
    health                 = 100,
    ballistic_fire_mode    = .ImmediateCooldown,
    auto_reload            = false,
    starting_active_weapon = .SMG,
    starting_weapons       = {.SMG, .Rifle, .Tesla, .Cannon},
}
CrosshairDB := EntityDef {
    type   = .Crosshair,
    radius = 20,
}
EnemyDB := [EnemyType]EntityDef {
    .Chaser = EntityDef {
        type = .Enemy,
        enemy_type = .Chaser,
        move_speed = 120,
        move_accel = 1.2,
        health = 50,
        contact_damage = 10,
        radius = 50,
        tint = rl.RED,
        separation_str = 120,
        auto_reload = true,
        ballistic_fire_mode = .ImmediateCooldown,
        starting_active_weapon = .SMG,
        starting_weapons = {.SMG},
    },
    .Rusher = EntityDef {
        type = .Enemy,
        enemy_type = .Rusher,
        move_speed = 80,
        move_accel = 1.1,
        health = 30,
        contact_damage = 15,
        radius = 50,
        tint = rl.ORANGE,
        separation_str = 100,
        auto_reload = true,
        ballistic_fire_mode = .ImmediateCooldown,
        starting_active_weapon = .SMG,
        starting_weapons = {.SMG},
        charge_telegraph = 0.6,
        dash_speed = 560,
        dash_duration = 0.30,
        dash_cooldown = 1.1,
    },
    .Strafer = EntityDef {
        type = .Enemy,
        enemy_type = .Strafer,
        move_speed = 95,
        move_accel = 1.2,
        health = 35,
        contact_damage = 3,
        radius = 50,
        tint = rl.PURPLE,
        separation_str = 110,
        auto_reload = true,
        ballistic_fire_mode = .ImmediateCooldown,
        starting_active_weapon = .Rifle,
        starting_weapons = {.Rifle, .Tesla},
        preferred_dist = 350,
        strafe_speed = 100,
    },
}
EnemySpawnPlan := [3]EnemySpawnBatch{EnemySpawnBatch{enemy_type = .Chaser, count = 5}, EnemySpawnBatch{enemy_type = .Rusher, count = 3}, EnemySpawnBatch{enemy_type = .Strafer, count = 2}}
VizDB := [EntityType]VisualData {
    .Player = VisualData{tex_path = "res/char3.png", tex_scale = Vec2{1, 1} / 300, bob_speed = 15.0, bob_magnitude = 5.0, squash_speed = 2.0, squash_magnitude = 0.25, squash_baseline = 0.9},
    .Enemy = VisualData{tex_path = "res/enemy.png", tex_scale = Vec2{1, 1} / 300, bob_speed = 10.0, bob_magnitude = 4.0, squash_speed = 1.5, squash_magnitude = 0.2, squash_baseline = 0.8},
    .Crosshair = VisualData{tex_path = "res/crosshair.png", tex_scale = Vec2{1, 1} / 200, bob_speed = 0.0, bob_magnitude = 0.0, squash_speed = 0.0, squash_magnitude = 0.0, squash_baseline = 0.0},
}

// ── Globals ────────────────────────────────────────────────────────────────────

st := GameState {
    camera = rl.Camera2D{zoom = 1.0},
    flip_by_aim = true,
    show_debug_overlay = false,
}
PerfectReloadSfx: rl.Sound

// ── Init / Cleanup ─────────────────────────────────────────────────────────────

init_assets :: proc() {
    for &viz in VizDB {
        path := strings.clone_to_cstring(viz.tex_path, context.temp_allocator)
        viz.texture = rl.LoadTexture(path)
    }
    for &wep in WeaponDB {
        if wep.sound_path != "" {
            wep.sound = rl.LoadSound(strings.clone_to_cstring(wep.sound_path, context.temp_allocator))
        }
        if wep.charge_sound_path != "" {
            wep.charge_sound = rl.LoadSound(strings.clone_to_cstring(wep.charge_sound_path, context.temp_allocator))
        }
    }
    PerfectReloadSfx = rl.LoadSound(strings.clone_to_cstring(PerfectReloadSfxPath, context.temp_allocator))
}

init_game_state :: proc() {
    spawn_entity :: proc(entity_def: EntityDef, pos: Vec2 = {}) {
        e := Entity {
            id                  = len(st.entities),
            type                = entity_def.type,
            enemy_type          = entity_def.enemy_type,
            radius              = entity_def.radius,
            move_speed          = entity_def.move_speed,
            move_accel          = entity_def.move_accel,
            health              = entity_def.health,
            max_health          = entity_def.health,
            damage              = entity_def.contact_damage,
            active_weapon       = entity_def.starting_active_weapon,
            owned_weapons       = entity_def.starting_weapons,
            auto_reload         = entity_def.auto_reload,
            ballistic_fire_mode = entity_def.ballistic_fire_mode,
        }
        for w in WeaponType {
            if w not_in e.owned_weapons {continue}
            wpn_def := WeaponDB[w]
            e.weapons[w] = WeaponInstance {
                ammo_in_clip = wpn_def.clip_size,
                ammo_reserve = max(0, wpn_def.max_ammo - wpn_def.clip_size),
            }
        }
        e.pos = pos
        append(&st.entities, e)
    }
    random_enemy_spawn_pos :: proc() -> Vec2 {
        return Vec2{f32(rl.GetRandomValue(-900, 900)), f32(rl.GetRandomValue(-500, 500))}
    }

    spawn_entity(PlayerDB)
    spawn_entity(CrosshairDB)
    for batch in EnemySpawnPlan {
        enemy_def := EnemyDB[batch.enemy_type]
        for _ in 0 ..< batch.count {
            spawn_entity(enemy_def, random_enemy_spawn_pos())
        }
    }
}

cleanup_resources :: proc() {
    delete(st.entities)
    delete(st.particles)
    for &viz in VizDB {rl.UnloadTexture(viz.texture)}
    for &wep in WeaponDB {
        rl.UnloadSound(wep.sound)
        rl.UnloadSound(wep.charge_sound)
    }
    rl.UnloadSound(PerfectReloadSfx)
    rl.CloseAudioDevice()
    rl.CloseWindow()
}

// ── Shared Helpers ─────────────────────────────────────────────────────────────

vec2 :: proc(v: Vec2i) -> Vec2 {return Vec2{f32(v.x), f32(v.y)}}

draw_text :: proc(pos: Vec2, size: f32, fmtstring: string, args: ..any) {
    s := fmt.tprintf(fmtstring, ..args)
    cs := strings.clone_to_cstring(s, context.temp_allocator)
    rl.DrawText(cs, i32(pos.x), i32(pos.y), i32(size), rl.RAYWHITE)
}

update_weapon_move_lock :: proc(entity: ^Entity) {
    state := entity.weapons[entity.active_weapon].state
    entity.weapon_move_locked = state != .Idle && state != .Cooldown
}

resolve_volitional_movement_lock :: proc(entity: ^Entity) {
    entity.cant_volitional_move = entity.weapon_move_locked || entity.ai_move_locked
}

// ── Weapon Systems ─────────────────────────────────────────────────────────────

enter_state :: proc(inst: ^WeaponInstance, new_state: WeaponState, duration: f32) {
    inst.state = new_state
    inst.state_timer = 0
    inst.state_duration = duration
}

enter_clip_insert :: proc(wpn_inst: ^WeaponInstance, wpn_def: WeaponDef) {
    window_w := rl.GetRandomValue(ReloadMiniWindowMinPermille, ReloadMiniWindowMaxPermille)
    start_min := ReloadMiniWindowPadPermille
    start_max := 1000 - ReloadMiniWindowPadPermille - window_w
    if start_max < start_min {start_max = start_min}
    window_start := rl.GetRandomValue(start_min, start_max)
    wpn_inst.reload_window_start = f32(window_start) / 1000.0
    wpn_inst.reload_window_end = f32(window_start + window_w) / 1000.0
    wpn_inst.reload_window_spent = false
    wpn_inst.reload_perfect_this_insert = false
    enter_state(wpn_inst, .ClipInsert, wpn_def.clip_insert_time)
}

enter_clip_drop :: proc(wpn_inst: ^WeaponInstance, wpn_def: WeaponDef) {
    enter_state(wpn_inst, .ClipDrop, wpn_def.clip_drop_time)
}

calc_reload_action :: proc(ammo_in_clip: int, ammo_reserve: int) -> ReloadAction {
    if ammo_in_clip > 0 {return .DropClip}
    if ammo_reserve > 0 {return .InsertClip}
    return .None
}

calc_clip_insert_ammo :: proc(clip_size: int, ammo_reserve: int) -> (new_clip: int, new_reserve: int) {
    new_clip = min(clip_size, ammo_reserve)
    new_reserve = ammo_reserve - new_clip
    return
}

check_reload_window :: proc(cursor: f32, window_start: f32, window_end: f32) -> bool {
    return cursor >= window_start && cursor <= window_end
}

apply_kickback :: proc(entity: ^Entity, aim_rad: f32, impulse: f32) {
    dir := Vec2{math.cos(aim_rad), math.sin(aim_rad)}
    entity.impulse_vel -= dir * impulse * 8.0
}

spawn_hit_sparks :: proc(origin: Vec2, color: rl.Color, count: int = 5) {
    for _ in 0 ..< count {
        ang := f32(rl.GetRandomValue(0, 6283)) / 1000.0
        speed := f32(rl.GetRandomValue(180, 520))
        vel := Vec2{math.cos(ang), math.sin(ang)} * speed
        append(&st.particles, Particle{pos = origin, vel = vel, radius = f32(rl.GetRandomValue(2, 4)), color = color, max_age = f32(rl.GetRandomValue(8, 18)) / 100.0})
    }
}

fire_bullet :: proc(entity: ^Entity, wpn_inst: ^WeaponInstance, wpn_def: WeaponDef, muzzle_pos: Vec2, aim_rad: f32) {
    spread := aim_rad + (f32(rl.GetRandomValue(-1000, 1000)) / 1000.0) * wpn_def.bullet_spread
    vel := Vec2{math.cos(spread), math.sin(spread)} * wpn_def.bullet_speed
    friendly := entity.type == .Player
    append(&st.particles, Particle{pos = muzzle_pos, vel = vel, radius = wpn_def.bullet_radius, damage = wpn_def.bullet_damage, color = wpn_def.bullet_color, max_age = 3.0, friendly = friendly})
    wpn_inst.ammo_in_clip -= 1
    apply_kickback(entity, aim_rad, wpn_def.kickback_impulse)
    wpn_inst.muzzle_flash_timer = wpn_def.flash_duration
    shake := wpn_def.shake_impulse if entity.type == .Player else wpn_def.shake_impulse * 0.05
    st.camera_shake = max(st.camera_shake, shake)
    rl.PlaySound(wpn_def.sound)
}

process_ballistic_firing_state :: proc(entity: ^Entity, wpn_inst: ^WeaponInstance, wpn_def: WeaponDef, muzzle_pos: Vec2, aim_rad: f32, input: WeaponInput) {
    if wpn_inst.state != .Firing {
        return
    }

    fire_on_entry := wpn_inst.fire_on_firing_enter
    if fire_on_entry {
        wpn_inst.fire_on_firing_enter = false
    } else if wpn_inst.state_timer < wpn_inst.state_duration {
        return
    }

    fired := false
    switch entity.active_weapon {
    case .SMG, .Tesla:
        can_fire := input.fire_held || fire_on_entry if entity.ballistic_fire_mode == .ImmediateCooldown else (wpn_inst.fire_queued || input.fire_held)
        if can_fire && wpn_inst.ammo_in_clip > 0 {
            fire_bullet(entity, wpn_inst, wpn_def, muzzle_pos, aim_rad)
            wpn_inst.state_timer = 0
            wpn_inst.state_duration = wpn_def.fire_interval
            wpn_inst.fire_queued = false
            fired = true
        }
    case .Rifle:
        wants_rifle_fire := input.fire_pressed || fire_on_entry
        can_fire := wants_rifle_fire if entity.ballistic_fire_mode == .ImmediateCooldown else wpn_inst.fire_queued
        if can_fire && wpn_inst.ammo_in_clip > 0 {
            fire_bullet(entity, wpn_inst, wpn_def, muzzle_pos, aim_rad)
            wpn_inst.state_timer = 0
            wpn_inst.state_duration = wpn_def.fire_interval
            wpn_inst.fire_queued = false
            fired = true
        }
    case .Cannon:
    }

    if !fired {
        wpn_inst.fire_queued = false
        enter_state(wpn_inst, .Idle, 0)
    }
}

update_entity_weapons :: proc(entity: ^Entity, input: WeaponInput, dt: f32) {
    spawn_perfect_reload_fanfare :: proc(origin: Vec2) {
        for i in 0 ..< 18 {
            ang := math.to_radians(f32(i) * (360.0 / 18.0)) + f32(rl.GetRandomValue(-120, 120)) / 1000.0
            speed := f32(rl.GetRandomValue(280, 620))
            vel := Vec2{math.cos(ang), math.sin(ang)} * speed
            col := rl.YELLOW if i % 2 == 0 else rl.LIME
            append(&st.particles, Particle{pos = origin, vel = vel, radius = f32(rl.GetRandomValue(3, 6)), color = col, max_age = f32(rl.GetRandomValue(22, 55)) / 100.0})
        }
    }

    wpn_def := WeaponDB[entity.active_weapon]
    wpn_inst := &entity.weapons[entity.active_weapon]

    aim_rad := math.to_radians(entity.aim_angle)
    aim_dir := Vec2{math.cos(aim_rad), math.sin(aim_rad)}
    muzzle_pos := entity.pos + aim_dir * (entity.radius + 15)

    is_player := entity.type == .Player

    wpn_inst.state_timer += dt

    switch wpn_inst.state {
    case .Idle: // Weapon switch
            if w, ok := input.switch_to.?; ok && w != entity.active_weapon && w in entity.owned_weapons {
                wpn_inst.pending_weapon = w
                enter_state(wpn_inst, .Switching, wpn_def.switch_time)
            } else if input.reload {
                switch calc_reload_action(wpn_inst.ammo_in_clip, wpn_inst.ammo_reserve) {
                case .DropClip: enter_clip_drop(wpn_inst, wpn_def)
                case .InsertClip: enter_clip_insert(wpn_inst, wpn_def)
                case .None:
                }
            } else {
                switch entity.active_weapon {
                case .SMG, .Tesla, .Rifle:
                    wants_to_fire := input.fire_held if entity.active_weapon != .Rifle else input.fire_pressed
                    if wants_to_fire && wpn_inst.ammo_in_clip > 0 {
                        enter_state(wpn_inst, .Firing, wpn_def.fire_interval)
                        wpn_inst.fire_on_firing_enter = entity.ballistic_fire_mode == .ImmediateCooldown
                        wpn_inst.fire_queued = entity.ballistic_fire_mode == .WindupDelay
                        // Fire immediately on state entry without mutating timer semantics.
                        process_ballistic_firing_state(entity, wpn_inst, wpn_def, muzzle_pos, aim_rad, input)
                    }
                case .Cannon: if input.fire_held && wpn_inst.ammo_in_clip > 0 {
                            enter_state(wpn_inst, .Charging, wpn_def.charge_time)
                            rl.PlaySound(wpn_def.charge_sound)
                            wpn_inst.charge_sfx_playing = true
                        }
                }
            }

    case .Switching: if wpn_inst.state_timer >= wpn_inst.state_duration {
                entity.active_weapon = wpn_inst.pending_weapon
                enter_state(&entity.weapons[wpn_inst.pending_weapon], .Idle, 0)
            }

    case .Firing: process_ballistic_firing_state(entity, wpn_inst, wpn_def, muzzle_pos, aim_rad, input)

    case .ClipDrop: if wpn_inst.state_timer >= wpn_inst.state_duration {
                wpn_inst.ammo_in_clip = 0
                if entity.auto_reload && wpn_inst.ammo_reserve > 0 {
                    enter_clip_insert(wpn_inst, wpn_def)
                } else {
                    enter_state(wpn_inst, .Idle, 0)
                }
            }

    case .ClipInsert:
        // Perfect reload minigame: player-only
        if is_player && !wpn_inst.reload_window_spent && input.reload {
            wpn_inst.reload_window_spent = true
            cursor := clamp(wpn_inst.state_timer / wpn_inst.state_duration, 0, 1)
            if check_reload_window(cursor, wpn_inst.reload_window_start, wpn_inst.reload_window_end) {
                wpn_inst.reload_perfect_this_insert = true
                st.perfect_reload_fx_timer = max(st.perfect_reload_fx_timer, PerfectReloadFxSecs)
                st.camera_shake = max(st.camera_shake, 18)
                spawn_perfect_reload_fanfare(entity.pos)
                rl.PlaySound(PerfectReloadSfx)
                wpn_inst.state_timer = wpn_inst.state_duration
            }
        }
        if wpn_inst.state_timer >= wpn_inst.state_duration {
            wpn_inst.ammo_in_clip, wpn_inst.ammo_reserve = calc_clip_insert_ammo(wpn_def.clip_size, wpn_inst.ammo_reserve)
            wpn_inst.perfect_reload_clip = wpn_inst.reload_perfect_this_insert
            enter_state(wpn_inst, .Idle, 0)
        }

    case .Charging: if input.fire_held {
                charge_frac := wpn_inst.state_timer / wpn_inst.state_duration
                shake := (7 + 22 * charge_frac) if is_player else 0
                st.camera_shake = max(st.camera_shake, shake)
                if is_player {
                    for _ in 0 ..< 3 {
                        ang := aim_rad + f32(rl.GetRandomValue(-750, 750)) / 1000.0
                        r := f32(rl.GetRandomValue(80, 130))
                        spawn := entity.pos + Vec2{math.cos(ang), math.sin(ang)} * r
                        append(
                            &st.particles,
                            Particle{pos = spawn, vel = (muzzle_pos - spawn) * 1.3, radius = f32(rl.GetRandomValue(3, 6)), color = rl.SKYBLUE, max_age = f32(rl.GetRandomValue(22, 35)) / 100.0},
                        )
                    }
                }
            } else {
                rl.StopSound(wpn_def.charge_sound)
                wpn_inst.charge_sfx_playing = false
                if wpn_inst.state_timer >= wpn_inst.state_duration {
                    wpn_inst.beam_angle = entity.aim_angle
                    wpn_inst.ammo_in_clip -= 1
                    apply_kickback(entity, math.to_radians(wpn_inst.beam_angle), wpn_def.kickback_impulse)
                    shake := wpn_def.shake_impulse if is_player else wpn_def.shake_impulse * 0.05
                    st.camera_shake = max(st.camera_shake, shake)
                    rl.PlaySound(wpn_def.sound)
                    enter_state(wpn_inst, .BeamActive, wpn_def.beam_duration)
                } else {
                    enter_state(wpn_inst, .Idle, 0)
                }
            }

    case .BeamActive:
        shake: f32 = 55 if is_player else 2
        st.camera_shake = max(st.camera_shake, shake)
        beam_rad := math.to_radians(wpn_inst.beam_angle)
        beam_dir := Vec2{math.cos(beam_rad), math.sin(beam_rad)}
        beam_origin := entity.pos + beam_dir * (entity.radius + 15)
        friendly := entity.type == .Player
        for &e in st.entities {
            // Player beam hits enemies, enemy beam hits player
            if friendly && e.type != .Enemy {continue}
            if !friendly && e.type != .Player {continue}
            to_e := e.pos - beam_origin
            along := linalg.dot(to_e, beam_dir)
            if along < 0 {continue}
            beam_hit_r := wpn_def.beam_half_width + e.radius
            if linalg.length2(to_e - beam_dir * along) < beam_hit_r * beam_hit_r {
                e.health -= wpn_def.beam_damage * dt
                e.hit_flash = max(e.hit_flash, 0.06)
                if rl.GetRandomValue(0, 100) < 10 {
                    spawn_hit_sparks(e.pos, rl.YELLOW, 2)
                }
            }
        }
        if wpn_inst.state_timer >= wpn_inst.state_duration {
            enter_state(wpn_inst, .Cooldown, wpn_def.cooldown_time)
        }

    case .Cooldown: if wpn_inst.state_timer >= wpn_inst.state_duration {
                enter_state(wpn_inst, .Idle, 0)
            }
    }

    update_weapon_move_lock(entity)
    resolve_volitional_movement_lock(entity)

    // Decay muzzle flash (cosmetic, not state-gated)
    if wpn_inst.muzzle_flash_timer > 0 {wpn_inst.muzzle_flash_timer = max(0, wpn_inst.muzzle_flash_timer - dt)}
}

// ── Gameplay Update ────────────────────────────────────────────────────────────

update_gameplay :: proc() {
    dt := rl.GetFrameTime()

    {     // Refresh entity pointers (entity list may have changed last frame)
        st.player = nil
        st.crosshair = nil
        for &e in st.entities {
            switch e.type {
            case .Player: st.player = &e
            case .Crosshair: st.crosshair = &e
            case .Enemy:
            }
        }
    }

    {     // Windowing and inputs that need correction before use
        st.render_size = vec2({rl.GetRenderWidth(), rl.GetRenderHeight()})
        st.dpi_scaling = rl.GetWindowScaleDPI()
        st.mouse_pos = rl.GetMousePosition() * st.dpi_scaling // not DPI aware so we must fix
        if rl.IsKeyPressed(.Y) {st.sprite_aim_rotate = !st.sprite_aim_rotate}
        if rl.IsKeyPressed(.T) {st.flip_by_aim = !st.flip_by_aim}
        if rl.IsKeyPressed(.G) {st.player.auto_reload = !st.player.auto_reload}
        if rl.IsKeyPressed(.H) {
            st.player.ballistic_fire_mode = .WindupDelay if st.player.ballistic_fire_mode == .ImmediateCooldown else .ImmediateCooldown
        }
        if rl.IsKeyPressed(.U) {st.show_debug_overlay = !st.show_debug_overlay}
    }

    {     // Camera
        st.camera.offset = st.render_size / 2 // if window resized, we must update camera offset based on render (not screen) size
        st.camera.target = st.player.pos // follow player
        st.camera.zoom = clamp(st.camera.zoom + rl.GetMouseWheelMove() * 0.1, 0.1, 10.0) // zoom in/out with mouse wheel
        if st.camera_shake > 0.1 {
            st.camera.offset += {f32(rl.GetRandomValue(-100, 100)) / 100.0 * st.camera_shake, f32(rl.GetRandomValue(-100, 100)) / 100.0 * st.camera_shake}
        }
    }

    dir_input: Vec2
    {     // Movement
        st.player.ai_move_locked = false
        update_weapon_move_lock(st.player)
        resolve_volitional_movement_lock(st.player)
        if !st.player.cant_volitional_move {
            if rl.IsKeyDown(.W) {dir_input.y -= 1}
            if rl.IsKeyDown(.S) {dir_input.y += 1}
            if rl.IsKeyDown(.A) {dir_input.x -= 1}
            if rl.IsKeyDown(.D) {dir_input.x += 1}
        }

        move_accel_per_sec := st.player.move_speed * (1 - FrictionGroundPerTick) * 35.0 * st.player.move_accel
        st.player.move_vel += dir_input * move_accel_per_sec * dt
        st.player.move_vel = st.player.move_vel * math.pow(FrictionGroundPerSec, dt)
        move_speed_sq := linalg.length2(st.player.move_vel)
        move_cap_sq := st.player.move_speed * st.player.move_speed
        if move_speed_sq > move_cap_sq {
            st.player.move_vel = st.player.move_vel / math.sqrt(move_speed_sq) * st.player.move_speed
        }
        st.player.impulse_vel = st.player.impulse_vel * math.pow(FrictionGroundPerSec, dt)
        st.player.pos += (st.player.move_vel + st.player.impulse_vel) * dt
    }

    {     // Aiming
        st.crosshair.pos = rl.GetScreenToWorld2D(st.mouse_pos, st.camera)
        dir := st.crosshair.pos - st.player.pos
        st.player.aim_angle = math.to_degrees(math.atan2(dir.y, dir.x))
        for &e in st.entities {
            if e.type == .Enemy {
                d := st.player.pos - e.pos
                e.aim_angle = math.to_degrees(math.atan2(d.y, d.x))
            }
        }
    }

    {     // Enemy AI + weapon input
        for i in 0 ..< len(st.entities) {
            e := &st.entities[i]
            if e.type != .Enemy {continue}
            enemy_def := EnemyDB[e.enemy_type]

            to_player := st.player.pos - e.pos
            dist_sq := linalg.length2(to_player)
            dist_to_player: f32
            dir_to_player: Vec2
            if dist_sq > 0.0001 {
                dist_to_player = math.sqrt(dist_sq)
                dir_to_player = to_player / dist_to_player
            }

            separation: Vec2
            for j in 0 ..< len(st.entities) {
                if i == j {continue}
                other := st.entities[j]
                if other.type != .Enemy {continue}
                delta := e.pos - other.pos
                d_sq := linalg.length2(delta)
                if d_sq <= 0.0001 {continue}
                d := math.sqrt(d_sq)
                desired_sep := e.radius + other.radius + 24
                if d < desired_sep {
                    separation += (delta / d) * ((desired_sep - d) / desired_sep)
                }
            }

            steering: Vec2
            ai_move_locked := false
            use_air_friction := false
            enemy_input := WeaponInput{}
            separation_term := separation * (enemy_def.separation_str / 120.0)

            switch e.enemy_type {
            case .Chaser:
                e.ai_timer += dt
                steering = dir_to_player + separation_term
                within_engage_range := dist_to_player < 400
                enemy_input.fire_held = within_engage_range
                enemy_input.fire_pressed = within_engage_range

            case .Rusher:
                steering = separation_term
                switch e.ai_state {
                case .Idle:
                    e.ai_timer += dt
                    if dist_to_player > 430 {
                        steering += dir_to_player * 0.9
                    } else if dist_to_player < 170 {
                        steering += -dir_to_player * 0.55
                    } else {
                        steering += dir_to_player * 0.25
                    }
                    within_engage_range := dist_to_player < 380
                    enemy_input.fire_held = within_engage_range
                    enemy_input.fire_pressed = within_engage_range
                    player_world_vel := st.player.move_vel + st.player.impulse_vel
                    closing_dot: f32
                    player_speed_sq := linalg.length2(player_world_vel)
                    if player_speed_sq > 1 {
                        player_dir := player_world_vel / math.sqrt(player_speed_sq)
                        // Positive means player is moving toward the rusher; avoid wasting dashes on hard closes.
                        closing_dot = linalg.dot(player_dir, -dir_to_player)
                    }
                    can_charge_dist := dist_to_player > 210 && dist_to_player < 520
                    if can_charge_dist && e.ai_timer >= 0.28 && closing_dot < 0.70 {
                        e.ai_state = .Charging
                        e.ai_timer = 0
                        e.move_vel = {}
                    }
                case .Charging:
                    ai_move_locked = true
                    e.move_vel = {}
                    e.ai_timer += dt
                    if e.ai_timer >= enemy_def.charge_telegraph {
                        e.ai_state = .Dashing
                        e.ai_timer = 0
                        lead_target := st.player.pos + (st.player.move_vel + st.player.impulse_vel) * 0.22
                        dash_vec := lead_target - e.pos
                        dash_dir := dir_to_player
                        dash_len_sq := linalg.length2(dash_vec)
                        if dash_len_sq > 0.0001 {
                            dash_dir = dash_vec / math.sqrt(dash_len_sq)
                        }
                        e.impulse_vel = dash_dir * enemy_def.dash_speed
                    }
                case .Dashing:
                    use_air_friction = true
                    e.ai_timer += dt
                    if e.ai_timer >= enemy_def.dash_duration {
                        e.ai_state = .Cooldown
                        e.ai_timer = 0
                    }
                case .Cooldown:
                    use_air_friction = true
                    e.ai_timer += dt
                    if e.ai_timer >= enemy_def.dash_cooldown {
                        e.ai_state = .Idle
                        e.ai_timer = 0
                    }
                }

            case .Strafer:
                e.ai_timer += dt
                preferred := enemy_def.preferred_dist
                radial: Vec2
                if dist_to_player > preferred + 50 {
                    radial = dir_to_player
                } else if dist_to_player < preferred - 50 {
                    radial = -dir_to_player
                }
                orbit_sign: f32 = 1 if e.id % 2 == 0 else -1
                tangential := Vec2{-dir_to_player.y, dir_to_player.x} * orbit_sign
                steering = radial + tangential * (enemy_def.strafe_speed / max(f32(1), enemy_def.move_speed)) + separation_term
                within_engage_range := dist_to_player < preferred + 150
                enemy_input.fire_held = within_engage_range
                enemy_input.fire_pressed = within_engage_range

                if e.weapons[e.active_weapon].ammo_in_clip <= 0 {
                    tesla_has_any_ammo := e.weapons[.Tesla].ammo_in_clip > 0 || e.weapons[.Tesla].ammo_reserve > 0
                    rifle_has_any_ammo := e.weapons[.Rifle].ammo_in_clip > 0 || e.weapons[.Rifle].ammo_reserve > 0
                    if e.active_weapon == .Rifle && .Tesla in e.owned_weapons && tesla_has_any_ammo {
                        enemy_input.switch_to = .Tesla
                    } else if e.active_weapon == .Tesla && .Rifle in e.owned_weapons && rifle_has_any_ammo {
                        enemy_input.switch_to = .Rifle
                    }
                }
            }

            steer_len_sq := linalg.length2(steering)
            if steer_len_sq > 1 {
                steering /= math.sqrt(steer_len_sq)
            }

            update_entity_weapons(e, enemy_input, dt)
            e.ai_move_locked = ai_move_locked
            resolve_volitional_movement_lock(e)

            if !e.cant_volitional_move && e.ai_state != .Dashing {
                move_accel_per_sec := e.move_speed * (1 - FrictionGroundPerTick) * 35.0 * e.move_accel
                e.move_vel += steering * move_accel_per_sec * dt
            }

            e.move_vel = e.move_vel * math.pow(FrictionGroundPerSec, dt)
            move_speed_sq := linalg.length2(e.move_vel)
            move_cap_sq := e.move_speed * e.move_speed
            if move_speed_sq > move_cap_sq {
                e.move_vel = e.move_vel / math.sqrt(move_speed_sq) * e.move_speed
            }
            friction_per_sec := FrictionGroundPerSec
            if use_air_friction {
                friction_per_sec = FrictionAirPerSec
            }
            if e.ai_state == .Dashing {
                // Keep burst movement coherent while dash is active.
                e.impulse_vel = e.impulse_vel * math.pow(FrictionAirPerSec, dt * 0.20)
            } else {
                e.impulse_vel = e.impulse_vel * math.pow(friction_per_sec, dt)
            }
            e.pos += (e.move_vel + e.impulse_vel) * dt
        }
    }

    {     // Player weapon input
        player_input := WeaponInput {
            fire_held    = rl.IsMouseButtonDown(.LEFT),
            fire_pressed = rl.IsMouseButtonPressed(.LEFT),
            reload       = rl.IsKeyPressed(.R),
        }
        if rl.IsKeyPressed(
            .ONE,
        ) {player_input.switch_to = .SMG} else if rl.IsKeyPressed(.TWO) {player_input.switch_to = .Rifle} else if rl.IsKeyPressed(.THREE) {player_input.switch_to = .Tesla} else if rl.IsKeyPressed(.FOUR) {player_input.switch_to = .Cannon}
        update_entity_weapons(st.player, player_input, dt)

        // Keep SMG audio alive only while actively firing with trigger held (player-only).
        smg_audio_active := st.player.active_weapon == .SMG && st.player.weapons[.SMG].state == .Firing && rl.IsMouseButtonDown(.LEFT)
        if !smg_audio_active {
            rl.StopSound(WeaponDB[.SMG].sound)
        }
    }

    {     // VFX decay
        if st.camera_shake > 0.1 {
            st.camera_shake *= math.pow(f32(0.78), dt * 60)
        } else {
            st.camera_shake = 0
        }
        if st.perfect_reload_fx_timer > 0 {
            st.perfect_reload_fx_timer = max(0, st.perfect_reload_fx_timer - dt)
        }
    }

    {     // Damage, collisions, and cleanup (co-located)
        // Shared helper to keep particle and entity-contact damage feedback consistent.
        apply_damage_with_flash :: proc(e: ^Entity, damage: f32, flash_secs: f32) {
            if damage <= 0 {return}
            e.health -= damage
            e.hit_flash = max(e.hit_flash, flash_secs)
        }

        // Particle movement + particle damage impacts
        for i := 0; i < len(st.particles); {
            p := &st.particles[i]
            p.pos += p.vel * dt
            p.age += dt
            dead := p.age >= p.max_age
            if p.damage > 0 && !dead {
                for &e in st.entities {
                    hits_enemy := p.friendly && e.type == .Enemy
                    hits_player := !p.friendly && e.type == .Player
                    if !hits_enemy && !hits_player {continue}
                    hit_r := e.radius + p.radius
                    if linalg.length2(e.pos - p.pos) < hit_r * hit_r {
                        apply_damage_with_flash(&e, p.damage, 0.16)
                        spawn_hit_sparks(p.pos, p.color, 5)
                        dead = true
                        break
                    }
                }
            }
            if dead {unordered_remove(&st.particles, i)} else {i += 1}
        }

        // Entity contact damage
        for i in 0 ..< len(st.entities) {
            for j in i + 1 ..< len(st.entities) {
                a := &st.entities[i]
                b := &st.entities[j]
                if a.type == .Enemy && b.type == .Enemy {continue}
                hit_r := a.radius + b.radius
                if linalg.length2(b.pos - a.pos) < hit_r * hit_r {
                    apply_damage_with_flash(a, b.damage * dt, 0.1)
                    apply_damage_with_flash(b, a.damage * dt, 0.1)
                }
            }
        }

        // Damage feedback decay
        for &e in st.entities {
            if e.hit_flash > 0 {
                e.hit_flash = max(0, e.hit_flash - dt)
            }
        }

        // Remove dead enemies
        for i := 0; i < len(st.entities); {
            if st.entities[i].type == .Enemy && st.entities[i].health <= 0 {
                unordered_remove(&st.entities, i)
            } else {
                i += 1
            }
        }
    }
}

// ── Rendering ──────────────────────────────────────────────────────────────────

render_frame :: proc() {
    draw_tex :: proc(tex: rl.Texture2D, pos: Vec2, scale: Vec2, angle: f32, flipH: bool = false, tint: rl.Color = rl.WHITE) {
        src_size := vec2({tex.width, tex.height})
        src_rect := rl.Rectangle{0, 0, src_size.x if !flipH else -src_size.x, src_size.y}
        dest_size := src_size * scale
        dest_rect := rl.Rectangle{pos.x, pos.y, dest_size.x, dest_size.y}
        rl.DrawTexturePro(tex, src_rect, dest_rect, dest_size / 2, angle, tint)
    }
    draw_cannon_beam :: proc(beam_angle_deg: f32, beam_timer: f32) {
        cannon_wpn_def := WeaponDB[.Cannon]
        beam_rad := math.to_radians(beam_angle_deg)
        beam_dir := Vec2{math.cos(beam_rad), math.sin(beam_rad)}
        perp := Vec2{-math.sin(beam_rad), math.cos(beam_rad)}
        origin := st.player.pos + beam_dir * (st.player.radius + 15)
        beam_end := origin + beam_dir * 3000
        beam_fade := max(f32(0), 1 - beam_timer / cannon_wpn_def.beam_duration)
        outer_alpha := f32(0.84) * beam_fade
        outer_half_width := cannon_wpn_def.beam_half_width * 1.33
        core_half_width := cannon_wpn_def.beam_half_width * 0.53
        outer_color := rl.Fade(rl.RAYWHITE, outer_alpha)
        core_color := rl.Fade(rl.YELLOW, outer_alpha * 0.7)
        rl.DrawTriangle(origin + perp * outer_half_width, beam_end + perp * outer_half_width, beam_end - perp * outer_half_width, outer_color)
        rl.DrawTriangle(beam_end - perp * outer_half_width, origin - perp * outer_half_width, origin + perp * outer_half_width, outer_color)
        rl.DrawTriangle(origin + perp * core_half_width, beam_end + perp * core_half_width, beam_end - perp * core_half_width, core_color)
        rl.DrawTriangle(beam_end - perp * core_half_width, origin - perp * core_half_width, origin + perp * core_half_width, core_color)
    }

    rl.BeginDrawing()
    rl.ClearBackground(rl.BROWN)
    rl.BeginMode2D(st.camera)

    // Field guide lines
    rl.DrawLine(0, -5000, 0, 5000, rl.GREEN)
    rl.DrawLine(-5000, 0, 5000, 0, rl.GREEN)

    // Precompute aim vectors needed for render-time effects
    render_aim_rad := math.to_radians(st.player.aim_angle)
    render_aim_dir := Vec2{math.cos(render_aim_rad), math.sin(render_aim_rad)}
    render_muzzle := st.player.pos + render_aim_dir * (st.player.radius + 15)

    // Particles
    for p in st.particles {
        rl.DrawCircleV(p.pos, p.radius, rl.Fade(p.color, 1 - p.age / p.max_age))
    }

    // Entities
    for e in st.entities {
        viz := VizDB[e.type]
        pos := e.pos
        scale := viz.tex_scale * e.radius
        enemy_def := EntityDef{}
        if e.type == .Enemy {
            enemy_def = EnemyDB[e.enemy_type]
            scale = viz.tex_scale * enemy_def.radius
        }
        world_vel := e.move_vel + e.impulse_vel
        flipH := (math.abs(e.aim_angle) > 90) if st.flip_by_aim else (world_vel.x < 0)

        if e.type != .Crosshair {     // Bobbing effect
            pos.y += math.sin(f32(rl.GetTime()) * viz.bob_speed) * viz.bob_magnitude
        }
        if e.type != .Crosshair {     // Squash and stretch effect
            squash := math.abs(math.sin(f32(rl.GetTime()) * viz.squash_speed)) * viz.squash_magnitude + viz.squash_baseline
            stretch := 2 - squash
            scale *= {stretch, squash}
        }

        angle: f32 = 0
        if st.sprite_aim_rotate {angle = e.aim_angle}

        tint := rl.WHITE
        if e.type == .Enemy {
            tint = enemy_def.tint
            if e.enemy_type == .Rusher && e.ai_state == .Dashing {
                tint = rl.Color{255, 222, 128, 255}
            }
        }
        if e.hit_flash > 0.01 {
            tint = rl.Color{255, 165, 165, 255}
        }

        draw_tex(viz.texture, pos, scale, angle, flipH, tint)
        rl.DrawCircleLines(i32(e.pos.x), i32(e.pos.y), e.radius, rl.GREEN)
        if e.type == .Enemy && e.enemy_type == .Rusher {
            switch e.ai_state {
            case .Charging:
                telegraph_def := EnemyDB[.Rusher]
                telegraph_frac := clamp(e.ai_timer / max(f32(0.001), telegraph_def.charge_telegraph), 0, 1)
                pulse := f32(1.0) + 0.18 * math.sin(f32(rl.GetTime()) * 18)
                telegraph_r := e.radius * (1.2 + 0.45 * telegraph_frac) * pulse
                rl.DrawCircleLines(i32(e.pos.x), i32(e.pos.y), telegraph_r, rl.Fade(rl.RED, 0.85))
            case .Dashing:
                dash_vel := e.move_vel + e.impulse_vel
                dash_speed_sq := linalg.length2(dash_vel)
                if dash_speed_sq > 1 {
                    dash_speed := math.sqrt(dash_speed_sq)
                    dash_dir := dash_vel / dash_speed
                    trail_len := e.radius * 2.4 + min(f32(320), dash_speed * 0.30)
                    tail := e.pos - dash_dir * trail_len
                    rl.DrawLineEx(e.pos, tail, 10, rl.Fade(rl.ORANGE, 0.32))
                    rl.DrawLineEx(e.pos, tail, 5, rl.Fade(rl.YELLOW, 0.90))
                    for gi in 1 ..= 3 {
                        t := f32(gi) / 4.0
                        ghost := e.pos - dash_dir * trail_len * t
                        ghost_r := e.radius * (1.0 - 0.18 * t)
                        rl.DrawCircleV(ghost, ghost_r, rl.Fade(rl.ORANGE, 0.34 * (1 - t)))
                    }
                    rl.DrawCircleLines(i32(e.pos.x), i32(e.pos.y), e.radius * 1.25, rl.Fade(rl.YELLOW, 0.95))
                }
            case .Idle, .Cooldown:
            }
        }
        if e.hit_flash > 0 {
            flash_alpha := clamp(e.hit_flash / 0.18, 0, 1)
            rl.DrawCircleLines(i32(e.pos.x), i32(e.pos.y), e.radius + 6 * flash_alpha, rl.Fade(rl.ORANGE, flash_alpha))
        }

        if e.type == .Player || e.type == .Enemy {     // Health bar
            bar_w := e.radius * 2
            bar_h: f32 = 6
            bar_x := e.pos.x - e.radius
            bar_y := e.pos.y - e.radius - 10
            frac := clamp(e.health / e.max_health, 0, 1)
            bar_color := rl.GREEN if frac > 0.5 else (rl.YELLOW if frac > 0.25 else rl.RED)
            rl.DrawRectangleRec({bar_x, bar_y, bar_w, bar_h}, rl.DARKGRAY)
            rl.DrawRectangleRec({bar_x, bar_y, bar_w * frac, bar_h}, bar_color)
        }

        if !st.sprite_aim_rotate {
            if e.type != .Crosshair {
                aim_rad := math.to_radians(e.aim_angle)
                cone_len := e.radius * 1.5
                half_spread := math.to_radians(f32(20))
                tip := e.pos + Vec2{math.cos(aim_rad), math.sin(aim_rad)} * cone_len
                left := e.pos + Vec2{math.cos(aim_rad - half_spread), math.sin(aim_rad - half_spread)} * cone_len
                rgt := e.pos + Vec2{math.cos(aim_rad + half_spread), math.sin(aim_rad + half_spread)} * cone_len
                rl.DrawLine(i32(e.pos.x), i32(e.pos.y), i32(tip.x), i32(tip.y), rl.YELLOW)
                rl.DrawLine(i32(e.pos.x), i32(e.pos.y), i32(left.x), i32(left.y), rl.YELLOW)
                rl.DrawLine(i32(e.pos.x), i32(e.pos.y), i32(rgt.x), i32(rgt.y), rl.YELLOW)
            }
        }
    }

    // Cannon charging: muzzle glow
    cannon_inst := st.player.weapons[.Cannon]
    if cannon_inst.state == .Charging {
        charge_frac := cannon_inst.state_timer / WeaponDB[.Cannon].charge_time
        for gi in 0 ..< 6 {
            r := (52 + charge_frac * 22) * (1 - f32(gi) * 0.16)
            rl.DrawCircle(i32(render_muzzle.x), i32(render_muzzle.y), r, rl.Fade(rl.RAYWHITE, 0.25 + charge_frac * 0.32))
        }
    }
    if cannon_inst.state == .BeamActive {
        draw_cannon_beam(cannon_inst.beam_angle, cannon_inst.state_timer)
    }

    // Active weapon data used by muzzle flash and HUD
    active_wpn_def := WeaponDB[st.player.active_weapon]
    active_wpn_inst := st.player.weapons[st.player.active_weapon]

    // Muzzle flash (standard) or Tesla arc
    if active_wpn_inst.muzzle_flash_timer > 0 && active_wpn_def.flash_duration > 0 {
        t := active_wpn_inst.muzzle_flash_timer / active_wpn_def.flash_duration
        perp := Vec2{-math.sin(render_aim_rad), math.cos(render_aim_rad)}
        if active_wpn_def.flash_size > 0 {
            flen := active_wpn_def.flash_size * (0.5 + t * 0.5)
            fwid := active_wpn_def.flash_size * 0.4 * t
            tip := render_muzzle + render_aim_dir * flen
            rl.DrawTriangle(render_muzzle + perp * fwid, tip, render_muzzle - perp * fwid, rl.Fade(active_wpn_def.bullet_color, t))
            rl.DrawCircleV(render_muzzle + render_aim_dir * (flen * 0.75), fwid * 0.22, rl.Fade(rl.RAYWHITE, t * 0.65))
        } else {
            // Tesla arc: 5 jagged segments
            arc_len: f32 = 200
            prev := render_muzzle
            for s in 1 ..= 5 {
                center := render_muzzle + render_aim_dir * (arc_len * f32(s) / 5)
                offset := f32(rl.GetRandomValue(-30, 30))
                next := center + perp * offset
                rl.DrawLineEx(prev, next, 2, rl.Fade(rl.SKYBLUE, t))
                prev = next
            }
        }
    }

    rl.EndMode2D()

    // Cannon white flash (screen-space, drawn after EndMode2D)
    if cannon_inst.state == .BeamActive && cannon_inst.state_timer < 0.26 {
        rl.DrawRectangle(0, 0, i32(st.render_size.x), i32(st.render_size.y), rl.Fade(rl.RAYWHITE, max(f32(0), 1 - cannon_inst.state_timer / 0.26)))
    }
    if st.perfect_reload_fx_timer > 0 {
        t := clamp(st.perfect_reload_fx_timer / PerfectReloadFxSecs, 0, 1)
        rl.DrawRectangle(0, 0, i32(st.render_size.x), i32(st.render_size.y), rl.Fade(rl.LIME, 0.08 * t))
        draw_text({st.render_size.x / 2 - 110, st.render_size.y / 2 - 120}, 28, "PERFECT RELOAD!")
    }

    // HUD
    fire_mode_label := "COOLDOWN" if st.player.ballistic_fire_mode == .ImmediateCooldown else "WINDUP"
    draw_text({10, 10}, 20, "FPS %d | HP %.0f", rl.GetFPS(), st.player.health)
    draw_text(
        {10, 30},
        20,
        "WASD: move  LMB: fire  R: reload  scroll: zoom  [1-4]: weapon  T: flip-via-aim %v  Y: rotate %v  G: auto-reload %v  H: fire mode %v",
        st.flip_by_aim,
        st.sprite_aim_rotate,
        st.player.auto_reload,
        fire_mode_label,
    )
    switch active_wpn_inst.state {
    case .Switching: draw_text({10, 50}, 20, "SWITCHING...")
    case .ClipDrop: draw_text({10, 50}, 20, "%v: DROPPING CLIP...", active_wpn_def.name)
    case .ClipInsert: draw_text({10, 50}, 20, "%v: RELOADING...", active_wpn_def.name)
    case .Idle, .Firing, .Charging, .BeamActive, .Cooldown: draw_text({10, 50}, 20, "%v: %d / %d", active_wpn_def.name, active_wpn_inst.ammo_in_clip, active_wpn_inst.ammo_reserve)
    }
    draw_text({10, 70}, 18, "PERFECT CLIP %v", active_wpn_inst.perfect_reload_clip)
    if active_wpn_inst.state == .ClipInsert {
        draw_text({10, 90}, 18, "RELOAD MINIGAME: press R in highlighted window")
    }

    // Progress bar for timed states
    show_bar := false
    bar_frac: f32
    bar_color: rl.Color
    bar_label: string
    switch active_wpn_inst.state {
    case .Switching:
        show_bar = true
        bar_frac = clamp(active_wpn_inst.state_timer / active_wpn_inst.state_duration, 0, 1)
        bar_color = rl.ORANGE
        bar_label = "SWITCHING"
    case .ClipDrop:
        show_bar = true
        bar_frac = clamp(active_wpn_inst.state_timer / active_wpn_inst.state_duration, 0, 1)
        bar_color = rl.ORANGE
        bar_label = "DROPPING CLIP"
    case .ClipInsert:
        show_bar = true
        bar_frac = clamp(active_wpn_inst.state_timer / active_wpn_inst.state_duration, 0, 1)
        bar_color = rl.SKYBLUE
        bar_label = "RELOADING"
    case .Charging:
        show_bar = true
        bar_frac = clamp(active_wpn_inst.state_timer / active_wpn_inst.state_duration, 0, 1)
        bar_color = rl.YELLOW if bar_frac >= 1 else rl.SKYBLUE
        bar_label = "MAXIMUM CHARGE!" if bar_frac >= 1 else "CHARGING..."
    case .Cooldown:
        show_bar = true
        bar_frac = 1 - clamp(active_wpn_inst.state_timer / active_wpn_inst.state_duration, 0, 1)
        bar_color = rl.YELLOW
        bar_label = "COOLDOWN"
    case .Idle, .Firing, .BeamActive:
    }
    if show_bar {
        barw: f32 = 300
        barh: f32 = 20
        cx := st.render_size.x / 2 - barw / 2
        cy := st.render_size.y - 60
        rl.DrawRectangle(i32(cx), i32(cy), i32(barw), i32(barh), rl.DARKGRAY)
        rl.DrawRectangle(i32(cx), i32(cy), i32(barw * bar_frac), i32(barh), bar_color)
        if active_wpn_inst.state == .ClipInsert {
            zone_x := cx + barw * clamp(active_wpn_inst.reload_window_start, 0, 1)
            zone_w := barw * clamp(active_wpn_inst.reload_window_end - active_wpn_inst.reload_window_start, 0, 1)
            rl.DrawRectangle(i32(zone_x), i32(cy), i32(zone_w), i32(barh), rl.Fade(rl.GREEN, 0.45))
            cursor_x := cx + barw * clamp(active_wpn_inst.state_timer / active_wpn_inst.state_duration, 0, 1)
            rl.DrawLineEx({cursor_x, cy - 4}, {cursor_x, cy + barh + 4}, 2, rl.RAYWHITE)
        }
        rl.DrawRectangleLines(i32(cx), i32(cy), i32(barw), i32(barh), rl.RAYWHITE)
        draw_text({cx, cy - 24}, 18, bar_label)
    }

    if st.show_debug_overlay {
        enemy_count := 0
        rusher_idle := 0
        rusher_charging := 0
        rusher_dashing := 0
        rusher_cooldown := 0
        for e in st.entities {
            if e.type != .Enemy {continue}
            enemy_count += 1
            if e.enemy_type == .Rusher {
                switch e.ai_state {
                case .Idle: rusher_idle += 1
                case .Charging: rusher_charging += 1
                case .Dashing: rusher_dashing += 1
                case .Cooldown: rusher_cooldown += 1
                }
            }
        }
        draw_text({10, 110}, 18, "[U] DEBUG OVERLAY")
        draw_text({10, 130}, 18, "ENTITIES %d | ENEMIES %d | PARTICLES %d", len(st.entities), enemy_count, len(st.particles))
        draw_text({10, 150}, 18, "FRAME %.2fms | UPDATE %.2fms | RENDER %.2fms", st.debug_frame_ms, st.debug_update_ms, st.debug_render_ms)
        draw_text({10, 170}, 18, "RUSHER FSM I:%d C:%d D:%d CD:%d", rusher_idle, rusher_charging, rusher_dashing, rusher_cooldown)
    }

    rl.EndDrawing()
}

// ── Main Loop ──────────────────────────────────────────────────────────────────

main :: proc() {
    when DEBUG_MEMORY {
        tracking_allocator: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking_allocator, context.allocator)
        context.allocator = mem.tracking_allocator(&tracking_allocator)

        print_alloc_stats :: proc(tracking: ^mem.Tracking_Allocator) {
            for _, entry in tracking.allocation_map {
                fmt.printfln("%v: Leaked %v bytes", entry.location, entry.size)
            }
            for entry in tracking.bad_free_array {
                fmt.printfln("%v: Bad free @ %v", entry.location, entry.memory)
            }
            fmt.printfln("Total Allocated: %d bytes", tracking.total_memory_allocated)
        }
        defer {print_alloc_stats(&tracking_allocator)}
    }
    rl.SetConfigFlags({.WINDOW_HIGHDPI, .MSAA_4X_HINT, .WINDOW_RESIZABLE})
    rl.InitWindow(1920, 1080, "Twin")
    rl.SetTargetFPS(120)
    rl.HideCursor()
    rl.InitAudioDevice()

    init_assets()
    init_game_state()

    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)
        update_begin := rl.GetTime()
        update_gameplay()
        st.debug_update_ms = f32((rl.GetTime() - update_begin) * 1000.0)
        render_begin := rl.GetTime()
        render_frame()
        st.debug_render_ms = f32((rl.GetTime() - render_begin) * 1000.0)
        st.debug_frame_ms = rl.GetFrameTime() * 1000.0
    }
    cleanup_resources()
}

// ── Tests ───────────────────────────────────────────────────────────────────────

import "core:testing"

@(test)
enter_state_sets_fields :: proc(t: ^testing.T) {
    inst := WeaponInstance {
        state          = .Idle,
        state_timer    = 99,
        state_duration = 99,
    }
    enter_state(&inst, .Firing, 0.3)
    testing.expect_value(t, inst.state, WeaponState.Firing)
    testing.expect(t, inst.state_timer == 0, "state_timer should be zeroed")
    testing.expect(t, inst.state_duration == 0.3, "state_duration should match")
}

@(test)
enter_clip_drop_uses_weapon_timing :: proc(t: ^testing.T) {
    def := WeaponDef {
        clip_drop_time = 0.4,
    }
    inst := WeaponInstance {
        state = .Idle,
    }
    enter_clip_drop(&inst, def)
    testing.expect_value(t, inst.state, WeaponState.ClipDrop)
    testing.expect(t, inst.state_duration == 0.4, "duration should match clip_drop_time")
    testing.expect(t, inst.state_timer == 0, "timer should be zeroed")
}

@(test)
clip_insert_full_reserve :: proc(t: ^testing.T) {
    clip, reserve := calc_clip_insert_ammo(30, 150)
    testing.expect_value(t, clip, 30)
    testing.expect_value(t, reserve, 120)
}

@(test)
clip_insert_partial_reserve :: proc(t: ^testing.T) {
    clip, reserve := calc_clip_insert_ammo(30, 12)
    testing.expect_value(t, clip, 12)
    testing.expect_value(t, reserve, 0)
}

@(test)
clip_insert_zero_reserve :: proc(t: ^testing.T) {
    clip, reserve := calc_clip_insert_ammo(30, 0)
    testing.expect_value(t, clip, 0)
    testing.expect_value(t, reserve, 0)
}

@(test)
reload_with_ammo_drops_clip :: proc(t: ^testing.T) {
    testing.expect_value(t, calc_reload_action(15, 100), ReloadAction.DropClip)
}

@(test)
reload_empty_with_reserve_inserts :: proc(t: ^testing.T) {
    testing.expect_value(t, calc_reload_action(0, 50), ReloadAction.InsertClip)
}

@(test)
reload_empty_no_reserve_does_nothing :: proc(t: ^testing.T) {
    testing.expect_value(t, calc_reload_action(0, 0), ReloadAction.None)
}

@(test)
perfect_reload_in_window :: proc(t: ^testing.T) {
    testing.expect(t, check_reload_window(0.5, 0.4, 0.6), "cursor inside window should hit")
}

@(test)
perfect_reload_before_window :: proc(t: ^testing.T) {
    testing.expect(t, !check_reload_window(0.3, 0.4, 0.6), "cursor before window should miss")
}

@(test)
perfect_reload_after_window :: proc(t: ^testing.T) {
    testing.expect(t, !check_reload_window(0.7, 0.4, 0.6), "cursor after window should miss")
}

@(test)
perfect_reload_at_boundaries :: proc(t: ^testing.T) {
    testing.expect(t, check_reload_window(0.4, 0.4, 0.6), "cursor at start boundary should hit")
    testing.expect(t, check_reload_window(0.6, 0.4, 0.6), "cursor at end boundary should hit")
}
