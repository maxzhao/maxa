-- filepath: tests/protocol/live.lua
--- Phase-1 W9 live validation: real DeepSeek round-trips over the three
--- supported protocols (openai_chat / openai_responses / anthropic_messages).
---
--- Provider definitions come from /home/maxzhao/maxa/.maxa/runtime.yaml
--- (api_key_env=DEEPSEEK_TEST_KEY). The key is read from <root>/.env at
--- runtime, set into the process env for resolve_provider, and NEVER printed
--- or persisted. Gemini is skipped (DeepSeek does not support it).
---
--- Per protocol: one non-streamed request (transport.post stream=false,
--- adapter:parse_nonstream) and one streamed request (adapter:stream with
--- on_event collection). Asserts exactly one terminal event and non-empty
--- normalized usage. Real failures are reported, never faked.
---
--- Exit contract: prints per-protocol PASS/FAIL + event summaries; exits 1
--- (`cq`) on any failure.
---
--- Usage:
---   NVIM_APPNAME=nvim-maxa nvim --headless -l tests/protocol/live.lua
local ROOT = "/home/maxzhao/maxa"

--- Read a KEY=VALUE line from <root>/.env without echoing the value.
---@param key string
---@return string|nil value
local function read_env_file(key)
  local f = io.open(ROOT .. "/.env", "rb")
  if not f then
    return nil
  end
  local body = f:read("*a")
  f:close()
  for line in body:gmatch("[^\r\n]+") do
    local value = line:match("^%s*" .. key .. "%s*=%s*(.-)%s*$")
    if value then
      return value
    end
  end
  return nil
end

--- Wait (keeping the event loop alive) until done or timeout.
---@param deadline_ms integer
---@param is_done fun(): boolean
---@return boolean finished_before_timeout
local function wait_for(deadline_ms, is_done)
  local waited = 0
  while waited < deadline_ms do
    if is_done() then
      return true
    end
    vim.wait(50)
    waited = waited + 50
  end
  return is_done()
end

--- Normalized messages/tools for a live request.
local function normalized_request(text)
  return {
    messages = {
      {
        id = "live-user-1",
        turn_id = "live-turn-1",
        role = "user",
        content = { { type = "text", text = text } },
        visibility = "visible",
        provenance = { source = "live-test" },
        created_at = os.time(),
      },
    },
    tools = {},
  }
end

--- Protocol endpoint/header facts for direct transport.post (non-stream).
---@param protocol string
---@param base_url string
---@param key string
---@return string url
---@return table headers
local function endpoint_facts(protocol, base_url, key)
  local base = base_url:gsub("/+$", "")
  if protocol == "anthropic_messages" then
    return base .. "/v1/messages", {
      ["content-type"] = "application/json",
      ["x-api-key"] = key,
    }
  elseif protocol == "openai_responses" then
    return base .. "/responses", {
      ["Content-Type"] = "application/json",
      Authorization = "Bearer " .. key,
    }
  end
  -- openai_chat
  return base .. "/chat/completions", {
    ["Content-Type"] = "application/json",
    Authorization = "Bearer " .. key,
  }
end

local config = require("maxa.runtime.config")
local transport = require("maxa.runtime.protocol.transport")
local proto = require("maxa.runtime.protocol")
-- Requiring adapter modules triggers register_adapter (self-registration).
require("maxa.runtime.protocol.adapters.openai_chat")
require("maxa.runtime.protocol.adapters.openai_responses")
require("maxa.runtime.protocol.adapters.anthropic_messages")

local key = read_env_file("DEEPSEEK_TEST_KEY")
if not key then
  print("LIVE_FAIL: DEEPSEEK_TEST_KEY not found in " .. ROOT .. "/.env")
  vim.cmd("cq")
  return false
end
vim.env.DEEPSEEK_TEST_KEY = key

print("== maxa W9 live deepseek validation ==")
local all_ok = true

local cases = {
  { id = "deepseek-chat", label = "openai_chat", text = "Reply with exactly: OK" },
  { id = "deepseek-responses", label = "openai_responses", text = "Reply with exactly: OK" },
  { id = "deepseek-anthropic", label = "anthropic_messages", text = "Reply with exactly: OK" },
}

