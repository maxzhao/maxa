# GenAI Adapter Development

Purpose: declare explicit image, TTS, or video services under `opts.maxa.providers` without introducing a second service registry.

## Configuration Ownership

- `lua/plugins/ai.lua`: deployment `opts.maxa.proxy` and provider-owned `llm`/`genai` service declarations; a media-only provider does not need an LLM adapter.
- `lua/maxa/provider_config.lua`: provider validation, LLM adapter composition and GenAI capability registration.
- `lua/maxa/presets.lua`: named presets and `maxa.defaults.image|tts|video`, each a name or inline configuration.
- `lua/maxa/mcphub/native_servers/genai/config.lua`: derived media defaults, output directory and persisted adapter selections.
- `lua/maxa/mcphub/native_servers/genai/capability_registry.lua`: lightweight picker metadata derived from provider declarations; never hand-register a second list.
- `lua/maxa/mcphub/native_servers/genai/adapter.lua`: selected service/capability resolution and request-time provider proxy policy.

## Capability Contract

```lua
opts.maxa = {
  proxy = "http://proxy.example.test:8080", -- or function(provider) -> address|nil
  providers = {
    example = {
      type = "sub2api",
      base_url = "https://example.test/v1",
      api_key = env.get("EXAMPLE_API_KEY"),
      proxy = true, -- false|true|address|function(provider) -> address|nil
      llm = {
        openai_responses = { name = "example_openai" },
      },
      genai = {
        image = {
          mode = "codex", -- codex | compatible; media name defaults to provider ID "example"
          api_key = env.get("EXAMPLE_IMAGE_API_KEY"),
          defaults = {},
          endpoints = { responses = "/responses" },
          request = { stream = true, max_n = 15, image_field = "image", mask_field = "mask" },
        },
        tts = {
          defaults = {},
          endpoints = { speech = "/audio/speech" },
          request = {},
        },
        video = {
          defaults = {},
          endpoints = {
            create = "/videos",
            retrieve = "/videos/{id}",
            content = "/videos/{id}/content",
          },
          request = {
            reference_field = "input_reference[]",
            max_reference_images = 7,
            poll_interval_ms = 2500,
            max_poll_attempts = 120,
          },
        },
      },
    },
  },
}
```

Rules:

- A provider capability block present means supported; absent means unsupported. Optional `adapter` names the independent media service; omission uses the provider ID regardless of LLM declarations. Preserve existing explicit names to retain saved selections. Do not add `enabled` or define services outside `opts.maxa.providers`.
- Do not infer support from protocol, models, keys, URLs or provider type.
- `mode`, endpoints, request policy, limits and capability credentials belong to the media capability; proxy selection belongs only to its provider.
- `provider.proxy = true` resolves the global address for that provider. A provider string supplies its own address; a provider function returns its own address or `nil` per outbound request, without global fallback. Global proxy functions receive the provider. `false`/omitted or a function result `nil` means direct.
- Ordinary request precedence is explicit tool fields > explicit named preset > adapter capability `defaults` > media role defaults. Without an explicit preset, provider parameter priority is unchanged.
- Connection precedence is capability `base_url`/`api_key` > provider `base_url`/`api_key`. Media never inherits same-name LLM overrides; move required legacy overrides into the capability explicitly. Sharing a name does not link media to an LLM.
- Keep provider composition lazy: the capability registry lists independent media names without constructing LLM adapters or requesting models. A media-only service is valid when declared by a provider; do not publish derived capabilities on LLM adapters.
- The provider proxy resolver uses the provider ID, not an adapter-name allowlist or `adapter.maxa.proxy` override.

## Image Modes

- `codex`: Responses `/responses` plus server-side `image_generation`; preserves request-only `requested_size`, streaming, exact prompt handling, and local output inspection.
- `compatible`: `/images/generations` and `/images/edits`; defaults to streaming to avoid long-request timeouts, supports `request.stream = false` as an adapter-level opt-out, and supports configured multipart image/mask fields.
- No tool-level mode override exists.

## Tool And UI Contract

- Media selection: explicit named `preset` (matching medium) > legacy explicit adapter > exact caller Chat medium override > explicit caller project's `_meta.yaml` medium override > persisted/global role default. Without Chat/project provenance retain global behavior; never infer the project from the active window or last Chat. `generation_preset` is only the upstream video mode.
- `ga` edits session overrides (clear restores project/global inheritance); `<leader>aA` edits global defaults; `<leader>aa` edits project defaults. Each overview shows effective `llm/image/tts/video` values and their source. Project controls are also in the independent `D` default-service view of `:MaxaConfig`, separate from Ability/suites. Media branches select declared-capable adapters, not model IDs.
- Capability listing must use the lightweight registry without resolving adapters or requesting model lists.
- Results identify `Adapter`, never a GenAI provider.

## Validation

Run the closest suites after capability changes:

```bash
nvim --headless -l lua/maxa/mcphub/native_servers/genai/default_adapter_test.lua
nvim --headless -l lua/maxa/mcphub/native_servers/genai/image/image_provider_test.lua
nvim --headless -l lua/maxa/mcphub/native_servers/genai/image/image_generate_test.lua
nvim --headless -l lua/maxa/mcphub/native_servers/genai/image/image_edit_test.lua
nvim --headless -l lua/maxa/mcphub/native_servers/genai/image/image_responses_provider_test.lua
nvim --headless -l lua/maxa/mcphub/native_servers/genai/media/media_contract_test.lua
```

Then validate Lua syntax, strict skill lint, `git diff --check`, full Native restart-resume, forced `genai` reload, schema fields, and a live `gi` picker smoke. Real paid media calls are required only when upstream deployment availability itself is under test.

## Failure Handling

- Missing declaration: add the capability under its provider only with evidence that the service supports it; do not infer.
- Missing key: configure capability or provider credentials; never log secret values.
- Invalid image mode: use exactly `codex` or `compatible`.
- Picker missing an adapter: verify provider declaration and capability registration before adapter resolution.
