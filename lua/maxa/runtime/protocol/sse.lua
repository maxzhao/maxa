-- filepath: lua/maxa/runtime/protocol/sse.lua
--- maxa runtime SSE frame parser (phase-1 W1 infrastructure).
---
--- Purpose: incremental Server-Sent Events frame parsing for streaming provider
--- responses (OpenAI Chat Completions / OpenAI Responses / Anthropic Messages /
--- Gemini native all stream SSE). The parser is fed raw transport chunks one at
--- a time (`parser:feed`) and returns complete frames; it MUST NOT depend on
--- receiving a concatenated transcript (fixture contract: "Stream chunks SHALL
--- be fed one at a time").
---
--- Scope (see .supermax/drafts/phase1-implementation-plan.md §4.2/§4.3):
---   - `data:` prefix stripping, multi-line data frames joined with "\n"
---   - `event:`/`id:` fields preserved on the frame (adapter observability)
---   - `[DONE]` marker detection (M.is_done)
---   - blank-line frame separation, CRLF tolerance, SSE comment lines ignored
---   - M.clean_streamed_data: CodeCompanion `adapter_utils.clean_streamed_data`
---     equivalent (read-only alignment; the original lives in
---     codecompanion/utils/adapters.lua and is never imported here).
---
--- Dependencies: none beyond stdlib (pure Lua). Never loads codecompanion.* /
--- mcphub.* / lua/util/hooks/*.
---
--- API:
---   parser = M.new()                  -> stateful parser
---   frames = parser:feed(chunk)       -> complete frames produced by this chunk
---   frames = parser:finish()          -> flush a trailing partial frame at EOF
---   parser:reset()                    -> clear buffer/current frame
---   parser.remainder                  -> unconsumed partial line (diagnostics)
---   frames = M.parse(text)            -> convenience: full-transcript parse
---   M.is_done(frame)                  -> frame.data == "[DONE]"
---   M.clean_streamed_data(data)       -> table -> data.body; string -> JSON start
---
--- Frame shape: { data = string, event = string|nil, id = string|nil }.
--- A frame with no `data` field value still yields data == "" (e.g. an event
--- marker frame); adapter layers decide how to interpret it.

local M = {}

--- Standard SSE end-of-stream data marker (OpenAI/Anthropic/Gemini streams).
M.DONE = "[DONE]"

--- Split an SSE line into (field_name, field_value). Per the SSE spec a single
--- leading space after the colon is stripped from the value. A line without a
--- colon is a field name with an empty value.
---@param line string single line without trailing newline
---@return string name
---@return string value
local function split_field(line)
  local colon = line:find(":", 1, true)
  if not colon then
    return line, ""
  end
  local value = line:sub(colon + 1)
  if value:sub(1, 1) == " " then
    value = value:sub(2)
  end
  return line:sub(1, colon - 1), value
end

--- New empty frame accumulator.
---@return table frame { data=string, has_data=bool, event=string|nil, id=string|nil }
local function new_frame()
  return {
    data = "",
    has_data = false,
    event = nil,
    id = nil,
  }
end

--- Materialize an accumulator into the public frame shape.
---@param acc table accumulator from new_frame
---@return table frame
local function materialize(acc)
  local frame = { data = acc.data }
  if acc.event ~= nil then
    frame.event = acc.event
  end
  if acc.id ~= nil then
    frame.id = acc.id
  end
  return frame
end

--- Create a stateful SSE parser.
---@return table parser { feed=fun(chunk)->table[], finish=fun()->table[],
---                       reset=fun(), remainder=string }
function M.new()
  local self = {
    buffer = "",
    acc = new_frame(),
  }

  --- Process one complete line (no trailing newline). Returns a materialized
  --- frame when the line terminated the current frame (blank line), else nil.
  ---@param line string
  ---@return table|nil frame
  local function process_line(line)
    -- Blank line: dispatch the accumulated frame (if it carries any field).
    if line == "" then
      if self.acc.has_data or self.acc.event ~= nil or self.acc.id ~= nil then
        local frame = materialize(self.acc)
        self.acc = new_frame()
        return frame
      end
      return nil
    end
    -- SSE comment lines (":" prefix) are ignored.
    if line:sub(1, 1) == ":" then
      return nil
    end
    local name, value = split_field(line)
    if name == "data" then
      -- Multi-line data frames append with a single "\n" separator.
      if self.acc.has_data then
        self.acc.data = self.acc.data .. "\n"
      end
      self.acc.data = self.acc.data .. value
      self.acc.has_data = true
    elseif name == "event" then
      self.acc.event = value
    elseif name == "id" then
      self.acc.id = value
    end
    -- Unknown fields (retry:, etc.) are ignored per the SSE spec.
    return nil
  end

  --- Feed a raw chunk of transport output; returns the complete frames it
  --- produced (empty list when the chunk only completed part of a frame).
  ---@param chunk string raw bytes
  ---@return table[] frames
  function self:feed(chunk)
    if type(chunk) ~= "string" or chunk == "" then
      return {}
    end
    self.buffer = self.buffer .. chunk
    local out = {}
    while true do
      local nl = self.buffer:find("\n", 1, true)
      if not nl then
        break
      end
      local line = self.buffer:sub(1, nl - 1)
      self.buffer = self.buffer:sub(nl + 1)
      -- CRLF tolerance: strip a trailing "\r".
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      local frame = process_line(line)
      if frame then
        out[#out + 1] = frame
      end
    end
    return out
  end

  --- Flush a trailing partial frame at end-of-stream. Some servers omit the
  --- final blank line; EOF must still dispatch the pending frame.
  ---
  --- A leftover buffer line without a trailing newline is still a complete
  --- SSE line at EOF (the spec dispatches on EOF even without a blank line),
  --- so it is processed as one final line before the accumulated frame is
  --- flushed. If that final line itself terminated a frame (trailing blank
  --- line), the dispatched frame is returned directly.
  ---@return table[] frames
  function self:finish()
    if self.buffer ~= "" then
      local line = self.buffer
      self.buffer = ""
      -- CRLF tolerance: strip a trailing "\r".
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      local frame = process_line(line)
      if frame then
        return { frame }
      end
    end
    local out = {}
    if self.acc.has_data or self.acc.event ~= nil or self.acc.id ~= nil then
      out[#out + 1] = materialize(self.acc)
      self.acc = new_frame()
    end
    self.buffer = ""
    return out
  end

  --- Reset the parser to a fresh state (new stream).
  function self:reset()
    self.buffer = ""
    self.acc = new_frame()
  end

  -- `remainder` is a read-only accessor over the internal buffer: it reports
  -- the unconsumed partial line(s) for diagnostics. Implemented via __index so
  -- it never goes stale when feed/finish/reset mutate `buffer`.
  return setmetatable(self, {
    __index = function(_, key)
      if key == "remainder" then
        return self.buffer
      end
      return nil
    end,
  })
end

--- Convenience: parse a full transcript into frames (feed + finish).
---@param text string complete SSE transcript
---@return table[] frames
function M.parse(text)
  local parser = M.new()
  local frames = parser:feed(text)
  vim.list_extend(frames, parser:finish())
  return frames
end

--- Whether a frame is the standard "[DONE]" end-of-stream marker.
---@param frame table frame from feed/parse
---@return boolean
function M.is_done(frame)
  return type(frame) == "table" and frame.data == M.DONE
end

--- CodeCompanion `adapter_utils.clean_streamed_data` equivalent: normalize a
--- streamed piece to the JSON payload start. Tables (plenary final responses)
--- expose their `body`; strings are cut at the first "{" or "[" so any leading
--- SSE field text ("event: ..." etc.) is discarded. If neither appears the
--- string is returned unchanged (e.g. "[DONE]"), and adapters must check
--- M.is_done before decoding.
---@param data string|table raw chunk or plenary-style response table
---@return string
function M.clean_streamed_data(data)
  if type(data) == "table" then
    return data.body or ""
  end
  local s = tostring(data)
  local a = s:find("{", 1, true)
  local b = s:find("[", 1, true)
  local first = math.min(a or math.huge, b or math.huge)
  if first == math.huge then
    return s
  end
  return s:sub(first)
end

return M
