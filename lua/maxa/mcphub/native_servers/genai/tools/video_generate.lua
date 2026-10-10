local provider_api = require("maxa.mcphub.native_servers.genai.adapter")
local video = require("maxa.mcphub.native_servers.genai.video.infinite_canvas")
local params_util = require("maxa.mcphub.native_servers.shared.params")

local function handler(req, res)
  if not req or not req.params then return res:error("video_generate: Invalid request object") end
  local params = params_util.normalize(req.params)
  local selected, merged, selection_err = require("maxa.mcphub.native_servers.genai.preset").resolve(req, "video", params)
  params = merged
  if selection_err then return res:error("video_generate: " .. tostring(selection_err)) end
  local provider, capability, err = provider_api.require_capability(selected, "video")
  if not provider then return res:error("video_generate: " .. tostring(err)) end
  video.generate_async(provider, capability, params, function(result, async_err)
    if not result then return res:error("video_generate: " .. tostring(async_err)) end
    return res:text(string.format("Video generation completed\nAdapter: %s\nModel: %s\nTask ID: %s\nStatus: %s\nSeconds: %s\nSize: %s\nMIME: %s\nBytes: %d\nPolls: %d\nElapsed ms: %d\nPath: %s", result.adapter, tostring(result.model or ""), tostring(result.task_id or "direct"), result.status, tostring(result.seconds), tostring(result.size or "auto"), result.mime, result.bytes, result.polls, result.elapsed_ms, result.path)):send()
  end)
end

return {
  name = "video_generate",
  description = "Generate a video through create/poll/download and save it locally; returns task/file facts, never binary or base64.",
  inputSchema = { type = "object", properties = {
    prompt = { type = "string", description = "Required non-empty video prompt." },
    reference_image_paths = { type = "array", items = { type = "string" }, maxItems = 7, description = "Optional local reference images; adapter limit defaults to seven." },
    preset = { type = "string", description = "Optional named video preset; omission preserves session/project/global defaults." },
    model = { type = "string", description = "Optional video model override; omit unless explicitly requested." },
    seconds = { type = "integer", minimum = 1, maximum = 20, description = "Duration in seconds; configured defaults apply when omitted." },
    size = { type = "string", pattern = "^(auto|[1-9][0-9]*x[1-9][0-9]*)$", description = "auto or WIDTHxHEIGHT." },
    resolution_name = { type = "string", description = "Optional compatible resolution name." },
    generation_preset = { type = "string", description = "Optional upstream video generation mode; unrelated to the Maxa preset name." },
    output_dir = { type = "string", description = "Optional local output directory." },
    filename_prefix = { type = "string", default = "video_generate", description = "Safe output filename prefix." },
    timeout_seconds = { type = "integer", minimum = 1, description = "Optional whole-operation timeout." },
    extra = { type = "object", additionalProperties = true, description = "Reserved allowlisted adapter fields." },
  }, required = { "prompt" } }, handler = handler,
}
