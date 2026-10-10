local function assert_equal(expected, actual, message)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

package.loaded["maxa.mcphub.native_servers.shared.streaming_llm"] = nil
package.loaded["maxa.http"] = nil
package.loaded["maxa.adapters"] = nil
package.loaded["maxa.session.llm_error_handler"] = nil

package.preload["maxa.adapters"] = function()
  return {
    call_handler = function(_, handler, data, tools)
      if handler == "parse_chat" then
        if data == "reason" then
          return { status = "success", output = { reasoning = { content = "tool reasoning" } } }
        end
        if data == "tool" then
          table.insert(tools, {
            id = "call-1",
            call_id = "call-1",
            type = "function",
            ["function"] = { name = "probe", arguments = "{}" },
          })
          return { status = "success", output = {} }
        end
      elseif handler == "build_reasoning" then
        return { content = data[1].content }
      end
      return nil
    end,
  }
end

package.preload["maxa.http"] = function()
  return {
    new = function()
      return {
        send = function(_, _, callbacks)
          callbacks.on_chunk("reason")
          callbacks.on_chunk("tool")
          callbacks.on_done()
          return {}
        end,
      }
    end,
  }
end

package.preload["maxa.session.llm_error_handler"] = function()
  return {
    TYPES = { TOKEN_LIMIT = "token_limit" },
    extract_error_string = function(err)
      return tostring(err)
    end,
    classify_http_error = function()
      return nil
    end,
  }
end

local streaming_llm = require("maxa.mcphub.native_servers.shared.streaming_llm")
local adapter = {
  map_roles = function(_, messages)
    return messages
  end,
}
local captured
streaming_llm.streaming_request(adapter, {}, {
  tools = {},
  on_tool_calls = function(tool_calls, content, reasoning)
    captured = { tool_calls = tool_calls, content = content, reasoning = reasoning }
  end,
}, function(_, err)
  error("unexpected completion callback: " .. tostring(err))
end)

assert_equal(1, #captured.tool_calls, "tool call count")
assert_equal("probe", captured.tool_calls[1].name, "tool call name")
assert_equal("tool reasoning", captured.reasoning.content, "tool continuation reasoning")
print("streaming_llm_test: OK")
