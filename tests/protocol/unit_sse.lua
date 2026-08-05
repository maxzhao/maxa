-- filepath: tests/protocol/unit_sse.lua
--- Minimal unit tests for lua/maxa/runtime/protocol/sse.lua (phase-1 W1).
---
--- Covers: single data frames, multi-line data, [DONE], blank-line separation,
--- split-chunk feeding (frame completes across feed calls), event/id fields,
--- CRLF tolerance, comment lines, EOF flush via finish(), M.parse convenience,
--- and M.clean_streamed_data (CodeCompanion-equivalent behavior).
---
--- Offline: no network, no external fixtures. Exit 0 on success, `cq` on failure.
---   nvim --headless -l tests/protocol/unit_sse.lua

vim.opt.runtimepath:prepend("/home/maxzhao/maxa")

local function ensure_ecosystem()
  if pcall(require, "plenary.path") then
    return true
  end
  local deadline = vim.loop.hrtime() + 20000 * 1e6
  while vim.loop.hrtime() < deadline do
    if pcall(require, "plenary.path") then
      return true
    end
    vim.wait(100)
  end
  return false
end

if not ensure_ecosystem() then
  print("UNIT_SSE_FAIL: plenary not ready (run `just setup` and boot nvim-maxa once)")
  vim.cmd("cq")
end

local sse = require("maxa.runtime.protocol.sse")

local failures = {}

local function expect(cond, msg)
  if not cond then
    failures[#failures + 1] = msg
  end
end

local function expect_frame(frame, data, msg)
  if type(frame) ~= "table" or frame.data ~= data then
    failures[#failures + 1] = ("%s (got %s)"):format(msg, vim.inspect(frame))
  end
end

-- 1. Simple single frame.
local frames = sse.parse("data: hello world\n\n")
expect(#frames == 1, "single frame count")
expect_frame(frames[1], "hello world", "single frame data")

-- 2. Multi-line data frames join with "\n".
frames = sse.parse("data: first\ndata: second\n\n")
expect(#frames == 1, "multi-line frame count")
expect_frame(frames[1], "first\nsecond", "multi-line frame data")

-- 3. [DONE] marker.
frames = sse.parse("data: [DONE]\n\n")
expect(#frames == 1 and sse.is_done(frames[1]), "[DONE] detection")

-- 4. Multiple frames separated by blank lines.
frames = sse.parse("data: a\n\n\ndata: b\n\n")
expect(#frames == 2, "two frames")
expect_frame(frames[1], "a", "frame 1")
expect_frame(frames[2], "b", "frame 2")

-- 5. Split-chunk feeding: frame completes only when the blank line arrives.
local parser = sse.new()
expect(#parser:feed("data: he") == 0, "partial chunk yields no frame")
expect(#parser:feed("llo\n") == 0, "line end without blank line yields no frame")
frames = parser:feed("\n")
expect(#frames == 1, "blank line dispatches frame")
expect_frame(frames[1], "hello", "split-chunk frame data")
expect(parser.remainder == "", "no leftover buffer after frame")

-- 6. event/id fields preserved.
frames = sse.parse("event: response.output_text.delta\nid: evt-1\ndata: hi\n\n")
expect(#frames == 1, "event frame count")
expect(frames[1].event == "response.output_text.delta", "event field")
expect(frames[1].id == "evt-1", "id field")
expect_frame(frames[1], "hi", "event frame data")

-- 7. CRLF tolerance.
frames = sse.parse("data: crlf\r\n\r\n")
expect(#frames == 1, "crlf frame count")
expect_frame(frames[1], "crlf", "crlf frame data")

-- 8. Comment lines ignored; unknown fields ignored.
frames = sse.parse(": keepalive comment\ndata: ok\nretry: 5000\n\n")
expect(#frames == 1, "comment ignored")
expect_frame(frames[1], "ok", "comment frame data")

-- 9. finish() flushes a trailing partial frame without a blank line (EOF).
parser = sse.new()
expect(#parser:feed("data: eof") == 0, "no frame before EOF")
frames = parser:finish()
expect(#frames == 1, "finish flushes pending frame")
expect_frame(frames[1], "eof", "eof frame data")
expect(#parser:finish() == 0, "second finish is empty")

-- 10. reset() clears state.
parser = sse.new()
parser:feed("data: stale\n")
parser:reset()
frames = parser:feed("data: fresh\n\n")
expect(#frames == 1, "reset clears frame")
expect_frame(frames[1], "fresh", "post-reset frame data")

-- 11. clean_streamed_data: strips SSE field text up to the JSON payload.
local cleaned = sse.clean_streamed_data('event: error\ndata: {"type":"error"}')
expect(cleaned == '{"type":"error"}', "clean strips event prefix")

-- 12. clean_streamed_data: leading whitespace before JSON.
cleaned = sse.clean_streamed_data('   {"error":{"message":"x"}}')
expect(cleaned == '{"error":{"message":"x"}}', "clean strips leading whitespace")

-- 13. clean_streamed_data: table input exposes body (plenary response shape).
cleaned = sse.clean_streamed_data({ body = '{"ok":true}' })
expect(cleaned == '{"ok":true}', "clean table body")

-- 14. clean_streamed_data: non-JSON marker returns unchanged.
cleaned = sse.clean_streamed_data("[DONE]")
expect(cleaned == "[DONE]", "clean leaves [DONE] unchanged")

-- 15. clean_streamed_data: array-prefixed JSON also preserved.
cleaned = sse.clean_streamed_data("garbage [1,2,3]")
expect(cleaned == "[1,2,3]", "clean handles array JSON")

-- 16. Feeding garbage that is not a string is a no-op.
parser = sse.new()
expect(#parser:feed(nil) == 0, "nil chunk no-op")
expect(#parser:feed("") == 0, "empty chunk no-op")

if #failures == 0 then
  print("UNIT_SSE_OK cases=16")
else
  print(("UNIT_SSE_FAIL failures=%d"):format(#failures))
  for _, f in ipairs(failures) do
    print("  - " .. f)
  end
  vim.cmd("cq")
end

return sse
