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
}

vec2 :: proc(v: Vec2i) -> Vec2 {return Vec2{f32(v.x), f32(v.y)}}
vec2i :: proc(v: Vec2) -> Vec2i {return Vec2i{i32(v.x), i32(v.y)}}

draw_text :: proc(pos: Vec2, size: f32, fmtstring: string, args: ..any) {
    s := fmt.tprintf(fmtstring, ..args)
    cs := strings.clone_to_cstring(s, context.temp_allocator)
    rl.DrawText(cs, i32(pos.x), i32(pos.y), i32(size), rl.RAYWHITE)
}
draw_tex :: proc(tex: rl.Texture2D, pos: Vec2, scale: Vec2, angle: f32, flipH: bool = false) {
    src_size := vec2({tex.width, tex.height})
    src_rect := rl.Rectangle{0, 0, src_size.x if !flipH else -src_size.x, src_size.y}
    dest_size := src_size * scale
    dest_rect := rl.Rectangle{pos.x, pos.y, dest_size.x, dest_size.y}
    rl.DrawTexturePro(tex, src_rect, dest_rect, dest_size / 2, angle, rl.WHITE)
}

VizDB := [EntityType]VisualData {
    .Player    = VisualData{tex_path = "res/char3.png", tex_scale = Vec2{1, 1} / 300, bob_speed = 15.0, bob_magnitude = 5.0, squash_speed = 2.0, squash_magnitude = 0.25, squash_baseline = 0.9},
    .Enemy     = VisualData{tex_path = "res/enemy.png", tex_scale = Vec2{1, 1} / 300, bob_speed = 10.0, bob_magnitude = 4.0, squash_speed = 1.5, squash_magnitude = 0.2, squash_baseline = 0.8},
    .Crosshair = VisualData{tex_path = "res/crosshair.png", tex_scale = Vec2{1, 1} / 200, bob_speed = 0.0, bob_magnitude = 0.0, squash_speed = 0.0, squash_magnitude = 0.0, squash_baseline = 0.0},
}
st := GameState {
    camera = rl.Camera2D{zoom = 1.0},
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

    // Initialize assets
    for &viz in VizDB {
        path := strings.clone_to_cstring(viz.tex_path, context.temp_allocator)
        viz.texture = rl.LoadTexture(path)
    }

    // Initialize game state
    append(&st.entities, Entity{id = len(st.entities), type = .Player, radius = 50, max_vel = {700, 700}, health = 100, max_health = 100})
    append(&st.entities, Entity{id = len(st.entities), type = .Crosshair, radius = 20})
    for _ in 1 ..= 10 {
        enemy := Entity{id = len(st.entities), type = .Enemy, radius = 50, max_vel = {40, 40}, health = 50, max_health = 50, damage = 10}
        append(&st.entities, enemy)
    }
    st.player = &st.entities[0]
    st.crosshair = &st.entities[1]

    for !rl.WindowShouldClose() {
        free_all(context.temp_allocator)

        {     // Windowing and inputs that need correction before use
            st.render_size = vec2({rl.GetRenderWidth(), rl.GetRenderHeight()})
            st.dpi_scaling = rl.GetWindowScaleDPI()
            st.mouse_pos = rl.GetMousePosition() * st.dpi_scaling // not DPI aware so we must fix
            if rl.IsKeyPressed(.Y) {st.sprite_aim_rotate = !st.sprite_aim_rotate}
        }

        {     // Camera
            st.camera.offset = st.render_size / 2 // if window resized, we must update camera offset based on render (not screen) size
            st.camera.target = st.player.pos // follow player
            st.camera.zoom = clamp(st.camera.zoom + rl.GetMouseWheelMove() * 0.1, 0.1, 10.0) // zoom in/out with mouse wheel
        }

        dir_input: Vec2
        {     // Movement
            if rl.IsKeyDown(.W) {dir_input.y -= 1}
            if rl.IsKeyDown(.S) {dir_input.y += 1}
            if rl.IsKeyDown(.A) {dir_input.x -= 1}
            if rl.IsKeyDown(.D) {dir_input.x += 1}

            accel_per_sec := st.player.max_vel * (1 - FrictionGroundPerTick) * 35.0
            st.player.vel += dir_input * accel_per_sec * rl.GetFrameTime()
            st.player.vel = st.player.vel * math.pow(FrictionGroundPerSec, rl.GetFrameTime())
            st.player.pos += st.player.vel * rl.GetFrameTime()
        }

        {     // Aiming
            st.crosshair.pos = rl.GetScreenToWorld2D(st.mouse_pos, st.camera)
            dir := st.crosshair.pos - st.player.pos
            st.player.aim_angle = math.to_degrees(math.atan2(dir.y, dir.x))
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
                    }
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

            for e in st.entities {
                viz := VizDB[e.type]
                pos := e.pos
                scale := viz.tex_scale * e.radius
                flipH := e.vel.x < 0
                angle: f32 = 0
                if st.sprite_aim_rotate {angle = e.aim_angle}

                if e.type != .Crosshair { // Bobbing effect
                    pos.y += math.sin(f32(rl.GetTime()) * viz.bob_speed) * viz.bob_magnitude
                }
                if e.type != .Crosshair { // Squash and stretch effect
                    squash := math.abs(math.sin(f32(rl.GetTime()) * viz.squash_speed)) * viz.squash_magnitude + viz.squash_baseline
                    stretch := 2 - squash
                    scale *= {stretch, squash}
                }

                draw_tex(viz.texture, pos, scale, angle, flipH)
                rl.DrawCircleLines(i32(e.pos.x), i32(e.pos.y), e.radius, rl.GREEN)

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

            rl.EndMode2D()
            draw_text({10, 10}, 20, "FPS %d | HP %.0f", rl.GetFPS(), st.player.health)
            draw_text({10, 30}, 20, "WASD: move | scroll: zoom | Y: toggle aim rotate")
            rl.EndDrawing()
        }
    }
    // Cleanup
    delete(st.entities)
    for &viz in VizDB {rl.UnloadTexture(viz.texture)}
    rl.CloseWindow()
}
