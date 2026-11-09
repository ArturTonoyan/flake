enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Simulation uses global Cocoa points. Each screen view maps a rect into NDC.
    struct FrameUniforms {
        float2 origin;   // screen origin in global Cocoa points
        float2 size;     // screen size in points
        float4 scalePad; // .x = backing scale (pointSize is in pixels)
    };

    struct FlakeOut {
        float4 position [[position]];
        float pointSize [[point_size]];
        float opacity;
    };

    vertex FlakeOut flake_vertex(
        const device float4 *flakes [[buffer(0)]],
        constant FrameUniforms &frame [[buffer(1)]],
        uint vid [[vertex_id]]
    ) {
        float4 f = flakes[vid];
        float2 pos = f.xy;
        float2 local = (pos - frame.origin) / frame.size;
        FlakeOut out;
        // Cull points from other monitors — otherwise Metal clamps them to the edge
        // and snowflakes "appear from nowhere" on the neighboring display.
        if (local.x < -0.02 || local.x > 1.02 || local.y < -0.02 || local.y > 1.02) {
            out.position = float4(0.0, 0.0, -1.0, 0.0);
            out.pointSize = 0.0;
            out.opacity = 0.0;
            return out;
        }
        float2 ndc = local * 2.0 - 1.0;
        out.position = float4(ndc, 0.0, 1.0);
        out.pointSize = max(1.5, f.z * 2.0) * frame.scalePad.x;
        out.opacity = f.w;
        return out;
    }

    fragment float4 flake_fragment(
        FlakeOut in [[stage_in]],
        float2 pc [[point_coord]]
    ) {
        float2 d = pc - float2(0.5);
        float r = length(d) * 2.0;
        if (r > 1.0) discard_fragment();

        // Soft crystal: bright core + faint 6-fold arms + cool bloom.
        float ang = atan2(d.y, d.x);
        float spokes = pow(abs(cos(ang * 3.0)), 5.0);
        float core = smoothstep(1.0, 0.18, r);
        float arms = spokes * smoothstep(1.0, 0.28, r) * 0.48;
        float bloom = exp(-r * r * 3.2) * 0.42;
        float shape = clamp(core * 0.9 + arms + bloom, 0.0, 1.0);

        float3 cool = float3(0.78, 0.88, 1.0);
        float3 warm = float3(1.0, 1.0, 1.0);
        float3 color = mix(cool, warm, core);
        return float4(color, shape * in.opacity);
    }

    vertex FlakeOut ball_vertex(
        const device float4 *balls [[buffer(0)]],
        constant FrameUniforms &frame [[buffer(1)]],
        uint vid [[vertex_id]]
    ) {
        float4 b = balls[vid];
        float2 local = (b.xy - frame.origin) / frame.size;
        FlakeOut out;
        // Wide margin so large rolled snowballs / tiled LAN hits near edges still draw.
        if (local.x < -0.35 || local.x > 1.35 || local.y < -0.35 || local.y > 1.35) {
            out.position = float4(0.0, 0.0, -1.0, 0.0);
            out.pointSize = 0.0;
            out.opacity = 0.0;
            return out;
        }
        float2 ndc = local * 2.0 - 1.0;
        out.position = float4(ndc, 0.0, 1.0);
        // b.z = diameter in points → pixels via scale.
        // Decor (eyes/buttons) must stay tiny — no large minimum clamp.
        float minPx = (b.w > 1.5) ? 2.0 : 10.0;
        // Hardware point-size clamp is typically ~512px; keep request sane.
        out.pointSize = min(512.0, max(minPx, b.z * frame.scalePad.x));
        out.opacity = b.w;
        return out;
    }

    // Soft lit snowball. opacity > 1.5 → decor (2=coal, 3=carrot).
    fragment float4 ball_fragment(
        FlakeOut in [[stage_in]],
        float2 pc [[point_coord]]
    ) {
        float2 d = pc - float2(0.5);
        float r = length(d) * 2.0;
        if (r > 1.0) discard_fragment();

        // Sharper edge for tiny decor; softer for snow body.
        float edge = (in.opacity > 1.5)
            ? smoothstep(1.0, 0.82, r)
            : smoothstep(1.0, 0.72, r);

        // Decor markers via opacity: 2=coal, ~2.4=twig, 3=carrot. Body uses opacity <= 1.
        if (in.opacity > 1.5) {
            float3 color;
            if (in.opacity > 2.7) {
                color = float3(1.0, 0.52, 0.12);       // carrot
            } else if (in.opacity > 2.15) {
                color = float3(0.38, 0.24, 0.12);      // twig
            } else {
                color = float3(0.06, 0.06, 0.07);      // coal
            }
            return float4(color, edge);
        }

        // Peer snow stain / burst grit: flatter wet blotch (opacity kept below ~0.88).
        if (in.opacity < 0.88) {
            float wet = smoothstep(1.0, 0.15, r);
            float3 color = mix(float3(0.78, 0.86, 0.95), float3(0.97, 0.99, 1.0), wet);
            float alpha = wet * clamp(in.opacity, 0.0, 1.0);
            return float4(color, alpha);
        }

        // Round soft snowball: cool shade at bottom, bright body, top-left highlight.
        float shade = smoothstep(-0.55, 0.75, d.y);
        float3 body = mix(float3(0.72, 0.80, 0.90), float3(0.98, 0.99, 1.0), shade);
        float2 hl = d - float2(-0.22, 0.28);
        float highlight = exp(-dot(hl, hl) * 18.0) * 0.45;
        float ambient = 0.08;
        float3 color = body + highlight + ambient;
        // Slight blue rim so it reads as snow, not a flat disc.
        float rim = smoothstep(0.55, 0.98, r);
        color = mix(color, float3(0.78, 0.86, 0.95), rim * 0.22);
        float alpha = edge * clamp(in.opacity, 0.0, 1.0);
        return float4(color, alpha);
    }

    struct DriftIn {
        float2 position [[attribute(0)]];
        float4 color [[attribute(1)]];
    };

    struct DriftOut {
        float4 position [[position]];
        float4 color;
    };

    vertex DriftOut drift_vertex(
        DriftIn in [[stage_in]],
        constant FrameUniforms &frame [[buffer(1)]]
    ) {
        float2 local = (in.position - frame.origin) / frame.size;
        DriftOut out;
        if (local.x < -0.02 || local.x > 1.02 || local.y < -0.02 || local.y > 1.02) {
            out.position = float4(0.0, 0.0, -1.0, 0.0);
            out.color = float4(0.0);
            return out;
        }
        float2 ndc = local * 2.0 - 1.0;
        out.position = float4(ndc, 0.0, 1.0);
        out.color = in.color;
        return out;
    }

    fragment float4 drift_fragment(DriftOut in [[stage_in]]) {
        return in.color;
    }

    // Large snowballs as triangle fans — same look as ball_fragment, any size.
    struct SoftBallIn {
        float2 position [[attribute(0)]];
        float4 localOp  [[attribute(1)]]; // xy = disk local [-1,1], z = opacity
    };

    struct SoftBallOut {
        float4 position [[position]];
        float2 local;
        float opacity;
    };

    vertex SoftBallOut softball_vertex(
        SoftBallIn in [[stage_in]],
        constant FrameUniforms &frame [[buffer(1)]]
    ) {
        float2 local = (in.position - frame.origin) / frame.size;
        SoftBallOut out;
        if (local.x < -0.55 || local.x > 1.55 || local.y < -0.55 || local.y > 1.55) {
            out.position = float4(0.0, 0.0, -1.0, 0.0);
            out.local = float2(0.0);
            out.opacity = 0.0;
            return out;
        }
        float2 ndc = local * 2.0 - 1.0;
        out.position = float4(ndc, 0.0, 1.0);
        out.local = in.localOp.xy;
        out.opacity = in.localOp.z;
        return out;
    }

    fragment float4 softball_fragment(SoftBallOut in [[stage_in]]) {
        float2 d = in.local;
        float r = length(d);
        if (r > 1.0) discard_fragment();

        // Soft wet splat / shock (same idea as ball_fragment stain path).
        if (in.opacity < 0.88) {
            float wet = smoothstep(1.0, 0.18, r);
            float3 color = mix(float3(0.78, 0.86, 0.95), float3(0.97, 0.99, 1.0), wet);
            float alpha = wet * clamp(in.opacity, 0.0, 1.0);
            return float4(color, alpha);
        }

        float edge = smoothstep(1.0, 0.70, r);

        // Soft volume shade — cooler / denser toward the bottom.
        float shade = smoothstep(-0.62, 0.78, d.y);
        float3 body = mix(float3(0.70, 0.79, 0.90), float3(0.99, 0.995, 1.0), shade);

        // Specular snow glint (top-left).
        float2 hl = d - float2(-0.20, 0.30);
        float highlight = exp(-dot(hl, hl) * 16.0) * 0.42;
        // Soft fill light from above.
        float fill = exp(-dot(d - float2(0.08, 0.55), d - float2(0.08, 0.55)) * 6.0) * 0.10;

        // Fine snow grain so big balls don't look like plastic.
        float n1 = fract(sin(dot(d * 31.7, float2(12.9898, 78.233))) * 43758.5453);
        float n2 = fract(sin(dot(d * 73.1, float2(39.346, 11.135))) * 23421.631);
        float grain = (n1 - 0.5) * 0.055 + (n2 - 0.5) * 0.025;
        float fleck = smoothstep(0.88, 1.0, n1) * 0.07;

        float3 color = body + highlight + fill + grain + fleck;
        // Cool rim / subsurface.
        float rim = smoothstep(0.48, 0.98, r);
        color = mix(color, float3(0.76, 0.86, 0.96), rim * 0.28);
        // Slight self-shadow under the equator.
        float under = smoothstep(0.15, -0.75, d.y);
        color *= (1.0 - under * 0.10);

        float alpha = edge * clamp(in.opacity, 0.0, 1.0);
        // Softer outer halo so the edge reads fluffy.
        float halo = smoothstep(1.0, 0.88, r) * 0.18 * clamp(in.opacity, 0.0, 1.0);
        alpha = max(alpha, halo * edge);
        return float4(color, alpha);
    }
    """
}
