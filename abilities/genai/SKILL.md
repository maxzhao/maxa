---
name: genai
description: "Use the genai MCP server for image generation and editing, text-to-speech, video generation, image prompt design, reusable visual templates, and case reverse engineering."
compatibility: Requires Maxa Ability runtime.
---
# GenAI Media And Prompt Workflows

Purpose: produce requested images, image prompts, speech, video, and reusable visual-generation artifacts through the composite GenAI Ability. One `load(target="genai")` commits both instructions and MCP authorization.

## Shared Boundaries

- Before writing any image-generation/editing prompt, read `references/craft.md`, including prompt-only, category/template, and generated-intermediate requests.
- `references/preflight.md` owns settings and public GenAI mapping; this Ability does not select or migrate the configured backend.
- Use configured defaults without inspecting or reporting adapter identity during successful work. Omit `preset`, `model`, and `text_model` unless explicitly requested or the task needs a particular named configuration; select only a matching media type. Repair rejected capabilities from actual tool errors.
- Prefer native SVG/vector/code editing for deterministic editable-source changes unless the user wants a generated bitmap.
- Image-edit comparisons require `references/image-edit-review-standard.md`: judge first-glance identity and requested invariants, not blanket pixel identity or exact seams. Named user or downstream technical invariants still apply.
- Prompt-only requests do not call generation tools. Return a self-contained prompt and relevant parameter advice.
- Tool success proves file generation, not content acceptance. Apply the selected workflow's validation and report unresolved deliverable requirements.

## Task Routing

Read the selected row's references, not every workflow. Before any media generation/edit/speech/video call, read the applicable call and acceptance sections of `references/media-calls.md`. All paths are relative to this Ability root.

| Task | Read / use |
| --- | --- |
| Text-to-image, image edit/reference fusion, speech, or video | `references/media-calls.md`; call the corresponding public tool |
| Continue editing, tune a previous candidate, or branch candidates | `references/media-calls.md` and `references/iterative-workflows.md` |
| App Store screenshot, figure, slide, logo grid, storyboard, sprite sheet, ecommerce or reusable template | `references/template-routing.md`, then the selected template; use `references/media-calls.md` for generation |
| Prompt craft | `references/craft.md`; `references/roles.md` for an expert checklist |
| Category-specific prompt | `references/gallery-index.md` and one relevant category; mixed cases read at most two |
| Case reverse engineering / rule capture | `references/reverse-engineering.md` |
| Adapter development | `references/adapter-development.md` |
| Safety/moderation or edit failure | `references/safety-and-edit-failures.md` |

Category/template references are task-specific heuristics under `references/craft.md`, not separate model rules; adapt them to the user's goal instead of copying unrelated examples. Template/batch deliverables may additionally require `references/templates.md` and one YAML template. Parameter preflight is in `references/preflight.md`.

