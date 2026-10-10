# Character and Figure Design

Use for character design, full-body illustration, character sheets, card art, expression/pose sheets, and series consistency. Core controls: identity, silhouette, costume, pose, and continuity.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a [character sheet / full-body character illustration / card art] for [character concept].
Canvas: [portrait/square].
Identity: [age range, role, species/fantasy type if any].
Silhouette: [body shape, pose, recognizable outline].
Costume: [clothing, accessories, materials, color coding].
Expression/pose: [mood, action].
Style: [anime, painterly, game concept art, ink, etc.].
Consistency: preserve same face, outfit motifs, palette, and proportions across panels.
Constraints: no extra limbs, clean hands, readable character design, no random text unless specified.
```

## Required Controls

- Character identity and role.
- Silhouette and pose.
- Costume, accessories, materials, palette.
- Expression and emotion.
- Style boundary.
- For multipanel outputs: panel count and content per panel.

## Recommended Sizes

- Full-body character: `1024x1536` or `2160x3840`.
- Character/action sheet: `2048x2048` or `1536x1024`.
- Card art: `1024x1536`.

## Pitfalls

- Multiperson or multipanel images need explicit consistency constraints. For later scenes, reuse the approved character image and restate defining face, hair, proportions, costume, and palette.
- Describe body framing, gaze, hand contact, and prop interaction concretely; preserve the requested action rather than simplifying it automatically.
- Do not let the model add random text, logos, or badges.
- Use concrete style anchors: game concept art, anime key visual, ink wash character sheet.

## Prompt Skeleton

```text
Create a full-body character design sheet for a fictional forest courier named "Liora".
Canvas: portrait.
Identity: young adult fantasy courier, agile and calm.
Silhouette: slim figure, asymmetrical cloak, satchel, light boots, standing in a relaxed three-quarter pose; full body and both feet visible.
Costume: moss-green hooded cloak, cream linen tunic, brass map case, small leaf-shaped pins, worn leather gloves.
Expression: focused and warm, subtle smile.
Style: polished game concept art with painterly texture and clean readable design.
Constraints: consistent face and proportions, clear costume details, no extra limbs, clean hands, no random text or logos.
```
