# GenAI Safety and image_edit Failure Handling

## Goal

When `@genai:image_edit` fails, distinguish prompt-fixable issues, input-image safety issues, and provider/gateway issues. Avoid blind repeated retries. When a call succeeds and its visual result is reviewed, apply `references/image-edit-review-standard.md`; transport or moderation handling must not imply that successful edits owe 1:1 pixel reproduction.

## Typical Signals

- Explicit safety: `moderation_blocked`, `safety_violations=[...]`, `sexual`, `image_generation_user_error`.
- Ambiguous interruption: `curl exit 56`, `Recv failure`, `Connection reset by peer`, `HTTP/2 INTERNAL_ERROR`. In Responses image edit, this may be provider/gateway failure or upstream safety disconnect.
- Gateway timeout: `502`, `504`, `bad_response_status_code`, `Gateway Time-out`. Usually provider/gateway instability, but repeated failures with the same sensitive prompt/input should also be checked for safety.

## Classification

1. First look for explicit safety/moderation text.
2. If ambiguous and in `image_edit`, inspect prompt and input image:
   - Prompt includes nudity, sexualized framing, adult-adjacent wording, body/stocking/underwear focus → treat as `prompt_risk` first.
   - Prompt is neutral, but input image itself has exposure/sexualized/underwear/minor-uncertain/adult-adjacent traits → treat as `input_image_risk`.
   - Safe still life, product, or landscape also fails → likely `provider_gateway`.

## Auto-Repair Boundary

- **Likely prompt risk**: rewrite to neutral, non-sexual, ordinary edit intent; retry at most 1 time.
- **Likely input image risk**: do not keep editing the same image; use safer source, regenerate from text, first create a safe base image, or explain likely safety block.
- **Likely provider/gateway**: test with a safe small image + simple prompt if useful; if minimal repro fails, report provider/gateway issue and stop retrying the business prompt.

## User Report Categories

- `prompt_risk`: prompt adjusted and retried / adjustment suggested.
- `input_image_risk`: same image should not continue through edit; suggest replacement or regeneration.
- `provider_gateway`: backend connection, timeout, or gateway issue.
- `confirmed_working`: safe small image + neutral edit succeeded, so the capability path works.
