#+feature dynamic-literals
package main
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"
import gl "vendor:raylib/rlgl"

DEBUG_MEMORY :: true

assets : AssetDB
st : GameState

AssetDB :: struct {
    player_topdown : rl.Texture2D,
    player_side : [2]rl.Texture2D,
    player_scale : f32,
    crosshair : rl.Texture2D,
    crosshair_scale : f32,
    player_walk : [4]rl.Texture2D,
    player_walk_scale : f32,
}
load_assets := proc() {
    assets.player_topdown = rl.LoadTexture( "res/char1.png" )
    assets.player_side[0] = rl.LoadTexture( "res/char2.png" )
    assets.player_side[1] = rl.LoadTexture( "res/char2_flipped.png" )
    assets.player_scale = 0.1/40

    assets.crosshair = rl.LoadTexture( "res/crosshair.png" )
    assets.crosshair_scale = 0.1/20

    if false {
        for i in 0..=3 {
            path := fmt.tprint( "res/char_walk_%d.png", i )
            cpath := strings.clone_to_cstring( path, context.temp_allocator )
            assets.player_walk[i] = rl.LoadTexture( cpath )
        }
        assets.player_walk_scale = 0.5/40
    }
}
Vec2 :: [2]f32
Vec2i :: [2]i32
GameState :: struct {
    render_size : Vec2,
    dpi_scaling : Vec2,
    camera : rl.Camera2D,

    mouse_pos : Vec2, // screen space
    crosshair_pos : Vec2, // world space
    crosshair_size : f32,

    player_pos : Vec2,
    player_rot : f32, // degrees
    player_size_topdown : f32,
    player_size_side : f32,
    player_speed : f32,

    anim_speed : f32,
    topdown_mode : bool,
}
vec2 :: proc( v: Vec2i ) -> Vec2 { return Vec2{ f32(v.x), f32(v.y) } }
vec2i :: proc( v: Vec2 ) -> Vec2i { return Vec2i{ i32(v.x), i32(v.y) } }

draw_text :: proc( pos: Vec2, size: f32, fmtstring: string, args: ..any ) {
    s := fmt.tprintf( fmtstring, ..args )
    cs := strings.clone_to_cstring( s, context.temp_allocator )
    rl.DrawText( cs, i32(pos.x), i32(pos.y), i32(size), rl.RAYWHITE )
}
draw_tex :: proc( tex: rl.Texture2D, pos: Vec2, scale: f32, angle: f32 ) {
    src_size := vec2({ tex.width, tex.height })
    src_rect := rl.Rectangle{ 0, 0, src_size.x, src_size.y }
    dest_size := src_size * scale
    dest_rect := rl.Rectangle{ pos.x, pos.y, dest_size.x, dest_size.y }
    rl.DrawTexturePro( tex, src_rect, dest_rect, dest_size/2, angle, rl.WHITE )
}

