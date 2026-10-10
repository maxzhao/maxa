# GenAI Image-Edit Review Standard

## Purpose

Apply this standard whenever `@genai:image_edit` output is visually compared with an input or approved base. Image editing is generative rerendering, not a deterministic pixel transform. Default review therefore measures perceptual fidelity and requested-change success rather than exact pixel reproduction.

## Default Perceptual-Fidelity Review

Use complete side-by-side views as primary evidence. Ask whether an ordinary viewer would immediately read the edited result as the same subject, asset, design, or composition after the requested change.

PASS when:

- the requested change is visibly achieved and each named content/technical invariant passes its own check;
- protected content keeps the same first-glance identity;
- dominant silhouette, aspect ratio, orientation, composition, component arrangement, topology, negative spaces, and key landmarks remain substantially similar where protected;
- dominant hue family, major accent colors, and light/dark distribution remain substantially similar where protected;
- text, Logo, brand, character, product, or UI invariants required by the task remain recognizable and semantically correct;
- no unrelated addition, deletion, or redesign changes the protected content's identity.

Accept normal generative variation:

- antialiasing, resampling, local gradients, glow falloff, highlights, texture, brushwork, and micro-detail;
- small local contour, stroke, facet, tooth, ray, fold, or ornament differences;
- minor brightness, saturation, scale, position, or proportion drift that is not obvious at first glance and does not alter identity, layout intent, or usability.

FAIL for an identity-relevant difference visible in complete views, any unmet requested change, or a failed named content/technical invariant. The latter may require a crop or deterministic check even when it is subtle in the complete view. Examples:

- an immediately different dominant silhouette, aspect ratio, orientation, composition, or component arrangement;
- a clear dominant color-family shift or loss/replacement of an identity-defining accent;
- a missing, added, or structurally changed key component, topology, negative space, landmark, readable text, Logo, or brand feature;
- scale, position, or proportion drift large enough to read as a different treatment or break the requested layout;
- failure to perform the requested edit, retained forbidden content, or invented content.

Do not fail solely because pixels, seams, contours, antialiasing, or micro-details do not match exactly. Crops, overlays, split views, difference images, and registration diagnostics are secondary evidence; they may localize a visible problem but cannot turn imperceptible pixel drift into a default failure. Do not invent universal numeric similarity thresholds without task-specific evidence.

## Strict Technical Exceptions

Use stricter correspondence only when the user or downstream computation requires it. Examples:

- masks, exact-canvas compositing, or other downstream deterministic processing;
- exact text, Logo, package label, chart value, scientific label, UI state, or other explicitly protected contract;
- a user request that explicitly requires pixel-accurate preservation.

For an exception, name the exact strict invariant and why it is required. Apply strict review only to that invariant; review all other generatively rendered properties with the default perceptual standard. A stricter workflow section overrides the default only within its declared scope. Never claim that ordinary `image_edit` guarantees 1:1 pixels.

The official image prompting guide (source in `craft.md`) recommends inspecting every edit and compositing an approved edit into the original when a region must remain pixel-identical. Use deterministic compositing and verify protected pixels for that requirement; stronger prompts or repeated model calls alone are not a sufficient implementation. Exact text, chart values and scientific relationships must be checked at readable scale, not waived because first-glance identity passes.

## Review Report

For each output, record:

- `PASS`, `FAIL`, or `BLOCKED`;
- requested change result;
- protected invariants that remain perceptually similar;
- any first-glance identity/task-relevant difference;
- strict technical invariant evidence only when an exception applies;
- output path and next repair focus when needed.
