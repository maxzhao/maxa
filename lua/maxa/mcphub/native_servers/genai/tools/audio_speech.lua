local provider_api = require("maxa.mcphub.native_servers.genai.adapter")
local speech = require("maxa.mcphub.native_servers.genai.audio.openai_speech")
local params_util = require("maxa.mcphub.native_servers.shared.params")

local function handler(req, res)
  if not req or not req.params then return res:error("audio_speech: Invalid request object") end
  local params = params_util.normalize(req.params)
  local selected, merged, selection_err = require("maxa.mcphub.native_servers.genai.preset").resolve(req, "tts", params)
  params = merged
  if selection_err then return res:error("audio_speech: " .. tostring(selection_err)) end
  local provider, capability, err = provider_api.require_capability(selected, "tts")
  if not provider then return res:error("audio_speech: " .. tostring(err)) end
  speech.speech_async(provider, capability, params, function(result, async_err)
    if not result then return res:error("audio_speech: " .. tostring(async_err)) end
    return res:text(string.format("Audio speech completed\nAdapter: %s\nModel: %s\nVoice: %s\nFormat: %s\nMIME: %s\nBytes: %d\nPath: %s", result.adapter, result.model, result.voice, result.format, result.mime, result.bytes, result.path)):send()
  end)
end

return {
  name = "audio_speech",
  description = "Synthesize non-streaming speech to a unique local audio file; returns factual metadata, never audio bytes or base64.",
  inputSchema = { type = "object", properties = {
    input = { type = "string", description = "Required non-empty text to synthesize." },
    preset = { type = "string", description = "Optional named TTS preset; omission preserves session/project/global defaults." },
    model = { type = "string", description = "Optional TTS model override; omit unless explicitly requested." },
    voice = { type = "string", description = "Optional voice override." },
    response_format = { type = "string", enum = { "mp3", "opus", "aac", "flac", "wav", "pcm" }, description = "Audio format; configured defaults apply when omitted." },
    speed = { type = "number", minimum = 0.25, maximum = 4, description = "Speech speed; configured defaults apply when omitted." },
    instructions = { type = "string", description = "Optional speaking-style instructions." },
    output_dir = { type = "string", description = "Optional local output directory." },
    filename_prefix = { type = "string", default = "audio_speech", description = "Safe output filename prefix." },
    timeout_seconds = { type = "integer", minimum = 1, description = "Optional HTTP timeout." },
    extra = { type = "object", additionalProperties = true, description = "Allowlisted adapter request fields." },
  }, required = { "input" } }, handler = handler,
}
