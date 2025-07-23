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
    player : rl.Texture2D,
    crosshair : rl.Texture2D,
}
load_assets := proc() {
    assets.player = rl.LoadTexture( "res/char1.png" )
    assets.crosshair = rl.LoadTexture( "res/crosshair.png" )
}
Vec2 :: [2]f32
Vec2i :: [2]i32
GameState :: struct {
    render_size : Vec2,
    dpi_scaling : Vec2,
    camera : rl.Camera2D,

    mouse_pos : Vec2, // screen space
    crosshair_pos : Vec2, // world space

    player_pos : Vec2,
    player_rot : f32, // degrees
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

    for !rl.WindowShouldClose() {
        free_all( context.temp_allocator )

        { // Windowing and inputs that need correction before use
            st.render_size = vec2({ rl.GetRenderWidth(), rl.GetRenderHeight() })
            st.dpi_scaling = rl.GetWindowScaleDPI()
            st.mouse_pos = rl.GetMousePosition() * st.dpi_scaling // not DPI aware so we must fix
        }

        { // Camera
            st.camera.offset = st.render_size / 2 // if window resized, we must update camera offset based on render (not screen) size
            st.camera.target = st.player_pos // temp. follow player
        }

        { // Input - Aiming
            st.crosshair_pos = rl.GetScreenToWorld2D( st.mouse_pos, st.camera )
        }

        { // Player facing towards crosshair
            dir_aiming := st.crosshair_pos - st.player_pos
            st.player_rot = math.atan2( dir_aiming.y, dir_aiming.x ) // radians -π..π
            st.player_rot += math.PI / 2 // normalize so up along y-axis is 0 degrees
            if st.player_rot < 0 { st.player_rot += 2 * math.PI } // normalize to 0..2π
            st.player_rot = math.DEG_PER_RAD * st.player_rot // convert to degrees 0..360
        }

        //TODO player movement

        { // Render
            rl.BeginDrawing()
            rl.ClearBackground( rl.BROWN )
                rl.BeginMode2D( st.camera )
                    // temp. draw center of screen for reference
                    rl.DrawLine( 0, -5000, 0, 5000, rl.BLUE )
                    rl.DrawLine( -5000, 0, 5000, 0, rl.BLUE )

                    draw_tex( assets.player, st.player_pos, 0.1, st.player_rot )
                    draw_tex( assets.crosshair, st.crosshair_pos, 0.1, 0 )
                rl.EndMode2D()
            draw_text( {10,10}, 20, "FPS %d rend %v dpi %v mouse %v cross %v", rl.GetFPS(), st.render_size, st.dpi_scaling, st.mouse_pos, st.crosshair_pos )
            rl.EndDrawing()
        }
    }
}