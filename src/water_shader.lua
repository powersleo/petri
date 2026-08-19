-- Screen-space post effect applied over the dish canvas only (see main.lua,
-- which renders the world into a padded, world-sized canvas before this
-- runs). Tuned for a shallow petri dish under a lamp, not open water: fine,
-- slow surface-tension shimmer instead of rolling waves, no hue-shifting
-- tint (cell color encodes genome traits, so it has to stay legible), a
-- faint grain for suspended particulate, a bright meniscus ring where the
-- liquid climbs the dish wall, and a few small drifting specular sparkles
-- instead of one flat glare blob.
--
-- The canvas is padded past the dish bounds (room for cell appendages
-- near the wall to draw without clipping), so texture_coords span more
-- than just the dish. insetFrac gives the fraction of the canvas that's
-- padding on each axis, letting the vignette/meniscus stay anchored to
-- the real dish wall instead of the padded canvas edge.
return [[
extern number time;
extern vec2 resolution;
extern vec2 insetFrac;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;

    float t = time * 0.35;
    float wobbleX = sin(uv.y * 40.0 + t * 2.0) * 0.0009
                   + sin(uv.y * 97.0 - t * 3.1) * 0.0004;
    float wobbleY = sin(uv.x * 44.0 - t * 1.7) * 0.0009
                   + sin(uv.x * 89.0 + t * 2.6) * 0.0004;
    vec2 distorted = uv + vec2(wobbleX, wobbleY);

    vec4 texcolor = Texel(texture, distorted);

    float grain = hash(floor(uv * 400.0) + floor(time * 6.0)) - 0.5;
    texcolor.rgb += grain * 0.018;

    // Dish-relative uv: 0..1 spans the actual dish; outside that range is
    // the padding strip that only exists so appendages have room to draw.
    vec2 dishUV = (uv - insetFrac) / (1.0 - 2.0 * insetFrac);

    vec2 aspect = vec2(resolution.x / resolution.y, 1.0);
    vec2 aspectUV = (dishUV - 0.5) * aspect;
    float dist = length(aspectUV);
    float vign = smoothstep(0.8, 0.25, dist);

    // Meniscus: liquid climbs the dish wall at the rim and catches the
    // light there. Symmetric around the wall line itself (dishUV edge ==
    // 0) so it fades out into the padding strip instead of flooding it.
    float edgeDist = min(min(dishUV.x, 1.0 - dishUV.x), min(dishUV.y, 1.0 - dishUV.y));
    float meniscus = (1.0 - smoothstep(0.0, 0.035, abs(edgeDist))) * 0.16;

    // A handful of small drifting specular sparkles standing in for a lamp
    // glinting off the liquid surface, instead of one flat glare blob.
    float sparkle = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        vec2 seed = vec2(fi * 13.7, fi * 41.3);
        vec2 pos = vec2(hash(seed), hash(seed + 7.0));
        pos += vec2(sin(t * (0.6 + fi * 0.13) + fi), cos(t * (0.5 + fi * 0.11) + fi * 2.0)) * 0.06;
        pos = fract(pos);
        vec2 posAspect = (pos - 0.5) * aspect;
        float d = length(aspectUV - posAspect);
        float twinkle = 0.5 + 0.5 * sin(time * (1.3 + fi * 0.4) + fi * 5.0);
        sparkle += smoothstep(0.025, 0.0, d) * twinkle * 0.35;
    }

    vec3 finalColor = texcolor.rgb * (0.8 + 0.2 * vign) + meniscus + sparkle;

    return vec4(finalColor, texcolor.a) * color;
}
]]
