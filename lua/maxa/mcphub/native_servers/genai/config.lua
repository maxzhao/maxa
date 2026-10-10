-- Global GenAI output/default parameters and independent per-medium adapter defaults.
-- Provider declarations live at `opts.maxa.providers[provider_id].genai`.
-- `image`, `tts`, and `video` each declare at most one capability block with
-- `adapter = <name>`; the same name may identify an LLM adapter of that provider.
-- A media-only provider does not need a fictitious LLM protocol.
-- Existing capability fields (`mode`, `api_key`, `endpoints`, `request`,
-- `defaults`) retain their driver semantics. Missing blocks mean unsupported.
-- Calls use tool params > capability defaults > global defaults and select only
-- adapter names; persisted per-medium selections override deployment defaults.

local state = require("maxa.mcphub.native_servers.genai.default_adapter")

return state.get_initial_config(vim.deepcopy(require("maxa.config").runtime().genai))
