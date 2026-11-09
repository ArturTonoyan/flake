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
        float r2 = dot(d, d);
        if (r2 > 0.25) discard_fragment();
        float soft = smoothstep(0.25, 0.02, r2);
        return float4(1.0, 1.0, 1.0, soft * in.opacity);
    }

    vertex FlakeOut ball_vertex(
        const device float4 *balls [[buffer(0)]],
        constant FrameUniforms &frame [[buffer(1)]],
        uint vid [[vertex_id]]
    ) {
        float4 b = balls[vid];
        float2 local = (b.xy - frame.origin) / frame.size;
        FlakeOut out;
        if (local.x < -0.08 || local.x > 1.08 || local.y < -0.08 || local.y > 1.08) {
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
        out.pointSize = max(minPx, b.z * frame.scalePad.x);
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
    """
}
