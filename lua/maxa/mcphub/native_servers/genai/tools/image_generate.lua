-- 通用文本生图 MCP 工具

local image = require("maxa.mcphub.native_servers.genai.image")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local requested_size = require("maxa.mcphub.native_servers.genai.image.requested_size")
local result_text = require("maxa.mcphub.native_servers.genai.image.result_text")

local function build_result_text(result)
  return result_text.build("✅ Image generation completed", result)
end

local function handler(req, res)
  if not req or not req.params then
    return res:error("image_generate: Invalid request object")
  end

  local params = param_utils.normalize(req.params)
  if not params.prompt or vim.trim(params.prompt) == "" then
    return res:error("image_generate: Missing required parameter: prompt")
  end
  local valid_size, size_err = requested_size.validate_params(params, { provider_label = "image_generate" })
  if not valid_size then
    return res:error("image_generate: " .. tostring(size_err))
  end

  local selected, merged, selection_err = require("maxa.mcphub.native_servers.genai.preset").resolve(req, "image", params)
  params = merged
  if selection_err then return res:error("image_generate: " .. tostring(selection_err)) end
  local provider, err = image.get_adapter(selected)
  if not provider then
    return res:error("image_generate: " .. tostring(err))
  end

  local driver
  driver, err = image.get_driver(provider)
  if not driver then
    return res:error("image_generate: " .. tostring(err))
  end

  if type(driver.generate_image_async) == "function" then
    driver.generate_image_async(provider, params, function(result, async_err)
      if not result then
        return res:error("image_generate: " .. tostring(async_err))
      end
      return res:text(build_result_text(result)):send()
    end)
    return
  end

  if type(driver.generate_image) ~= "function" then
    return res:error("image_generate: Driver '" .. tostring(provider.driver) .. "' does not implement generate_image")
  end

  local result
  result, err = driver.generate_image(provider, params)
  if not result then
    return res:error("image_generate: " .. tostring(err))
  end

  return res:text(build_result_text(result)):send()
end

return {
  name = "image_generate",
  description = "Generate image files from a text prompt with the configured adapter; returns local paths and summary, never base64.",
  inputSchema = {
    type = "object",
    properties = {
      prompt = {
        type = "string",
        description = "Required image-generation prompt.",
      },
      preset = {
        type = "string",
        description = "Optional named image preset; omission preserves session/project/global defaults.",
      },
      model = {
        type = "string",
        description = "Optional image/tool model override. Omit unless the user explicitly requests one; otherwise adapter defaults apply.",
      },
      text_model = {
        type = "string",
        description = "Optional outer Responses text model override for adapters that separate text host model from image/tool model.",
      },
      requested_size = {
        type = "string",
        description = "Optional upstream size request: `auto` or positive-integer `WIDTHxHEIGHT`; actual saved dimensions may differ.",
      },
      quality = {
        type = "string",
        description = "Optional adapter quality setting; configured defaults apply when omitted.",
      },
      output_format = {
        type = "string",
        description = "Optional output format, e.g. png, jpeg, webp; configured defaults apply when omitted.",
      },
      background = {
        type = "string",
        description = "Optional adapter background setting, e.g. auto, opaque, transparent; adapter/model support varies.",
        enum = { "auto", "opaque", "transparent" },
      },
      response_format = {
        type = "string",
        description = "Optional upstream response format; adapter behavior applies when omitted.",
        enum = { "url", "b64_json" },
      },
      n = {
        type = "integer",
        description = "Optional image count; configured defaults apply when omitted.",
        minimum = 1,
      },
      output_dir = {
        type = "string",
        description = "Optional output directory override; defaults to the adapter capability or GenAI output directory.",
      },
      filename_prefix = {
        type = "string",
        description = "Optional safe filename prefix.",
        default = "image_generate",
      },
      extra = {
        type = "object",
        description = "Optional adapter-specific JSON-body fields.",
        additionalProperties = true,
      },
    },
    required = { "prompt" },
  },
  handler = handler,
}