main :: proc() {
    when DEBUG_MEMORY {
        tracking_allocator : mem.Tracking_Allocator
        mem.tracking_allocator_init( &tracking_allocator, context.allocator )
        context.allocator = mem.tracking_allocator( &tracking_allocator )

        print_alloc_stats := proc( tracking: ^mem.Tracking_Allocator ) {
            for _, entry in tracking.allocation_map {
                fmt.printfln( "%v: Leaked %v bytes", entry.location, entry.size )
            }
            for entry in tracking.bad_free_array {
                fmt.printfln( "%v: Bad free @ %v", entry.location, entry.memory )
            }
            fmt.printfln( "Total Allocated: %d bytes", tracking.total_memory_allocated )
        }
        defer { print_alloc_stats( &tracking_allocator ) }
    }

    rl.SetConfigFlags({ .WINDOW_HIGHDPI, .MSAA_4X_HINT, .WINDOW_RESIZABLE, })
    rl.InitWindow( 1920, 1080, "Twin" )
    rl.SetTargetFPS( 120 )
    rl.HideCursor()
    load_assets()
    st.camera.zoom = 1.0
    st.player_size_topdown = 40
    st.player_size_side = 40*5
    st.crosshair_size = 20
    st.player_speed = 700.0
    st.anim_speed = 15.0

    last_move_dir : Vec2

    for !rl.WindowShouldClose() {
        free_all( context.temp_allocator )

        { // Windowing and inputs that need correction before use
            st.render_size = vec2({ rl.GetRenderWidth(), rl.GetRenderHeight() })
            st.dpi_scaling = rl.GetWindowScaleDPI()
            st.mouse_pos = rl.GetMousePosition() * st.dpi_scaling // not DPI aware so we must fix
        }

        { // Camera
            st.camera.offset = st.render_size / 2 // if window resized, we must update camera offset based on render (not screen) size
            st.camera.target = st.player_pos // follow player
        }

        { // Input - Aiming
            st.crosshair_pos = rl.GetScreenToWorld2D( st.mouse_pos, st.camera )
        }

        if rl.IsKeyPressed( .T ) {
            st.topdown_mode = !st.topdown_mode
            st.player_rot = 0
        }

        if st.topdown_mode { // Player facing towards crosshair
            dir_aiming := st.crosshair_pos - st.player_pos
            st.player_rot = math.atan2( dir_aiming.y, dir_aiming.x ) // radians -π..π
            st.player_rot += math.PI / 2 // normalize so up along y-axis is 0 degrees
            if st.player_rot < 0 { st.player_rot += 2 * math.PI } // normalize to 0..2π
            st.player_rot = math.DEG_PER_RAD * st.player_rot // convert to degrees 0..360
        }

        
        dir_input : Vec2
        walk_anim : f32
        { // Movement
            if rl.IsKeyDown( .W ) { dir_input.y -= 1 }
            if rl.IsKeyDown( .S ) { dir_input.y += 1 }
            if rl.IsKeyDown( .A ) { dir_input.x -= 1 }
            if rl.IsKeyDown( .D ) { dir_input.x += 1 }
            if dir_input != {0,0} {
                dir_input = linalg.normalize( dir_input ) // normalize to unit vector
                walk_anim = 1.0
            }
            last_move_dir = dir_input
            st.player_pos += dir_input * st.player_speed * rl.GetFrameTime()
        }

        player_pos : Vec2
        { // Player animation
            st.anim_speed += rl.GetMouseWheelMove() * 1.0
            walk_anim = st.anim_speed * walk_anim
            player_pos = st.player_pos
            player_pos.y += math.sin( f32( rl.GetTime() ) * walk_anim ) * 5.0 // bobbing effect
        }

        { // Render
            rl.BeginDrawing()
            rl.ClearBackground( rl.BROWN )
                rl.BeginMode2D( st.camera )
                    // temp. draw center of screen for reference
                    rl.DrawLine( 0, -5000, 0, 5000, rl.GREEN )
                    rl.DrawLine( -5000, 0, 5000, 0, rl.GREEN )

                    if st.topdown_mode {
                        rl.DrawCircleLines( i32(st.player_pos.x), i32(st.player_pos.y), st.player_size_topdown, rl.GREEN )
                        draw_tex( assets.player_topdown, player_pos, st.player_size_topdown * assets.player_scale, st.player_rot )
                    } else {
                        rl.DrawCircleLines( i32(st.player_pos.x), i32(st.player_pos.y), st.player_size_side, rl.GREEN )
                        if last_move_dir.x < 0 { // facing left
                            draw_tex( assets.player_side[1], player_pos, st.player_size_side * assets.player_scale, st.player_rot )
                        } else { // facing right
                            draw_tex( assets.player_side[0], player_pos, st.player_size_side * assets.player_scale, st.player_rot )
                        }
                    }
                    rl.DrawCircleLines( i32(st.crosshair_pos.x), i32(st.crosshair_pos.y), st.crosshair_size, rl.GREEN )
                    draw_tex( assets.crosshair, st.crosshair_pos, st.crosshair_size * assets.crosshair_scale, 0 )

                rl.EndMode2D()
            draw_text( {10,10}, 20, "FPS %d pos %v cross %v wasd %v anim_speed %v", rl.GetFPS(), st.player_pos, st.crosshair_pos, dir_input, st.anim_speed )
            rl.EndDrawing()
        }
    }
}