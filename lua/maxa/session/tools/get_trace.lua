local session_trace = require("maxa.session.session_trace")
local history_core = require("maxa.session.history_core")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

local function respond(res, data)
  return res:text(vim.json.encode(history_core.create_response(data))):send()
end

local function get_current_save_id(req)
  local chat = req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat
  if chat and chat.opts then
    return chat.opts.save_id
  end
  return nil
end

local function handler(req, res)
  local params = param_utils.normalize(req.params)
  local root_trace_id = params.root_trace_id
  local save_id = params.save_id
  local mode = param_utils.default(params.mode, "summary")
  local include_archives = param_utils.boolean(params.include_archives, false)
  local synthesize_if_missing = param_utils.boolean(params.synthesize_if_missing, true)
  local skip = param_utils.default(params.skip, 0)
  local take = params.take

  if mode ~= "summary" and mode ~= "full" then
    return res:error("get_trace: mode must be 'summary' or 'full'")
  end
  if type(skip) ~= "number" or skip < 0 then
    return res:error("get_trace: skip must be a non-negative number")
  end
  if take ~= nil and (type(take) ~= "number" or take < 1) then
    return res:error("get_trace: take must be a positive number")
  end

  if (not root_trace_id or root_trace_id == "") and (not save_id or save_id == "") then
    save_id = get_current_save_id(req)
  end

  if root_trace_id and root_trace_id ~= "" then
    local _, err = session_trace.validate_trace_id(root_trace_id)
    if err then
      return res:error("get_trace: " .. err)
    end
    if session_trace.trace_exists(root_trace_id) then
      local data, read_err = session_trace.read_trace(root_trace_id, {
        mode = mode,
        include_archives = include_archives,
        skip = skip,
        take = take,
      })
      if not data then
        return res:error("get_trace: Failed to read trace - " .. tostring(read_err))
      end
      return respond(res, data)
    end
    if not synthesize_if_missing then
      return res:error("get_trace: trace not found: " .. root_trace_id)
    end
    save_id = save_id or root_trace_id
  end

  if not save_id or save_id == "" then
    return res:error("get_trace: root_trace_id or save_id is required when no current chat is available")
  end
  local _, save_err = session_trace.validate_trace_id(save_id)
  if save_err then
    return res:error("get_trace: save_id must be a non-empty path-safe id")
  end

  local resolved_trace_id, source = session_trace.find_trace_id_for_save_id(save_id)
  if resolved_trace_id and session_trace.trace_exists(resolved_trace_id) then
    local data, read_err = session_trace.read_trace(resolved_trace_id, {
      mode = mode,
      include_archives = include_archives,
      skip = skip,
      take = take,
    })
    if not data then
      return res:error("get_trace: Failed to read trace - " .. tostring(read_err))
    end
    data.requested_save_id = save_id
    data.resolution = source
    return respond(res, data)
  end

  if not synthesize_if_missing then
    return res:error("get_trace: recorded trace not found for save_id: " .. save_id)
  end

  local synthesized, synth_err = session_trace.synthesize_trace(save_id, {
    mode = mode,
    skip = skip,
    take = take,
  })
  if not synthesized then
    return res:error("get_trace: Failed to synthesize trace - " .. tostring(synth_err))
  end
  return respond(res, synthesized)
end

return {
  name = "get_trace",
  description = "Read a recorded session trace or synthesize bounded lineage from saved chat history; returns JSON.",
  inputSchema = {
    type = "object",
    properties = {
      root_trace_id = {
        type = "string",
        description = "Trace root id; equals the /trace_start root chat save_id.",
      },
      save_id = {
        type = "string",
        description = "Saved chat id used to resolve a recorded trace or synthesize fallback.",
      },
      mode = {
        type = "string",
        enum = { "summary", "full" },
        description = "summary truncates event content and omits archive bodies; full returns larger bounded records.",
      },
      include_archives = {
        type = "boolean",
        description = "When true, include archive metadata in summary mode or archive bodies in full mode.",
      },
      synthesize_if_missing = {
        type = "boolean",
        description = "Default true; synthesize best-effort lineage from saved chat when recorded trace files are absent.",
      },
      skip = {
        type = "number",
        description = "Number of trace events to skip; default 0.",
      },
      take = {
        type = "number",
        description = "Maximum events to return after skip; defaults to 50 in summary, 200 in full.",
      },
    },
    required = {},
  },
  handler = handler,
}
