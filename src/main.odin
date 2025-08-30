#+feature dynamic-literals
package main
import "core:fmt"
import "core:log"
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
FrictionGroundPerTick := 0.90625 // Doom style, per 35hz tic, applied to current speed
FrictionGroundPerSec := math.pow( FrictionGroundPerTick, 35.0 )
FrictionSlowdownAir :: 0.9727 // doom style, per 35hz tic, applied to current speed

Vec2 :: [2]f32
Vec2i :: [2]i32
EntityType :: enum {
    Player,
    Enemy,
    Crosshair,
}
VisualData :: struct {
    texture : rl.Texture2D,
    tex_path : string,
    tex_scale : Vec2,           // to normalize texture to appropriate size
    bob_speed : f32,
    bob_magnitude : f32,
    squash_speed : f32,
    squash_magnitude : f32,
    squash_baseline : f32,
}
Entity :: struct {
    id : int,
    type : EntityType,
    pos : Vec2,
    vel : Vec2,
    radius : f32,
    aim_angle : f32, // degrees, can be independent of movement

    max_vel : Vec2,
    accel : Vec2,
}
GameState :: struct {
    render_size : Vec2,
    dpi_scaling : Vec2,
    mouse_pos : Vec2, // screen space

    camera : rl.Camera2D,
    entities : [dynamic]Entity,
}

vec2 :: proc( v: Vec2i ) -> Vec2 { return Vec2{ f32(v.x), f32(v.y) } }
vec2i :: proc( v: Vec2 ) -> Vec2i { return Vec2i{ i32(v.x), i32(v.y) } }

draw_text :: proc( pos: Vec2, size: f32, fmtstring: string, args: ..any ) {
    s := fmt.tprintf( fmtstring, ..args )
    cs := strings.clone_to_cstring( s, context.temp_allocator )
    rl.DrawText( cs, i32(pos.x), i32(pos.y), i32(size), rl.RAYWHITE )
}
draw_tex :: proc( tex: rl.Texture2D, pos: Vec2, scale: Vec2, angle: f32, flipH: bool = false ) {
    src_size := vec2({ tex.width, tex.height })
    src_rect := rl.Rectangle{ 0, 0, src_size.x if !flipH else -src_size.x, src_size.y }
    dest_size := src_size * scale
    dest_rect := rl.Rectangle{ pos.x, pos.y, dest_size.x, dest_size.y }
    rl.DrawTexturePro( tex, src_rect, dest_rect, dest_size/2, angle, rl.WHITE )
}

