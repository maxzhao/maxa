# Photography and Photorealism

Use for realistic photos, cinematic scenes, screen photography, lifestyle images, architecture/interior, and product photography. Core controls: camera context, lighting, and plausible detail.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a photorealistic [photo type] of [subject].
Canvas: [portrait/landscape/square].
Camera: [lens/angle/framing/depth of field].
Lighting: [natural window light/golden hour/neon/softbox].
Environment: [place, props, weather, time].
Material details: [texture, reflections, imperfections].
Mood: [editorial/documentary/cinematic].
Constraints: realistic proportions, natural imperfections, avoid CGI look.
```

## Required Controls

- Photo type: editorial, documentary, product photography, cinematic still, screen photography.
- Lens/angle: macro, low three-quarter, overhead, wide shot, close-up.
- Light: golden hour, diffused window light, softbox, neon reflections.
- Environment, props, and time.
- Material, texture, natural imperfections.

## Recommended Sizes

- Landscape/cinematic: `1536x1024`, `2048x1152`, or `3840x2160`.
- Portrait/fashion: `1024x1536` or `2160x3840`.
- Square social/product: `1024x1024` or `2048x2048`.

## Pitfalls

- Request photorealism explicitly and describe framing, light, materials, scale, atmosphere, and color. Camera specifications are appearance cues, not guarantees of physical simulation.
- Avoid CGI look with natural imperfections and real material texture.
- For people, describe body framing, relative scale, gaze, and contact with objects; require realistic proportions and natural skin.
- For screen photography, specify whether screen content must be real/readable.

## Prompt Skeleton

```text
Create a photorealistic editorial photo of a small independent bookstore at night.
Canvas: landscape 16:9.
Camera: low three-quarter street-level angle, 35mm lens feel, shallow depth of field.
Lighting: warm interior window light spilling onto wet pavement, subtle neon reflections after rain.
Environment: narrow street, wooden storefront, stacked books visible through the window, a few natural imperfections.
Mood: cinematic but believable documentary still.
Constraints: realistic proportions, natural reflections, textured paper and wood, avoid CGI look, avoid over-saturated fantasy colors.
```