for _, spec in ipairs(cases) do
  local notes = {}
  local ok = true
  local snap, lerr = config.load(ROOT, { resolve_root = false })
  local record
  if not snap then
    ok = false
    notes[#notes + 1] = "resolve: config.load failed: " .. tostring(lerr and lerr.message)
  else
    local rerr
    record, rerr = config.resolve_provider(snap, spec.id)
    if not record then
      ok = false
      notes[#notes + 1] = "resolve_provider failed: " .. tostring(rerr and rerr.message)
    end
  end

  if ok and record then
    local adapter = proto.get_adapter(record.protocol)
    if not adapter then
      ok = false
      notes[#notes + 1] = ("no adapter for %q"):format(record.protocol)
    else
      record:bind(adapter)
      local params, serr = adapter:setup({
        model = record.model,
        stream = true,
        base_url = record.base_url,
        api_key_env = record.api_key_env,
        connect_timeout_ms = record.request and record.request.connect_timeout_ms,
        timeout_ms = record.request and record.request.timeout_ms,
        proxy_env = record.request and record.request.proxy_env,
      })
      if serr then
        ok = false
        notes[#notes + 1] = "setup failed: " .. tostring(serr)
      else
        -- 1. non-streamed: transport.post + parse_nonstream
        local ns_done = false
        local ns_events = {}
        local ns_err
        local ns_body = adapter:build_request(vim.tbl_deep_extend("force", {}, params, { stream = false }), normalized_request(spec.text))
        local url, headers = endpoint_facts(record.protocol, record.base_url, key)
        transport.post({
          url = url,
          headers = headers,
          body = ns_body,
          stream = false,
          connect_timeout_ms = record.request and record.request.connect_timeout_ms,
          timeout_ms = record.request and record.request.timeout_ms or 60000,
        }, {
          on_done = function(response)
            ns_done = true
            if not response or type(response.body) ~= "string" then
              ns_err = "non-stream: missing response body (status=" .. tostring(response and response.status) .. ")"
              return
            end
            if #response.body > 2000 then
              ns_err = ("non-stream: body too large/unexpected (%d bytes): %.120s"):format(
                #response.body,
                response.body:sub(1, 120)
              )
              return
            end
            local ok_decode, decoded = pcall(vim.json.decode, response.body)
            if not ok_decode then
              ns_err = "non-stream: JSON decode failed: " .. tostring(decoded) .. " :: " .. response.body:sub(1, 200)
              return
            end
            if type(decoded) ~= "table" then
              ns_err = "non-stream: decoded body is not a table"
              return
            end
            local evs = adapter:parse_nonstream(decoded)
            if evs then
              if evs.type then
                ns_events[#ns_events + 1] = evs
              else
                for _, e in ipairs(evs) do
                  ns_events[#ns_events + 1] = e
                end
              end
            end
            -- Contract: the caller appends `completed` when the parsed stream
            -- has no terminal event yet (mirrors the fixture driver).
            local has_terminal = false
            for _, e in ipairs(ns_events) do
              if e.type == "completed" or e.type == "error" then
                has_terminal = true
              end
            end
            if not has_terminal then
              ns_events[#ns_events + 1] = require("maxa.runtime.protocol.normalize").completed()
            end
          end,
          on_error = function(err)
            ns_done = true
            ns_err = ("non-stream HTTP/curl error: class=%s status=%s"):format(
              tostring(err and err.message),
              tostring(err and err.cause and err.cause.status)
            )
          end,
        })
        if not wait_for(90000, function()
          return ns_done
        end) then
          ok = false
          notes[#notes + 1] = "non-stream timed out"
        elseif ns_err then
          ok = false
          notes[#notes + 1] = ns_err
        else
          local types = {}
          local usage_seen = false
          local terminal_count = 0
          local err_detail
          for _, e in ipairs(ns_events) do
            types[#types + 1] = e.type
            if e.type == "usage_updated" and e.usage then
              usage_seen = usage_seen
                or (e.usage.input_tokens ~= nil or e.usage.output_tokens ~= nil or e.usage.total_tokens ~= nil)
            end
            if e.type == "error" and e.error then
              err_detail = ("code=%s message=%s"):format(tostring(e.error.code), tostring(e.error.message))
            end
            if e.type == "completed" or e.type == "error" then
              terminal_count = terminal_count + 1
            end
          end
          if terminal_count ~= 1 then
            ok = false
            notes[#notes + 1] = ("non-stream: expected exactly 1 terminal, got %d"):format(terminal_count)
          elseif not usage_seen then
            ok = false
            notes[#notes + 1] = "non-stream: no usage tokens normalized"
          end
          if err_detail then
            notes[#notes + 1] = "nonstream error detail: " .. err_detail
          end
          notes[#notes + 1] = "nonstream events: " .. table.concat(types, ",")
        end

        -- 2. streamed: adapter:stream (full transport + sse + parse path).
        local st_done = false
        local st_events = {}
        local st_err
        -- setup() may normalize away provider fields, so re-inject record fields.
        local st_params = vim.tbl_deep_extend("force", {}, params, {
          stream = true,
          model = record.model,
          base_url = record.base_url,
          api_key_env = record.api_key_env,
          connect_timeout_ms = record.request and record.request.connect_timeout_ms,
          timeout_ms = record.request and record.request.timeout_ms,
          proxy_env = record.request and record.request.proxy_env,
          normalized = normalized_request(spec.text),
        })
        -- anthropic stream() expects caller-supplied url/headers; the OpenAI
        -- adapters build them from base_url/api_key_env internally.
        if record.protocol == "anthropic_messages" then
          st_params.url = (record.base_url:gsub("/+$", "") .. "/v1/messages")
          st_params.headers = {
            ["content-type"] = "application/json",
            ["x-api-key"] = key,
          }
        end
        local handle, herr = adapter:stream(st_params, {
          on_event = function(ev)
            st_events[#st_events + 1] = ev
          end,
          on_done = function()
            st_done = true
            -- Terminal contract: openai_chat emits no terminal at [DONE], so the
            -- caller appends `completed` at stream end; openai_responses emits it
            -- on response.completed and anthropic_messages on message_stop, so
            -- append only when the stream did not already end with a terminal.
            local has_terminal = false
            for _, e in ipairs(st_events) do
              if e.type == "completed" or e.type == "error" then
                has_terminal = true
              end
            end
            if not has_terminal then
              st_events[#st_events + 1] = require("maxa.runtime.protocol.normalize").completed()
            end
          end,
          on_error = function(err)
            st_done = true
            st_err = ("stream error: code=%s class=%s"):format(
              tostring(err and err.code),
              tostring(err and err.message)
            )
          end,
        })
        if not handle then
          ok = false
          notes[#notes + 1] = "stream failed to start: " .. tostring(herr)
        else
          if not wait_for(90000, function()
            return st_done
          end) then
            ok = false
            notes[#notes + 1] = "stream timed out"
          elseif st_err then
            ok = false
            notes[#notes + 1] = st_err
          else
            local types = {}
            local usage_seen = false
            local terminal_count = 0
            for _, e in ipairs(st_events) do
              types[#types + 1] = e.type
              if e.type == "usage_updated" and e.usage then
                usage_seen = usage_seen
                  or (e.usage.input_tokens ~= nil or e.usage.output_tokens ~= nil or e.usage.total_tokens ~= nil)
              end
              if e.type == "completed" or e.type == "error" then
                terminal_count = terminal_count + 1
              end
            end
            if terminal_count ~= 1 then
              ok = false
              notes[#notes + 1] = ("stream: expected exactly 1 terminal, got %d"):format(terminal_count)
            elseif not usage_seen then
              ok = false
              notes[#notes + 1] = "stream: no usage tokens normalized"
            end
            notes[#notes + 1] = "stream events: " .. table.concat(types, ",")
          end
        end
      end
    end
  end

  all_ok = ok and all_ok
  for _, n in ipairs(notes) do
    print("  [" .. spec.label .. "] " .. n)
  end
  print(("  %s => %s"):format(spec.label, ok and "PASS" or "FAIL"))
end

print(all_ok and "LIVE_OK" or "LIVE_FAIL")
if not all_ok then
  vim.cmd("cq")
end
return all_ok