VizDB := [EntityType]VisualData{
    .Player = VisualData{
        tex_path = "res/char3.png",
        tex_scale = Vec2{ 1, 1 } / 300,
        bob_speed = 15.0,
        bob_magnitude = 5.0,
        squash_speed = 2.0,
        squash_magnitude = 0.25,
        squash_baseline = 0.9,
    },
    .Enemy = VisualData{
        tex_path = "res/enemy.png",
        tex_scale = Vec2{ 1, 1 } / 400,
        bob_speed = 10.0,
        bob_magnitude = 4.0,
        squash_speed = 1.5,
        squash_magnitude = 0.2,
        squash_baseline = 0.8,
    },
    .Crosshair = VisualData{
        tex_path = "res/crosshair.png",
        tex_scale = Vec2{ 1, 1 } / 200,
        bob_speed = 0.0,
        bob_magnitude = 0.0,
        squash_speed = 0.0,
        squash_magnitude = 0.0,
        squash_baseline = 0.0,
    },
}
st := GameState {
    camera = rl.Camera2D{ zoom = 1.0, }
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

    // Initialize assets
    for &viz in VizDB {
        path := strings.clone_to_cstring( viz.tex_path, context.temp_allocator )
        viz.texture = rl.LoadTexture( path )
    }

    // Initialize game state
    append( &st.entities, Entity{ id=len(st.entities), type=.Player, radius=50, max_vel={ 700, 700 }, accel={ 500, 500 } } )
    append( &st.entities, Entity{ id=len(st.entities), type=.Crosshair, radius=20, } )
    for i in 1..=10 {
        //enemy := Entity{ id=len(st.entities), type=.Enemy, radius=15, max_vel={ 40, 40 }, accel={ 8, 8 } }
        //append( &st.entities, enemy )
    }

    for !rl.WindowShouldClose() {
        free_all( context.temp_allocator )

        // References to key entities (temp hack)
        player := &st.entities[0]
        crosshair := &st.entities[1]

        { // Windowing and inputs that need correction before use
            st.render_size = vec2({ rl.GetRenderWidth(), rl.GetRenderHeight() })
            st.dpi_scaling = rl.GetWindowScaleDPI()
            st.mouse_pos = rl.GetMousePosition() * st.dpi_scaling // not DPI aware so we must fix
        }

        { // Camera
            st.camera.offset = st.render_size / 2 // if window resized, we must update camera offset based on render (not screen) size
            st.camera.target = player.pos // follow player
            st.camera.zoom = clamp( st.camera.zoom + rl.GetMouseWheelMove() * 0.1, 0.1, 10.0 ) // zoom in/out with mouse wheel
        }

        { // Aiming
            crosshair.pos = rl.GetScreenToWorld2D( st.mouse_pos, st.camera )
        }

        dir_input : Vec2
        { // Movement
            if rl.IsKeyDown( .W ) { dir_input.y -= 1 }
            if rl.IsKeyDown( .S ) { dir_input.y += 1 }
            if rl.IsKeyDown( .A ) { dir_input.x -= 1 }
            if rl.IsKeyDown( .D ) { dir_input.x += 1 }
            //if dir_input != {0,0} { dir_input = linalg.normalize( dir_input ) } // For now, try old school where diag is faster

            fric_per_tick : f32 = 0.90625
            fric_per_sec : f32 = math.pow( fric_per_tick, 35.0 )
            accel_per_tick := player.max_vel * (1-fric_per_tick)
            accel_per_sec := accel_per_tick * 35.0

            player.vel += dir_input * accel_per_sec * rl.GetFrameTime()
            player.vel = player.vel * math.pow( fric_per_sec, rl.GetFrameTime() )
            player.pos += player.vel * rl.GetFrameTime()

            // This is effectively enforced by the nature of acceleration and friction
            //player.vel.x = clamp( player.vel.x, -player.max_vel.x, player.max_vel.x )
            //player.vel.y = clamp( player.vel.y, -player.max_vel.y, player.max_vel.y )
        }

        { // Render
            rl.BeginDrawing()
            rl.ClearBackground( rl.BROWN )
                rl.BeginMode2D( st.camera )
                    rl.DrawLine( 0, -5000, 0, 5000, rl.GREEN )
                    rl.DrawLine( -5000, 0, 5000, 0, rl.GREEN )
                    for e in st.entities {
                        viz := VizDB[ e.type ]
                        pos := e.pos
                        scale := viz.tex_scale * e.radius
                        angle := e.aim_angle
                        flipH := e.vel.x < 0 // flip horizontally if moving left

                        // Maybe only animate if moving?

                        if e.type != .Crosshair { // Bobbing effect
                            pos.y += math.sin( f32( rl.GetTime() ) * viz.bob_speed ) * viz.bob_magnitude
                        }
                        if e.type != .Crosshair { // Squash and stretch effect
                            squash := math.abs( math.sin( f32( rl.GetTime() ) * viz.squash_speed ) ) * viz.squash_magnitude + viz.squash_baseline
                            stretch := 2 - squash
                            scale *= { stretch, squash }
                        }

                        draw_tex( viz.texture, pos, scale, angle, flipH )
                        rl.DrawCircleLines( i32(e.pos.x), i32(e.pos.y), e.radius, rl.GREEN )
                    }
                rl.EndMode2D()
            draw_text( {10,10}, 20, "FPS %d wasd %v vel %v / maxvel %v + accel %v", rl.GetFPS(), dir_input, player.vel, player.max_vel, player.accel )
            draw_text( {10,30}, 20, "Mousesheel to change animation speed, T to toggle topdown mode" )
            rl.EndDrawing()
        }
    }
    // Cleanup
    delete( st.entities )
    for &viz in VizDB { rl.UnloadTexture( viz.texture ) }
    rl.CloseWindow()
}
