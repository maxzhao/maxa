# Product and Ecommerce

Use for product hero images, ecommerce main images, packaging concepts, product detail concepts, brand hero visuals, food, beauty, and product photography. Core controls: credible subject, clear material, and explicit selling points.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a [product hero / ecommerce main image / packaging concept] for [product].
Canvas: [square/portrait/landscape].
Subject: [product shape, package, label].
Selling points: "...", "...".
Composition: [center hero / exploded view / shelf scene / macro close-up].
Materials: [glass, metal, paper, cream, fabric].
Lighting: [softbox, rim light, natural window light].
Brand style: [premium/minimal/playful/scientific].
Constraints: sharp foreground, realistic material, readable label text, no fake extra logos.
```

## Required Controls

- Product type and package form.
- Hero composition: centered, exploded view, scene placement, comparison.
- Material: glass, metal, paper box, liquid, fabric, food texture.
- Commercial light: softbox, rim light, diffused light.
- Exact supplied label text, with readable placement and typography.
- Required selling points and claims; use only supplied facts.

## Recommended Sizes

- Product main image: `1024x1024` or `2048x2048`.
- Ecommerce detail poster: `1024x1536` or `2160x3840`.
- Landscape hero: `1536x1024` or `2048x1152`.

## Pitfalls

- Organize selling points with a clear hierarchy; do not remove required claims or shorten supplied label copy automatically.
- For edits, name the product geometry, label wording/placement, identity, and unedited lighting or layout to preserve. Pixel-identical package or label regions require deterministic compositing.
- Require realistic materials and shadows; avoid plastic CGI.
- Do not generate unprovided brand logos or certification marks.

## Prompt Skeleton

```text
Create a square premium ecommerce product hero image for a fictional sparkling tea brand named "MIST LEAF".
Subject: one glass bottle with ivory label, condensation droplets, green tea leaves, and citrus slices.
Exact label text: "MIST LEAF" / "Sparkling Cold Brew Tea" / "0 Sugar".
Composition: centered bottle hero with small ingredient accents around the base, clean negative space for advertising.
Materials and lighting: realistic glass, paper label texture, cold condensation, softbox reflection, subtle rim light.
Style: premium minimalist beverage photography, warm ivory and deep green palette.
Constraints: sharp foreground, realistic material, readable label text, no fake certification marks, no garbled microtext.
```
