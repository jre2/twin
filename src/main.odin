#+feature dynamic-literals
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import rl "vendor:raylib"

DEBUG_MEMORY :: true

FrictionGroundPerTick :: 0.90625 // Doom style, per 35hz tic, applied to current speed
FrictionGroundPerSec: f32 = math.pow(f32(FrictionGroundPerTick), 35.0)
FrictionSlowdownAir :: 0.9727 // doom style, per 35hz tic, applied to current speed

Vec2 :: [2]f32
Vec2i :: [2]i32
EntityType :: enum {
    Player,
    Enemy,
    Crosshair,
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
Entity :: struct {
    id:         int,
    type:       EntityType,
    pos:        Vec2,
    vel:        Vec2,
    radius:     f32,
    aim_angle:  f32, // degrees
    max_vel:    Vec2,
    health:     f32,
    max_health: f32,
    damage:     f32, // contact damage per second
    hit_flash:  f32, // seconds remaining for damage feedback
    cant_volitional_move: bool, // whether entity can move of their own volition; momentum and knockback are not affected
}
WeaponType :: enum {SMG, Rifle, Tesla, Cannon}
WeaponState :: enum {
    Idle,
    Switching,    // equipping a new weapon
    Firing,       // just fired, waiting for fire_interval to elapse
    ClipDrop,     // ejecting current clip
    ClipInsert,   // inserting new clip from reserve
    Charging,     // cannon: holding LMB to charge
    BeamActive,   // cannon: beam firing
    Cooldown,     // cannon: post-beam cooldown
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
WeaponInstance :: struct {
    ammo_in_clip:       int,
    ammo_reserve:       int,
    state:              WeaponState,
    state_timer:        f32, // seconds elapsed in current state
    state_duration:     f32, // total duration of current state (set on entry)
    beam_angle:         f32, // cannon: locked aim angle during beam
    charge_sfx_playing: bool, // cannon: whether charge sound is playing
    pending_weapon:     WeaponType, // target weapon during Switching state
    muzzle_flash_timer: f32, // visual only: decays independently
}
Particle :: struct {
    pos:     Vec2,
    vel:     Vec2,
    radius:  f32,
    damage:  f32, // 0 = visual only
    color:   rl.Color,
    age:     f32,
    max_age: f32,
}
GameState :: struct {
    render_size:       Vec2,
    dpi_scaling:       Vec2,
    mouse_pos:         Vec2, // screen space
    camera:            rl.Camera2D,
    entities:          [dynamic]Entity,
    player:            ^Entity,
    crosshair:         ^Entity,
    sprite_aim_rotate: bool,
    flip_by_aim:       bool, // true = flip sprite based on aim direction; false = flip based on movement
    auto_reload:       bool, // true = clip drop automatically chains into clip insert
    current_weapon:    WeaponType,
    weapons:           [WeaponType]WeaponInstance,
    particles:         [dynamic]Particle,
    camera_shake:      f32,
}

vec2 :: proc(v: Vec2i) -> Vec2 {return Vec2{f32(v.x), f32(v.y)}}
vec2i :: proc(v: Vec2) -> Vec2i {return Vec2i{i32(v.x), i32(v.y)}}

draw_text :: proc(pos: Vec2, size: f32, fmtstring: string, args: ..any) {
    s := fmt.tprintf(fmtstring, ..args)
    cs := strings.clone_to_cstring(s, context.temp_allocator)
    rl.DrawText(cs, i32(pos.x), i32(pos.y), i32(size), rl.RAYWHITE)
}
draw_tex :: proc(tex: rl.Texture2D, pos: Vec2, scale: Vec2, angle: f32, flipH: bool = false, tint: rl.Color = rl.WHITE) {
    src_size := vec2({tex.width, tex.height})
    src_rect := rl.Rectangle{0, 0, src_size.x if !flipH else -src_size.x, src_size.y}
    dest_size := src_size * scale
    dest_rect := rl.Rectangle{pos.x, pos.y, dest_size.x, dest_size.y}
    rl.DrawTexturePro(tex, src_rect, dest_rect, dest_size / 2, angle, tint)
}

enter_state :: proc(inst: ^WeaponInstance, new_state: WeaponState, duration: f32) {
    inst.state = new_state
    inst.state_timer = 0
    inst.state_duration = duration
}

apply_player_kickback :: proc(aim_rad: f32, impulse: f32) {
    // Convert weapon impulse into backward player velocity.
    dir := Vec2{math.cos(aim_rad), math.sin(aim_rad)}
    st.player.vel -= dir * impulse * 8.0
}

spawn_hit_sparks :: proc(origin: Vec2, color: rl.Color, count: int = 5) {
    for _ in 0 ..< count {
        ang := f32(rl.GetRandomValue(0, 6283)) / 1000.0
        speed := f32(rl.GetRandomValue(180, 520))
        vel := Vec2{math.cos(ang), math.sin(ang)} * speed
        append(&st.particles, Particle{
            pos = origin,
            vel = vel,
            radius = f32(rl.GetRandomValue(2, 4)),
            color = color,
            max_age = f32(rl.GetRandomValue(8, 18)) / 100.0,
        })
    }
}

fire_bullet :: proc(inst: ^WeaponInstance, def: WeaponDef, muzzle_pos: Vec2, aim_rad: f32) {
    spread := aim_rad + (f32(rl.GetRandomValue(-1000, 1000)) / 1000.0) * def.bullet_spread
    vel := Vec2{math.cos(spread), math.sin(spread)} * def.bullet_speed
    append(&st.particles, Particle{pos = muzzle_pos, vel = vel, radius = def.bullet_radius, damage = def.bullet_damage, color = def.bullet_color, max_age = 3.0})
    inst.ammo_in_clip -= 1
    apply_player_kickback(aim_rad, def.kickback_impulse)
    inst.muzzle_flash_timer = def.flash_duration
    st.camera_shake = max(st.camera_shake, def.shake_impulse)
    rl.PlaySound(def.sound)
    enter_state(inst, .Firing, def.fire_interval)
}

draw_cannon_beam :: proc(beam_angle_deg: f32, beam_timer: f32) {
    def := WeaponDB[.Cannon]
    beam_rad := math.to_radians(beam_angle_deg)
    dir := Vec2{math.cos(beam_rad), math.sin(beam_rad)}
    perp := Vec2{-math.sin(beam_rad), math.cos(beam_rad)}
    origin := st.player.pos + dir * (st.player.radius + 15)
    beam_end := origin + dir * 3000
    t := max(f32(0), 1 - beam_timer / def.beam_duration)
    outer_alpha := f32(0.84) * t
    ow := def.beam_half_width * 1.33
    cw := def.beam_half_width * 0.53
    oc := rl.Fade(rl.RAYWHITE, outer_alpha)
    cc := rl.Fade(rl.YELLOW, outer_alpha * 0.7)
    rl.DrawTriangle(origin + perp * ow, beam_end + perp * ow, beam_end - perp * ow, oc)
    rl.DrawTriangle(beam_end - perp * ow, origin - perp * ow, origin + perp * ow, oc)
    rl.DrawTriangle(origin + perp * cw, beam_end + perp * cw, beam_end - perp * cw, cc)
    rl.DrawTriangle(beam_end - perp * cw, origin - perp * cw, origin + perp * cw, cc)
}

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
}

init_game_state :: proc() {
    append(&st.entities, Entity{id = len(st.entities), type = .Player, radius = 50, max_vel = {700, 700}, health = 100, max_health = 100})
    append(&st.entities, Entity{id = len(st.entities), type = .Crosshair, radius = 20})
    for _ in 1 ..= 10 {
        pos := Vec2{f32(rl.GetRandomValue(-750, 750)), f32(rl.GetRandomValue(-350, 350))}
        enemy := Entity{id = len(st.entities), type = .Enemy, radius = 50, max_vel = {40, 40}, health = 50, max_health = 50, damage = 10, pos = pos}
        append(&st.entities, enemy)
    }

    st.weapons[.SMG]    = WeaponInstance{ammo_in_clip = 30,  ammo_reserve = 150}
    st.weapons[.Rifle]  = WeaponInstance{ammo_in_clip = 10,  ammo_reserve = 50}
    st.weapons[.Tesla]  = WeaponInstance{ammo_in_clip = 20,  ammo_reserve = 80}
    st.weapons[.Cannon] = WeaponInstance{ammo_in_clip = 3,   ammo_reserve = 6}
}

cleanup_resources :: proc() {
    delete(st.entities)
    delete(st.particles)
    for &viz in VizDB {rl.UnloadTexture(viz.texture)}
    for &wep in WeaponDB {
        rl.UnloadSound(wep.sound)
        rl.UnloadSound(wep.charge_sound)
    }
    rl.CloseAudioDevice()
    rl.CloseWindow()
}

VizDB := [EntityType]VisualData {
    .Player    = VisualData{tex_path = "res/char3.png", tex_scale = Vec2{1, 1} / 300, bob_speed = 15.0, bob_magnitude = 5.0, squash_speed = 2.0, squash_magnitude = 0.25, squash_baseline = 0.9},
    .Enemy     = VisualData{tex_path = "res/enemy.png", tex_scale = Vec2{1, 1} / 300, bob_speed = 10.0, bob_magnitude = 4.0, squash_speed = 1.5, squash_magnitude = 0.2, squash_baseline = 0.8},
    .Crosshair = VisualData{tex_path = "res/crosshair.png", tex_scale = Vec2{1, 1} / 200, bob_speed = 0.0, bob_magnitude = 0.0, squash_speed = 0.0, squash_magnitude = 0.0, squash_baseline = 0.0},
}
WeaponDB := [WeaponType]WeaponDef {
    .SMG    = WeaponDef{
        name = "SMG", sound_path = "res/smg.mp3",
        fire_interval = 0.065, clip_size = 30, max_ammo = 180,
        bullet_damage = 5, bullet_speed = 800, bullet_spread = 0.4, bullet_radius = 4, bullet_color = rl.YELLOW,
        kickback_impulse = 7, shake_impulse = 6, flash_size = 24, flash_duration = 0.05,
        switch_time = 0.3, clip_drop_time = 0.15, clip_insert_time = 0.4,
    },
    .Rifle  = WeaponDef{
        name = "Rifle", sound_path = "res/rifle.mp3",
        fire_interval = 0.3, clip_size = 10, max_ammo = 60,
        bullet_damage = 25, bullet_speed = 1200, bullet_spread = 0.15, bullet_radius = 5, bullet_color = rl.RAYWHITE,
        kickback_impulse = 33, shake_impulse = 21, flash_size = 58, flash_duration = 0.12,
        switch_time = 0.4, clip_drop_time = 0.15, clip_insert_time = 0.5,
    },
    .Tesla  = WeaponDef{
        name = "Tesla Gun", sound_path = "res/tesla_gun.mp3",
        fire_interval = 0.2, clip_size = 20, max_ammo = 100,
        bullet_damage = 15, bullet_speed = 1000, bullet_spread = 0.25, bullet_radius = 4, bullet_color = rl.SKYBLUE,
        kickback_impulse = 12, shake_impulse = 10, flash_size = 0, flash_duration = 0.1,
        switch_time = 0.35, clip_drop_time = 0.15, clip_insert_time = 0.35,
    },
    .Cannon = WeaponDef{
        name = "Particle Cannon", sound_path = "res/cannon_fire.mp3", charge_sound_path = "res/cannon_charge.mp3",
        clip_size = 3, max_ammo = 9,
        kickback_impulse = 47, shake_impulse = 55,
        charge_time = 3.5, cooldown_time = 2.0, beam_half_width = 60, beam_damage = 300, beam_duration = 1.5,
        switch_time = 0.6, clip_drop_time = 0.2, clip_insert_time = 0.8,
    },
}
st := GameState {
    camera      = rl.Camera2D{zoom = 1.0},
    flip_by_aim = true,
    auto_reload = false,
}

main :: proc() {
    when DEBUG_MEMORY {
        tracking_allocator: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracking_allocator, context.allocator)
        context.allocator = mem.tracking_allocator(&tracking_allocator)

        print_alloc_stats := proc(tracking: ^mem.Tracking_Allocator) {
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

        {     // Refresh entity pointers (entity list may have changed last frame)
            st.player = nil
            st.crosshair = nil
            for &e in st.entities {
                switch e.type {
                case .Player:    st.player = &e
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
            if rl.IsKeyPressed(.G) {st.auto_reload = !st.auto_reload}
        }

        {     // Camera
            st.camera.offset = st.render_size / 2 // if window resized, we must update camera offset based on render (not screen) size
            st.camera.target = st.player.pos // follow player
            st.camera.zoom = clamp(st.camera.zoom + rl.GetMouseWheelMove() * 0.1, 0.1, 10.0) // zoom in/out with mouse wheel
            if st.camera_shake > 0.1 {
                st.camera.offset += {
                    f32(rl.GetRandomValue(-100, 100)) / 100.0 * st.camera_shake,
                    f32(rl.GetRandomValue(-100, 100)) / 100.0 * st.camera_shake,
                }
            }
        }

        dir_input: Vec2
        {     // Movement
            st.player.cant_volitional_move = st.weapons[st.current_weapon].state != .Idle // TODO refactor so every entity has weapons; not just the player in some global state
            if !st.player.cant_volitional_move {
                if rl.IsKeyDown(.W) {dir_input.y -= 1}
                if rl.IsKeyDown(.S) {dir_input.y += 1}
                if rl.IsKeyDown(.A) {dir_input.x -= 1}
                if rl.IsKeyDown(.D) {dir_input.x += 1}
            }

            accel_per_sec := st.player.max_vel * (1 - FrictionGroundPerTick) * 35.0
            st.player.vel += dir_input * accel_per_sec * rl.GetFrameTime()
            st.player.vel = st.player.vel * math.pow(FrictionGroundPerSec, rl.GetFrameTime())
            st.player.pos += st.player.vel * rl.GetFrameTime()
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

        {     // Weapons
            dt := rl.GetFrameTime()
            def  := WeaponDB[st.current_weapon]
            inst := &st.weapons[st.current_weapon]

            aim_rad    := math.to_radians(st.player.aim_angle)
            aim_dir    := Vec2{math.cos(aim_rad), math.sin(aim_rad)}
            muzzle_pos := st.player.pos + aim_dir * (st.player.radius + 15)

            inst.state_timer += dt

            switch inst.state {
            case .Idle:
                // Weapon switch: 1-4 keys
                wanted: Maybe(WeaponType)
                if      rl.IsKeyPressed(.ONE)   {wanted = .SMG}
                else if rl.IsKeyPressed(.TWO)   {wanted = .Rifle}
                else if rl.IsKeyPressed(.THREE) {wanted = .Tesla}
                else if rl.IsKeyPressed(.FOUR)  {wanted = .Cannon}
                if w, ok := wanted.?; ok && w != st.current_weapon {
                    inst.pending_weapon = w
                    enter_state(inst, .Switching, def.switch_time)
                } else if rl.IsKeyPressed(.R) {
                    // Reload: R key — drop clip first, then insert
                    if inst.ammo_in_clip > 0 {
                        enter_state(inst, .ClipDrop, def.clip_drop_time)
                    } else if inst.ammo_reserve > 0 {
                        enter_state(inst, .ClipInsert, def.clip_insert_time)
                    }
                } else {
                    // Firing (per weapon type)
                    switch st.current_weapon {
                    case .SMG, .Tesla:
                        if rl.IsMouseButtonDown(.LEFT) && inst.ammo_in_clip > 0 {
                            fire_bullet(inst, def, muzzle_pos, aim_rad)
                        }
                    case .Rifle:
                        if rl.IsMouseButtonPressed(.LEFT) && inst.ammo_in_clip > 0 {
                            fire_bullet(inst, def, muzzle_pos, aim_rad)
                        }
                    case .Cannon:
                        if rl.IsMouseButtonDown(.LEFT) && inst.ammo_in_clip > 0 {
                            enter_state(inst, .Charging, def.charge_time)
                            rl.PlaySound(def.charge_sound)
                            inst.charge_sfx_playing = true
                        }
                    }
                }

            case .Switching:
                if inst.state_timer >= inst.state_duration {
                    st.current_weapon = inst.pending_weapon
                    enter_state(&st.weapons[inst.pending_weapon], .Idle, 0)
                }

            case .Firing:
                if inst.state_timer >= inst.state_duration {
                    should_auto_fire := (st.current_weapon == .SMG || st.current_weapon == .Tesla) && rl.IsMouseButtonDown(.LEFT) && inst.ammo_in_clip > 0
                    if should_auto_fire {
                        fire_bullet(inst, def, muzzle_pos, aim_rad)
                    } else {
                        enter_state(inst, .Idle, 0)
                    }
                }

            case .ClipDrop:
                if inst.state_timer >= inst.state_duration {
                    inst.ammo_in_clip = 0
                    if st.auto_reload && inst.ammo_reserve > 0 {
                        enter_state(inst, .ClipInsert, def.clip_insert_time)
                    } else {
                        enter_state(inst, .Idle, 0)
                    }
                }

            case .ClipInsert:
                if inst.state_timer >= inst.state_duration {
                    new_count := min(def.clip_size, inst.ammo_reserve)
                    inst.ammo_in_clip = new_count
                    inst.ammo_reserve -= new_count
                    enter_state(inst, .Idle, 0)
                }

            case .Charging:
                if rl.IsMouseButtonDown(.LEFT) {
                    charge_frac := inst.state_timer / inst.state_duration
                    st.camera_shake = max(st.camera_shake, 7 + 22 * charge_frac)
                    // Spawn converging charge particles
                    for _ in 0 ..< 3 {
                        ang := aim_rad + f32(rl.GetRandomValue(-750, 750)) / 1000.0
                        r := f32(rl.GetRandomValue(80, 130))
                        spawn := st.player.pos + Vec2{math.cos(ang), math.sin(ang)} * r
                        append(&st.particles, Particle{pos = spawn, vel = (muzzle_pos - spawn) * 1.3, radius = f32(rl.GetRandomValue(3, 6)), color = rl.SKYBLUE, max_age = f32(rl.GetRandomValue(22, 35)) / 100.0})
                    }
                } else {
                    // Released LMB
                    rl.StopSound(def.charge_sound)
                    inst.charge_sfx_playing = false
                    if inst.state_timer >= inst.state_duration {
                        // Fully charged → fire beam
                        inst.beam_angle = st.player.aim_angle
                        inst.ammo_in_clip -= 1
                        apply_player_kickback(math.to_radians(inst.beam_angle), def.kickback_impulse)
                        st.camera_shake = max(st.camera_shake, def.shake_impulse)
                        rl.PlaySound(def.sound)
                        enter_state(inst, .BeamActive, def.beam_duration)
                    } else {
                        enter_state(inst, .Idle, 0)
                    }
                }

            case .BeamActive:
                st.camera_shake = max(st.camera_shake, 55)
                beam_rad    := math.to_radians(inst.beam_angle)
                beam_dir    := Vec2{math.cos(beam_rad), math.sin(beam_rad)}
                beam_origin := st.player.pos + beam_dir * (st.player.radius + 15)
                for &e in st.entities {
                    if e.type != .Enemy {continue}
                    to_e  := e.pos - beam_origin
                    along := linalg.dot(to_e, beam_dir)
                    if along < 0 {continue}
                    if linalg.length(to_e - beam_dir * along) < def.beam_half_width + e.radius {
                        e.health -= def.beam_damage * dt
                        e.hit_flash = max(e.hit_flash, 0.06)
                        if rl.GetRandomValue(0, 100) < 10 {
                            spawn_hit_sparks(e.pos, rl.YELLOW, 2)
                        }
                    }
                }
                if inst.state_timer >= inst.state_duration {
                    enter_state(inst, .Cooldown, def.cooldown_time)
                }

            case .Cooldown:
                if inst.state_timer >= inst.state_duration {
                    enter_state(inst, .Idle, 0)
                }
            }

            // Decay visual effects (cosmetic, not state-gated)
            if inst.muzzle_flash_timer > 0 {inst.muzzle_flash_timer = max(0, inst.muzzle_flash_timer - dt)}
            if st.camera_shake > 0.1 {st.camera_shake *= math.pow(f32(0.78), dt * 60)} else {st.camera_shake = 0}
        }

        {     // Particles
            dt := rl.GetFrameTime()
            i := 0
            for i < len(st.particles) {
                p := &st.particles[i]
                p.pos += p.vel * dt
                p.age += dt
                dead := p.age >= p.max_age
                if p.damage > 0 && !dead {
                    for &e in st.entities {
                        if e.type == .Enemy && linalg.length(e.pos - p.pos) < e.radius + p.radius {
                            e.health -= p.damage
                            e.hit_flash = max(e.hit_flash, 0.16)
                            spawn_hit_sparks(p.pos, p.color, 5)
                            dead = true
                            break
                        }
                    }
                }
                if dead {unordered_remove(&st.particles, i)} else {i += 1}
            }
        }

        {     // Collision
            dt := rl.GetFrameTime()
            for i in 0 ..< len(st.entities) {
                for j in i + 1 ..< len(st.entities) {
                    a := &st.entities[i]
                    b := &st.entities[j]
                    if linalg.length(b.pos - a.pos) < a.radius + b.radius {
                        a.health -= b.damage * dt
                        b.health -= a.damage * dt
                        if b.damage > 0 {a.hit_flash = max(a.hit_flash, 0.1)}
                        if a.damage > 0 {b.hit_flash = max(b.hit_flash, 0.1)}
                    }
                }
            }
        }

        {     // Damage feedback decay
            dt := rl.GetFrameTime()
            for &e in st.entities {
                if e.hit_flash > 0 {
                    e.hit_flash = max(0, e.hit_flash - dt)
                }
            }
        }

        {     // Remove dead entities
            i := 0
            for i < len(st.entities) {
                if st.entities[i].type == .Enemy && st.entities[i].health <= 0 {
                    unordered_remove(&st.entities, i)
                } else {
                    i += 1
                }
            }
        }

        {     // Render
            rl.BeginDrawing()
            rl.ClearBackground(rl.BROWN)
            rl.BeginMode2D(st.camera)

            // Field guide lines
            rl.DrawLine(0, -5000, 0, 5000, rl.GREEN)
            rl.DrawLine(-5000, 0, 5000, 0, rl.GREEN)

            // Precompute aim vectors needed for render-time effects
            render_aim_rad := math.to_radians(st.player.aim_angle)
            render_aim_dir := Vec2{math.cos(render_aim_rad), math.sin(render_aim_rad)}
            render_muzzle  := st.player.pos + render_aim_dir * (st.player.radius + 15)

            // Particles
            for p in st.particles {
                rl.DrawCircleV(p.pos, p.radius, rl.Fade(p.color, 1 - p.age / p.max_age))
            }

            // Entities
            for e in st.entities {
                viz := VizDB[e.type]
                pos := e.pos
                scale := viz.tex_scale * e.radius
                flipH := (math.abs(e.aim_angle) > 90) if st.flip_by_aim else (e.vel.x < 0)

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
                if e.hit_flash > 0.01 {
                    tint = rl.Color{255, 165, 165, 255}
                }

                draw_tex(viz.texture, pos, scale, angle, flipH, tint)
                rl.DrawCircleLines(i32(e.pos.x), i32(e.pos.y), e.radius, rl.GREEN)
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
                        tip  := e.pos + Vec2{math.cos(aim_rad), math.sin(aim_rad)} * cone_len
                        left := e.pos + Vec2{math.cos(aim_rad - half_spread), math.sin(aim_rad - half_spread)} * cone_len
                        rgt  := e.pos + Vec2{math.cos(aim_rad + half_spread), math.sin(aim_rad + half_spread)} * cone_len
                        rl.DrawLine(i32(e.pos.x), i32(e.pos.y), i32(tip.x),  i32(tip.y),  rl.YELLOW)
                        rl.DrawLine(i32(e.pos.x), i32(e.pos.y), i32(left.x), i32(left.y), rl.YELLOW)
                        rl.DrawLine(i32(e.pos.x), i32(e.pos.y), i32(rgt.x),  i32(rgt.y),  rl.YELLOW)
                    }
                }
            }

            // Cannon charging: muzzle glow
            cannon_inst := st.weapons[.Cannon]
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

            // Muzzle flash (standard) or Tesla arc
            cur_inst := st.weapons[st.current_weapon]
            cur_def  := WeaponDB[st.current_weapon]
            if cur_inst.muzzle_flash_timer > 0 && cur_def.flash_duration > 0 {
                t    := cur_inst.muzzle_flash_timer / cur_def.flash_duration
                perp := Vec2{-math.sin(render_aim_rad), math.cos(render_aim_rad)}
                if cur_def.flash_size > 0 {
                    flen := cur_def.flash_size * (0.5 + t * 0.5)
                    fwid := cur_def.flash_size * 0.4 * t
                    tip  := render_muzzle + render_aim_dir * flen
                    rl.DrawTriangle(render_muzzle + perp * fwid, tip, render_muzzle - perp * fwid, rl.Fade(cur_def.bullet_color, t))
                    rl.DrawCircleV(render_muzzle + render_aim_dir * (flen * 0.75), fwid * 0.22, rl.Fade(rl.RAYWHITE, t * 0.65))
                } else {
                    // Tesla arc: 5 jagged segments
                    arc_len: f32 = 200
                    prev := render_muzzle
                    for s in 1 ..= 5 {
                        center := render_muzzle + render_aim_dir * (arc_len * f32(s) / 5)
                        offset := f32(rl.GetRandomValue(-30, 30))
                        next   := center + perp * offset
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

            // HUD
            hud_def  := WeaponDB[st.current_weapon]
            hud_inst := st.weapons[st.current_weapon]
            draw_text({10, 10}, 20, "FPS %d | HP %.0f", rl.GetFPS(), st.player.health)
            draw_text({10, 30}, 20, "WASD: move  LMB: fire  R: reload  scroll: zoom  [1-4]: weapon  T: flip-via-aim %v  Y: rotate %v  G: auto-reload %v", st.flip_by_aim, st.sprite_aim_rotate, st.auto_reload )
            switch hud_inst.state {
            case .Switching:   draw_text({10, 50}, 20, "SWITCHING...")
            case .ClipDrop:    draw_text({10, 50}, 20, "%v: DROPPING CLIP...", hud_def.name)
            case .ClipInsert:  draw_text({10, 50}, 20, "%v: RELOADING...", hud_def.name)
            case .Idle, .Firing, .Charging, .BeamActive, .Cooldown:
                draw_text({10, 50}, 20, "%v: %d / %d", hud_def.name, hud_inst.ammo_in_clip, hud_inst.ammo_reserve)
            }

            // Progress bar for timed states
            show_bar := false
            bar_frac: f32
            bar_color: rl.Color
            bar_label: string
            switch hud_inst.state {
            case .Switching:
                show_bar = true
                bar_frac = clamp(hud_inst.state_timer / hud_inst.state_duration, 0, 1)
                bar_color = rl.ORANGE
                bar_label = "SWITCHING"
            case .ClipDrop:
                show_bar = true
                bar_frac = clamp(hud_inst.state_timer / hud_inst.state_duration, 0, 1)
                bar_color = rl.ORANGE
                bar_label = "DROPPING CLIP"
            case .ClipInsert:
                show_bar = true
                bar_frac = clamp(hud_inst.state_timer / hud_inst.state_duration, 0, 1)
                bar_color = rl.SKYBLUE
                bar_label = "RELOADING"
            case .Charging:
                show_bar = true
                bar_frac = clamp(hud_inst.state_timer / hud_inst.state_duration, 0, 1)
                bar_color = rl.YELLOW if bar_frac >= 1 else rl.SKYBLUE
                bar_label = "MAXIMUM CHARGE!" if bar_frac >= 1 else "CHARGING..."
            case .Cooldown:
                show_bar = true
                bar_frac = 1 - clamp(hud_inst.state_timer / hud_inst.state_duration, 0, 1)
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
                rl.DrawRectangleLines(i32(cx), i32(cy), i32(barw), i32(barh), rl.RAYWHITE)
                draw_text({cx, cy - 24}, 18, bar_label)
            }

            rl.EndDrawing()
        }
    }
    cleanup_resources()
}
