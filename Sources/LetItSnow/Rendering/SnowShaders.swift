import Foundation

enum SnowShaderSource {
    static let metalLibrarySource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewportSize;
        float time;
        float sparkleEnabled;
        float4 tintColor;
        float4 shadowTint;
    };

    // MARK: - Instanced Snowflakes

    struct FlakeInstance {
        float2 center;
        float radius;
        float rotation;
        float opacity;
        float kind;       // 0 = powder, 1 = crystal, 2 = clump
        float foreground; // 0 or 1
        float pad;
    };

    struct FlakeOut {
        float4 position [[position]];
        float2 uv;
        float opacity;
        float kind;
        float foreground;
        float radius;
    };

    vertex FlakeOut flakeVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant Uniforms& u [[buffer(0)]],
        const device FlakeInstance* flakes [[buffer(1)]]
    ) {
        const float2 corners[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };

        FlakeInstance f = flakes[instanceID];
        float2 local = corners[vertexID];

        float padScale = (f.kind > 0.5 && f.kind < 1.5) ? 1.45 : 1.25;
        float halfSize = max(1.5, f.radius * padScale);
        float2 screenPos = f.center + local * halfSize;

        float2 ndc;
        ndc.x = (screenPos.x / u.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (screenPos.y / u.viewportSize.y) * 2.0;

        float c = cos(f.rotation);
        float s = sin(f.rotation);
        float2 rotUV = float2(
            local.x * c - local.y * s,
            local.x * s + local.y * c
        ) * padScale;

        FlakeOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = rotUV;
        out.opacity = f.opacity;
        out.kind = f.kind;
        out.foreground = f.foreground;
        out.radius = f.radius;
        return out;
    }

    float sdSegment(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }

    fragment float4 flakeFragment(
        FlakeOut in [[stage_in]],
        constant Uniforms& u [[buffer(0)]]
    ) {
        float2 p = in.uv;
        float r2 = dot(p, p);
        if (r2 > 1.25) discard_fragment();
        float r = sqrt(r2);
        float alpha = 0.0;

        if (in.kind < 0.5) {
            // Soft powder flake
            float softness = mix(0.58, 0.85, in.foreground);
            alpha = smoothstep(1.0, 1.0 - softness, r);
            alpha = pow(alpha, 1.35);
        } else if (in.kind < 1.5) {
            // 6-pointed crystalline dendrite snowflake
            if (r > 1.15) discard_fragment();
            float angle = atan2(p.y, p.x);
            float sector = 3.14159265 / 3.0;
            float folded = abs(fmod(angle + 3.14159265 + sector * 0.5, sector) - sector * 0.5);
            float2 fp = float2(cos(folded), sin(folded)) * r;

            float stroke = max(0.065, 0.14 / max(1.0, in.radius * 0.45));
            float dMain = sdSegment(fp, float2(0.0, 0.0), float2(0.92, 0.0));
            float dBranch1 = sdSegment(fp, float2(0.38, 0.0), float2(0.62, 0.24));
            float dBranch2 = sdSegment(fp, float2(0.66, 0.0), float2(0.84, 0.16));
            float dCenter = length(fp) - 0.14;

            float d = min(min(dMain, dCenter), min(dBranch1, dBranch2));
            float crystal = 1.0 - smoothstep(stroke * 0.5, stroke * 1.45, d);
            float coreGlow = smoothstep(0.95, 0.0, r) * 0.28;
            alpha = clamp(crystal + coreGlow, 0.0, 1.0);
        } else {
            // Fluffy snow clump (3 overlapping soft lobes)
            float d1 = length(p - float2(-0.18,  0.10)) / 0.72;
            float d2 = length(p - float2( 0.22,  0.08)) / 0.68;
            float d3 = length(p - float2( 0.00, -0.20)) / 0.74;
            float d = min(d1, min(d2, d3));
            alpha = smoothstep(1.05, 0.35, d);
        }

        alpha *= in.opacity;
        if (alpha <= 0.004) discard_fragment();

        float3 col = mix(u.shadowTint.rgb, u.tintColor.rgb, smoothstep(1.0, 0.15, r) * 0.7 + 0.3);
        return float4(col * alpha, alpha);
    }

    // MARK: - Accumulated Snow Caps (Triangle Strips)

    struct PileVertex {
        float2 pos;
        float edgeFrac; // 0 = bottom contact, 1 = top crest
        float heightNorm;
        float sparkleSeed;
        float pad;
    };

    struct PileOut {
        float4 position [[position]];
        float edgeFrac;
        float heightNorm;
        float sparkleSeed;
        float2 screenPos;
    };

    vertex PileOut pileVertex(
        uint vertexID [[vertex_id]],
        constant Uniforms& u [[buffer(0)]],
        const device PileVertex* verts [[buffer(1)]]
    ) {
        PileVertex v = verts[vertexID];
        float2 ndc;
        ndc.x = (v.pos.x / u.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (v.pos.y / u.viewportSize.y) * 2.0;

        PileOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.edgeFrac = v.edgeFrac;
        out.heightNorm = v.heightNorm;
        out.sparkleSeed = v.sparkleSeed;
        out.screenPos = v.pos;
        return out;
    }

    fragment float4 pileFragment(
        PileOut in [[stage_in]],
        constant Uniforms& u [[buffer(0)]]
    ) {
        // Soft AA feather on top crest and very bottom contact edge
        float topFeather = 1.0 - smoothstep(0.90, 1.0, in.edgeFrac);
        float bottomFeather = smoothstep(0.0, 0.14, in.edgeFrac);
        float alpha = topFeather * bottomFeather * smoothstep(0.02, 0.18, in.heightNorm);
        if (alpha <= 0.004) discard_fragment();

        // Shading: cool arctic shadow at contact bottom, bright sunlit snow on crest
        float lightCurve = smoothstep(0.05, 0.78, in.edgeFrac);
        float3 col = mix(u.shadowTint.rgb, u.tintColor.rgb, lightCurve);
        // Subtle specular top rim
        col += float3(0.06, 0.07, 0.09) * smoothstep(0.65, 0.92, in.edgeFrac);

        // Ice crystal glints
        if (u.sparkleEnabled > 0.5 && in.edgeFrac > 0.35 && in.edgeFrac < 0.92) {
            float cell = floor(in.screenPos.x * 0.35) * 13.37 + floor(in.screenPos.y * 0.35) * 7.19;
            float phase = sin(cell + u.time * 2.6 + in.sparkleSeed);
            float glint = smoothstep(0.985, 0.999, phase);
            col += float3(0.45, 0.50, 0.60) * glint;
        }

        alpha *= 0.95;
        return float4(col * alpha, alpha);
    }

    // MARK: - Collider Debug Overlay

    struct DebugVertex {
        float2 pos;
        float4 color;
    };

    struct DebugOut {
        float4 position [[position]];
        float4 color;
    };

    vertex DebugOut debugVertex(
        uint vertexID [[vertex_id]],
        constant Uniforms& u [[buffer(0)]],
        const device DebugVertex* verts [[buffer(1)]]
    ) {
        DebugVertex v = verts[vertexID];
        float2 ndc;
        ndc.x = (v.pos.x / u.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (v.pos.y / u.viewportSize.y) * 2.0;

        DebugOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 debugFragment(DebugOut in [[stage_in]]) {
        return float4(in.color.rgb * in.color.a, in.color.a);
    }

    // MARK: - 3D-Shaded Snowballs & Trajectory Beads

    struct SnowballInstance {
        float2 center;
        float radius;
        float rotation;
        float opacity;
        float kind; // 0 = snowball, 1 = enemy snowball (slight red rim), 2 = trajectory bead, 3 = cursor splat
        float2 pad;
    };

    struct SnowballOut {
        float4 position [[position]];
        float2 uv;
        float radius;
        float rotation;
        float opacity;
        float kind;
    };

    vertex SnowballOut snowballVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant Uniforms& u [[buffer(0)]],
        const device SnowballInstance* balls [[buffer(1)]]
    ) {
        const float2 corners[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };

        SnowballInstance b = balls[instanceID];
        float2 local = corners[vertexID];
        float padScale = 1.25;
        float2 screenPos = b.center + local * (b.radius * padScale);

        float2 ndc;
        ndc.x = (screenPos.x / u.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (screenPos.y / u.viewportSize.y) * 2.0;

        SnowballOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = local * padScale;
        out.radius = b.radius;
        out.rotation = b.rotation;
        out.opacity = b.opacity;
        out.kind = b.kind;
        return out;
    }

    fragment float4 snowballFragment(SnowballOut in [[stage_in]]) {
        float2 p = in.uv;
        float r = length(p);

        if (in.kind > 1.5 && in.kind < 2.5) {
            // Trajectory preview bead
            float a = (1.0 - smoothstep(0.65, 1.0, r)) * in.opacity;
            if (a <= 0.01) discard_fragment();
            float3 col = float3(0.45, 0.92, 1.0);
            return float4(col * a, a);
        }

        // Soft drop shadow slightly below sphere
        float shadowR = length((p - float2(0.08, 0.22)) * float2(0.95, 1.35));
        float shadowAlpha = (1.0 - smoothstep(0.55, 1.15, shadowR)) * 0.22 * in.opacity;

        if (r > 1.02) {
            if (shadowAlpha <= 0.005) discard_fragment();
            return float4(float3(0.05, 0.12, 0.25) * shadowAlpha, shadowAlpha);
        }

        float edgeAA = 1.0 - smoothstep(0.90, 1.02, r);
        // Fake 3D sphere normal (top-left lighting)
        float z = sqrt(max(0.0, 1.0 - r * r));
        float3 n = normalize(float3(p.x, -p.y, z));
        float3 lightDir = normalize(float3(-0.48, 0.58, 0.66));
        float diff = clamp(dot(n, lightDir) * 0.5 + 0.5, 0.0, 1.0);

        // Rotating subtle packed-snow grain
        float c = cos(in.rotation);
        float s = sin(in.rotation);
        float2 rp = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        float grain = sin(rp.x * 11.0 + rp.y * 7.0) * sin(rp.y * 13.0 - rp.x * 5.0) * 0.04;

        float3 hiCol = float3(1.0, 1.0, 1.0);
        float3 loCol = (in.kind > 0.5 && in.kind < 1.5)
            ? float3(0.92, 0.72, 0.76)  // subtle rosy shadow on enemy snowballs
            : float3(0.73, 0.85, 0.98); // cool ice shadow on player snowballs
        float3 col = mix(loCol, hiCol, smoothstep(0.15, 0.92, diff + grain));

        float a = edgeAA * in.opacity;
        return float4(col * a, a);
    }

    // MARK: - Charge Power Ring

    struct ChargeRingInstance {
        float2 center;
        float radius;
        float power;
    };

    struct ChargeOut {
        float4 position [[position]];
        float2 uv;
        float power;
    };

    vertex ChargeOut chargeRingVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant Uniforms& u [[buffer(0)]],
        const device ChargeRingInstance* rings [[buffer(1)]]
    ) {
        const float2 corners[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        ChargeRingInstance ring = rings[instanceID];
        float2 local = corners[vertexID];
        float2 screenPos = ring.center + local * ring.radius;

        float2 ndc;
        ndc.x = (screenPos.x / u.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (screenPos.y / u.viewportSize.y) * 2.0;

        ChargeOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = local;
        out.power = ring.power;
        return out;
    }

    fragment float4 chargeRingFragment(ChargeOut in [[stage_in]]) {
        float r = length(in.uv);
        float ringMask = smoothstep(0.58, 0.65, r) * (1.0 - smoothstep(0.86, 0.94, r));
        if (ringMask <= 0.01) discard_fragment();

        // Angle starting from top (-pi/2), sweeping clockwise
        float ang = atan2(in.uv.y, in.uv.x) + 1.5707963;
        if (ang < 0.0) ang += 6.2831853;
        float frac = ang / 6.2831853;

        float3 lowCol = float3(0.25, 0.88, 1.0);
        float3 midCol = float3(1.0, 0.86, 0.25);
        float3 maxCol = float3(1.0, 0.25, 0.25);
        float3 fillCol = in.power < 0.5
            ? mix(lowCol, midCol, in.power * 2.0)
            : mix(midCol, maxCol, (in.power - 0.5) * 2.0);

        float isFilled = step(frac, in.power);
        float3 col = mix(float3(1.0, 1.0, 1.0), fillCol, isFilled);
        float alpha = ringMask * mix(0.24, 0.94, isFilled);
        return float4(col * alpha, alpha);
    }

    // MARK: - Red Snowcraft Dudes (3D-shaded procedural SDF matching reference art)

    struct DudeInstance {
        float2 footPos;
        float scale;
        float facing;    // +1 right, -1 left
        float walkPhase;
        float state;     // 0=walk, 1=aim, 2=throw, 3=KO
        float hitTilt;
        float opacity;
    };

    struct DudeOut {
        float4 position [[position]];
        float2 uv; // x in [-1, 1], y in [-1.5, 0.2] relative to feet
        float facing;
        float walkPhase;
        float state;
        float opacity;
    };

    vertex DudeOut dudeVertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant Uniforms& u [[buffer(0)]],
        const device DudeInstance* dudes [[buffer(1)]]
    ) {
        const float2 corners[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        DudeInstance d = dudes[instanceID];
        float2 local = corners[vertexID];

        // Character bounding quad around footPos: width 64*scale, height 76*scale
        float halfW = 34.0 * d.scale;
        float topH = 66.0 * d.scale;
        float botH = 12.0 * d.scale;

        float2 relPos;
        relPos.x = local.x * halfW;
        relPos.y = (local.y < 0.0) ? (local.y * topH) : (local.y * botH);

        // Apply KO tilt around feet
        if (abs(d.hitTilt) > 0.001) {
            float ang = -d.facing * d.hitTilt;
            float c = cos(ang);
            float s = sin(ang);
            relPos = float2(relPos.x * c - relPos.y * s, relPos.x * s + relPos.y * c);
        }

        float2 screenPos = d.footPos + relPos;
        float2 ndc;
        ndc.x = (screenPos.x / u.viewportSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (screenPos.y / u.viewportSize.y) * 2.0;

        DudeOut out;
        out.position = float4(ndc, 0.0, 1.0);
        // Normalized character space: feet at y=0, head top around y=-1.35
        out.uv = float2(local.x * 1.15, (local.y < 0.0 ? local.y * 1.50 : local.y * 0.27));
        out.facing = d.facing;
        out.walkPhase = d.walkPhase;
        out.state = d.state;
        out.opacity = d.opacity;
        return out;
    }

    float sdEllipseApprox(float2 p, float2 r) {
        return (length(p / r) - 1.0) * min(r.x, r.y);
    }

    float4 shadeBlob(float2 p, float2 center, float2 radii, float3 baseCol, float3 shadowCol, float3 hiCol) {
        float d = sdEllipseApprox(p - center, radii);
        float a = 1.0 - smoothstep(-0.025, 0.025, d);
        if (a <= 0.002) return float4(0.0);
        float2 n2 = clamp((p - center) / radii, -1.0, 1.0);
        float light = clamp((-n2.x * 0.45 - n2.y * 0.55) * 0.5 + 0.5, 0.0, 1.0);
        float3 col = mix(shadowCol, baseCol, smoothstep(0.15, 0.70, light));
        col = mix(col, hiCol, smoothstep(0.75, 1.0, light) * 0.35);
        return float4(col, a);
    }

    float4 overLayer(float4 back, float4 front) {
        float outA = front.a + back.a * (1.0 - front.a);
        if (outA <= 0.0001) return float4(0.0);
        float3 outC = (front.rgb * front.a + back.rgb * back.a * (1.0 - front.a)) / outA;
        return float4(outC, outA);
    }

    fragment float4 dudeFragment(DudeOut in [[stage_in]]) {
        float2 p = in.uv;
        // Flip horizontally so +x is facing direction
        p.x *= in.facing;

        float bob = (in.state < 0.5) ? abs(sin(in.walkPhase)) * 0.07 : 0.0;
        float stride = (in.state < 0.5) ? sin(in.walkPhase) * 0.14 : 0.0;

        float3 redBase   = float3(0.84, 0.11, 0.15);
        float3 redShadow = float3(0.45, 0.04, 0.08);
        float3 redHi     = float3(1.00, 0.42, 0.42);
        float3 cuffBase  = float3(0.75, 0.08, 0.12);

        float3 purpBase  = float3(0.38, 0.09, 0.82);
        float3 purpShad  = float3(0.20, 0.04, 0.48);
        float3 purpHi    = float3(0.62, 0.36, 0.98);

        float3 skinBase  = float3(0.96, 0.82, 0.70);
        float3 skinShad  = float3(0.76, 0.58, 0.46);
        float3 skinHi    = float3(1.00, 0.92, 0.84);

        float3 whiteBase = float3(0.98, 0.99, 1.00);
        float3 whiteShad = float3(0.74, 0.84, 0.96);

        float4 col = float4(0.0);

        // 1. Soft ground shadow
        float shD = sdEllipseApprox(p - float2(-0.04, 0.03), float2(0.46, 0.12));
        float shA = (1.0 - smoothstep(-0.05, 0.10, shD)) * 0.25;
        col = overLayer(col, float4(float3(0.08, 0.14, 0.26), shA));

        // 2. Back boot + front boot (chunky purple boots)
        col = overLayer(col, shadeBlob(p, float2(-0.12 - stride * 0.5, -0.07), float2(0.18, 0.11), purpBase, purpShad, purpHi));
        col = overLayer(col, shadeBlob(p, float2( 0.14 + stride * 0.5, -0.05), float2(0.20, 0.11), purpBase, purpShad, purpHi));

        // 3. Back arm + back mitten (raises back when aiming)
        float aimShift = (in.state > 0.5 && in.state < 1.5) ? -0.18 : ((in.state >= 1.5 && in.state < 2.5) ? 0.22 : 0.0);
        float2 frontHand = float2(0.36 + aimShift * 0.7, -0.44 - bob + (in.state > 0.5 && in.state < 1.5 ? -0.10 : 0.0));
        float2 backHand  = float2(-0.26 - stride * 0.4, -0.36 - bob);

        // 4. Red parka torso
        col = overLayer(col, shadeBlob(p, float2(0.0, -0.38 - bob), float2(0.33, 0.28), redBase, redShadow, redHi));

        // 5. Back arm & white mitten
        col = overLayer(col, shadeBlob(p, float2(-0.22, -0.40 - bob), float2(0.14, 0.14), redBase, redShadow, redHi));
        col = overLayer(col, shadeBlob(p, backHand, float2(0.12, 0.12), whiteBase, whiteShad, whiteBase));

        // 6. Head (peach face) + dark brown oval eyes
        col = overLayer(col, shadeBlob(p, float2(0.02, -0.76 - bob), float2(0.29, 0.24), skinBase, skinShad, skinHi));
        // Eyes facing forward
        float eye1 = 1.0 - smoothstep(-0.015, 0.015, sdEllipseApprox(p - float2(0.10, -0.75 - bob), float2(0.036, 0.054)));
        float eye2 = 1.0 - smoothstep(-0.015, 0.015, sdEllipseApprox(p - float2(0.23, -0.75 - bob), float2(0.030, 0.048)));
        float eyeMask = max(eye1, eye2);
        col = overLayer(col, float4(float3(0.15, 0.09, 0.06), eyeMask));

        // 7. Fluffy white pom-pom on top of beanie
        col = overLayer(col, shadeBlob(p, float2(-0.10, -1.24 - bob), float2(0.13, 0.12), whiteBase, whiteShad, whiteBase));

        // 8. Chunky red beanie dome + folded cuff brim
        col = overLayer(col, shadeBlob(p, float2(-0.02, -0.99 - bob), float2(0.34, 0.24), redBase, redShadow, redHi));
        col = overLayer(col, shadeBlob(p, float2(-0.01, -0.89 - bob), float2(0.37, 0.11), cuffBase, redShadow, redHi));

        // 9. Front arm + front mitten + held snowball when aiming!
        col = overLayer(col, shadeBlob(p, float2(0.22 + aimShift * 0.35, -0.44 - bob), float2(0.13, 0.11), redBase, redShadow, redHi));
        col = overLayer(col, shadeBlob(p, frontHand, float2(0.12, 0.12), whiteBase, whiteShad, whiteBase));
        if (in.state > 0.5 && in.state < 1.5) {
            col = overLayer(col, shadeBlob(p, frontHand + float2(0.08, -0.09), float2(0.11, 0.11), whiteBase, whiteShad, whiteBase));
        }

        col.a *= in.opacity;
        if (col.a <= 0.005) discard_fragment();
        return float4(col.rgb * col.a, col.a);
    }
    """
}
