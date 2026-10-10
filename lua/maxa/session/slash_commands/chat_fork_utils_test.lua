-- filepath: lua/maxa/session/slash_commands/chat_fork_utils_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/slash_commands/chat_fork_utils_test.lua

local history_core = require("maxa.session.history_core")
local session_trace = require("maxa.session.session_trace")
local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name)
    print("  Error: " .. tostring(err))
  end
end

local function assert_true(value, msg)
  if not value then
    error(msg or "expected true")
  end
end

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end
local function with_temp_history(fn)
  local original_get_history_dir = history_core.get_history_dir
  local root = vim.fn.tempname()
  vim.fn.delete(root, "rf")
  vim.fn.mkdir(root, "p")
  history_core.get_history_dir = function()
    local history_dir = root .. "/.maxa/history"
    vim.fn.mkdir(history_dir .. "/chats", "p")
    return history_dir
  end
  local ok, err = pcall(fn, root)
  history_core.get_history_dir = original_get_history_dir
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

local function install_chat_fork_stubs()
  package.loaded["maxa.interactions.chat"] = {
    new = function(opts)
      return {
        opts = vim.deepcopy(opts or {}),
        adapter = opts and opts.adapter or nil,
        settings = opts and vim.deepcopy(opts.settings) or nil,
        buffer_context = opts and vim.deepcopy(opts.buffer_context) or nil,
        messages = vim.deepcopy(opts and opts.messages or {}),
        tools = {},
        tool_registry = {},
        context_items = {},
        ui = { follow = function() end },
        add_buf_message = function() end,
      }
    end,
  }
  package.loaded["maxa.interactions.chat.tools.display"] = {
    build_render_messages = function(messages)
      return vim.deepcopy(messages or {})
    end,
    apply_render_postprocess = function() end,
  }
end

package.preload["maxa.config"] = package.preload["maxa.config"] or function()
  return {
    constants = {
      USER_ROLE = "user",
      LLM_ROLE = "assistant",
      SYSTEM_ROLE = "system",
    },
  }
end

local fork_utils = require("maxa.session.slash_commands.chat_fork_utils")
local cc_config = require("maxa.config")

print("\n=== Testing session chat fork slash utilities ===\n")

test("collect_user_message_items should list visible user messages newest first", function()
  local chat = {
    messages = {
      { role = cc_config.constants.USER_ROLE, content = "first user" },
      { role = cc_config.constants.LLM_ROLE, content = "assistant" },
      { role = cc_config.constants.USER_ROLE, content = "hidden", opts = { visible = false } },
      { role = cc_config.constants.USER_ROLE, content = "restart", _meta = { tag = "nvim_restart_resume" } },
      { role = cc_config.constants.USER_ROLE, content = "context", context = { id = "ctx" } },
      {
        role = cc_config.constants.USER_ROLE,
        content = "[RESUME AGENT - CONTINUE RESTORED SESSION]\n\n你是从历史会话恢复出来的子代理。",
      },
      { role = cc_config.constants.USER_ROLE, content = "second user" },
    },
  }

  local items = fork_utils.collect_user_message_items(chat)

  assert_equal(2, #items, "should keep only visible user messages")
  assert_equal(7, items[1].index, "newest user message should be first")
  assert_equal("second user", items[1].content, "newest content should match")
  assert_equal(1, items[2].index, "oldest user message should be last")
end)

test("build_preview_lines should include focus marker", function()
  local chat = {
    messages = {
      { role = cc_config.constants.USER_ROLE, content = "hello" },
      { role = cc_config.constants.LLM_ROLE, content = "world" },
    },
  }

  local lines, focus_line = fork_utils.build_preview_lines(chat, 2)

  assert_true(#lines > 0, "preview should contain lines")
  assert_true(focus_line >= 1, "focus line should be positive")
  assert_true(lines[focus_line]:match("^▶"), "focus line should contain marker")
end)

  test("extract_summary_content should accept common background result shapes", function()
    assert_equal("plain", fork_utils.extract_summary_content(" plain "), "plain string result should be accepted")
    assert_equal("output string", fork_utils.extract_summary_content({ output = " output string " }), "output string should be accepted")
    assert_equal(
      "output content",
      fork_utils.extract_summary_content({ output = { content = " output content " } }),
      "output.content should be accepted"
    )
    assert_equal("content", fork_utils.extract_summary_content({ content = " content " }), "content should be accepted")
    assert_equal("output text", fork_utils.extract_summary_content({ output_text = " output text " }), "output_text should be accepted")
    assert_equal(
      "responses text",
      fork_utils.extract_summary_content({
        output = {
          {
            type = "message",
            content = {
              { type = "output_text", text = " responses text " },
            },
          },
        },
      }),
      "Responses API output message text should be accepted"
    )
  end)

  test("summary_result_diagnostic should include useful empty-result details", function()
    local diagnostic = fork_utils.summary_result_diagnostic({
      status = "error",
      output = {
        error = { message = "upstream empty response" },
        content = {},
      },
      response = { status = 200 },
    })

    assert_true(diagnostic:match("output_type=table"), "diagnostic should include output type")
    assert_true(diagnostic:match("status=error"), "diagnostic should include status")
    assert_true(diagnostic:match("upstream empty response"), "diagnostic should include nested error message")
    assert_true(diagnostic:match("response_status=200"), "diagnostic should include response status")
  end)

  test("append_summary_message should append visible summary and restore blank edit area", function()
  local buf_messages = {}
  local chat = {
    header_line = 10,
    messages = {},
    add_message = function(self, msg, opts)
      table.insert(self.messages, { msg = msg, opts = opts })
    end,
    add_buf_message = function(self, msg, opts)
      table.insert(buf_messages, { msg = msg, opts = opts })
    end,
  }

  local ok, err = fork_utils.append_summary_message(chat, "agent 回复了 `ok`。", {
    content = "agent 回复了 `ok`。",
  })

  assert_true(ok, err or "append should succeed")
  assert_equal(1, #chat.messages, "summary should be appended to message stack")
  assert_equal(2, #buf_messages, "summary should be followed by a separate editable user area")
  assert_equal("agent 回复了 `ok`。", buf_messages[1].msg.content, "buffer content should be pure summary")
  assert_equal(nil, buf_messages[1].opts.insert_at, "summary should not use direct insert_at hack")
  assert_true(buf_messages[1].opts.force_role, "summary should force its own user header")
  assert_equal("", buf_messages[2].msg.content, "blank edit area should be restored after summary")
  assert_true(buf_messages[2].opts.force_role, "blank edit area should force user role")
end)

  test("replace_summary_range should replace selected message range and rerender blank edit area", function()
    local rendered_messages = nil
    local restored_inputs = {}
    local chat = {
      messages = {
        { role = cc_config.constants.USER_ROLE, content = "keep", context = { id = "keep_ctx" }, _meta = { index = 1 } },
        { role = cc_config.constants.USER_ROLE, content = "start", context = { id = "drop_ctx" }, _meta = { index = 2 } },
        { role = cc_config.constants.LLM_ROLE, content = "answer", _meta = { index = 3 } },
        { role = cc_config.constants.USER_ROLE, content = "tail", _meta = { index = 4 } },
      },
      context_items = { { id = "keep_ctx" }, { id = "drop_ctx" } },
      tools = {},
      buffer_context = {},
      opts = { compact_protected_prefix_count = 99 },
      add_buf_message = function(_, msg, opts)
        table.insert(restored_inputs, { msg = msg, opts = opts })
      end,
      ui = {
        render = function(_, _, messages)
          rendered_messages = messages
        end,
        display_tokens = function() end,
        follow = function() end,
      },
    }

    local ok, result = fork_utils.replace_summary_range(chat, 2, 4, "summary body", {
      content = "summary block",
      source = "summarize",
      range = { start_index = 2, end_index = 4 },
    })

    assert_true(ok, result or "replace should succeed")
    assert_equal(3, result.removed_count, "selected range should be removed")
    assert_equal(2, result.summary_index, "summary should replace range start")
    assert_equal(2, #chat.messages, "message stack should keep prefix plus summary")
    assert_equal("keep", chat.messages[1].content, "prefix message should remain")
    assert_equal("summary block", chat.messages[2].content, "summary should replace removed range")
    assert_equal("summarize", chat.messages[2]._meta.source, "summary metadata should be stored on message")
    assert_equal(1, #chat.context_items, "context items from removed range should be pruned")
    assert_equal("keep_ctx", chat.context_items[1].id, "prefix context item should remain")
    assert_equal(chat.messages, chat.tools.messages, "tools should point at replacement message stack")
    assert_equal(2, chat.opts.compact_protected_prefix_count, "protected prefix should be clamped")
    assert_true(type(rendered_messages) == "table", "UI should be rerendered from replacement stack")
    assert_equal(2, #rendered_messages, "UI render should contain only persisted messages")
    assert_equal("keep", rendered_messages[1].content, "rendered prefix should remain")
    assert_equal("summary block", rendered_messages[2].content, "rendered summary should replace removed UI range")
    assert_equal(1, #restored_inputs, "blank edit area should be restored explicitly after render")
    assert_equal("", restored_inputs[1].msg.content, "restored edit area should be blank")
    assert_true(restored_inputs[1].opts.force_role, "blank edit area should force user role")
  end)

test("merge_scratch should not restore wrapped parent input", function()
  local rendered_messages = nil
  local parent = {
    id = 1,
    opts = { save_id = "parent" },
    messages = {},
    context_items = {},
    header_line = 1,
    chat_parser = {},
    buffer_context = {},
    ui = {
      render = function(_, _, messages)
        rendered_messages = messages
      end,
    },
    add_buf_message = function()
      error("merge should not use incremental add_buf_message path")
    end,
  }
  local scratch = {
    id = 2,
    opts = { save_id = history_core.make_unsavable_save_id("scratch") },
    _session_scratch_parent_chat = parent,
    _meta = {
      session_scratch = {
        parent_key = "id:1",
        fork_start_index = 1,
      },
    },
    messages = {
      { role = cc_config.constants.USER_ROLE, content = "original" },
      { role = cc_config.constants.LLM_ROLE, content = "ok" },
    },
    context_items = {},
    add_buf_message = function() end,
  }

  local ok, err = fork_utils.merge_scratch(scratch)

  assert_true(ok, err or "merge should succeed")
  assert_equal(1, #parent.messages, "scratch message should be merged")
  assert_equal(cc_config.constants.LLM_ROLE, parent.messages[1].role, "real scratch message should be merged")
  assert_equal("ok", parent.messages[1].content, "real scratch content should be preserved")
  assert_true(type(rendered_messages) == "table", "merge should rerender parent from message stack")
  assert_equal("ok", rendered_messages[1].content, "first rendered message should be scratch content")
  assert_equal("", rendered_messages[#rendered_messages].content, "rendered tail should be empty input area")
end)

test("merge_scratch should preserve wrapped text if it is an actual scratch message", function()
  local parent = {
    id = 1,
    opts = { save_id = "parent" },
    messages = {},
    context_items = {},
    add_buf_message = function() end,
  }
  local wrapped = "[RESUME AGENT - CONTINUE RESTORED SESSION]\n\n如果这是 scratch 中真实存在的消息，应原样合并。"
  local scratch = {
    id = 2,
    opts = { save_id = history_core.make_unsavable_save_id("scratch") },
    _session_scratch_parent_chat = parent,
    _meta = {
      session_scratch = {
        parent_key = "id:1",
        fork_start_index = 1,
      },
    },
    messages = {
      { role = cc_config.constants.USER_ROLE, content = "original" },
      { role = cc_config.constants.USER_ROLE, content = wrapped },
    },
    context_items = {},
    add_buf_message = function() end,
  }

  local ok, err = fork_utils.merge_scratch(scratch)

  assert_true(ok, err or "merge should succeed")
  assert_equal(1, #parent.messages, "actual scratch message should be merged")
  assert_equal(wrapped, parent.messages[1].content, "scratch message content should be preserved exactly")
end)

 test("is_scratch_chat should require scratch save_id and metadata", function()
   local save_id = history_core.make_unsavable_save_id("scratch")

   assert_true(not fork_utils.is_scratch_chat({ opts = { save_id = save_id } }), "metadata is required")
   assert_true(fork_utils.is_scratch_chat({
     opts = { save_id = save_id },
     _meta = {
       session_scratch = { parent_key = "id:1", fork_start_index = 1 },
     },
   }), "scratch metadata plus save_id should be accepted")
 end)

 test("close_chat_with_scratch_guard should close normal chats without confirmation", function()
   local closed = false
   local prompted = false
   local chat = { opts = { save_id = "normal" } }

   fork_utils.close_chat_with_scratch_guard(chat, {
     close_fn = function(target)
       assert_equal(chat, target, "close should receive original chat")
       closed = true
     end,
     win_factory = function()
       prompted = true
     end,
   })

   assert_true(closed, "normal chat should close immediately")
   assert_true(not prompted, "normal chat should not prompt")
 end)

 test("close_chat_with_scratch_guard should keep scratch open when confirmation UI is unavailable", function()
   local closed = false
   local notified = false
   local chat = {
     opts = { save_id = history_core.make_unsavable_save_id("scratch") },
     _meta = {
       session_scratch = { parent_key = "id:1", fork_start_index = 1 },
     },
   }

   local guarded = fork_utils.close_chat_with_scratch_guard(chat, {
     close_fn = function()
       closed = true
     end,
     win_factory = false,
     notify = function()
       notified = true
     end,
   })

   assert_true(not guarded, "scratch chat should not proceed without confirmation UI")
   assert_true(not closed, "scratch chat should not close when confirmation UI is unavailable")
   assert_true(notified, "UI fallback should notify user")
 end)

 test("close_chat_with_scratch_guard should cancel scratch close on n q and Esc", function()
   for _, key in ipairs({ "n", "q", "esc" }) do
     local closed = false
     local notified = false
     local win_opts = nil
     local fake_win = nil
     local chat = {
       opts = { save_id = history_core.make_unsavable_save_id("scratch") },
       _meta = {
         session_scratch = { parent_key = "id:1", fork_start_index = 1 },
       },
     }

     local guarded = fork_utils.close_chat_with_scratch_guard(chat, {
       close_fn = function()
         closed = true
       end,
       win_factory = function(opts)
         win_opts = opts
         fake_win = {}
         function fake_win:close()
           if opts.on_close then
             opts.on_close(fake_win)
           end
         end
         return fake_win
       end,
       notify = function()
         notified = true
       end,
     })

     assert_true(guarded, "scratch chat should enter guarded close path for " .. key)
     assert_true(type(win_opts) == "table", "scratch confirmation should create a Snacks window for " .. key)
     win_opts.keys[key][2](fake_win)
     assert_true(not closed, "scratch chat should not close on " .. key)
     assert_true(notified, "cancel should notify user for " .. key)
   end
 end)

 test("close_chat_with_scratch_guard should accept callable table window factories", function()
   local created = false
   local chat = {
     opts = { save_id = history_core.make_unsavable_save_id("scratch") },
     _meta = {
       session_scratch = { parent_key = "id:1", fork_start_index = 1 },
     },
   }
   local callable_factory = setmetatable({}, {
     __call = function(_, opts)
       created = type(opts) == "table"
       return { close = function() end }
     end,
   })

   local guarded = fork_utils.close_chat_with_scratch_guard(chat, {
     close_fn = function() end,
     win_factory = callable_factory,
   })

   assert_true(guarded, "callable table window factory should be accepted")
   assert_true(created, "callable table window factory should be invoked")
 end)

 test("close_chat_with_scratch_guard should close scratch only on uppercase Y", function()
   local closed = false
   local win_opts = nil
   local fake_win = nil
   local chat = {
     opts = { save_id = history_core.make_unsavable_save_id("scratch") },
     _meta = {
       session_scratch = { parent_key = "id:1", fork_start_index = 1 },
     },
   }

   fork_utils.close_chat_with_scratch_guard(chat, {
     close_fn = function()
       closed = true
     end,
     win_factory = function(opts)
       win_opts = opts
       fake_win = {}
       function fake_win:close()
         if opts.on_close then
           opts.on_close(fake_win)
         end
       end
       return fake_win
     end,
   })

   assert_true(type(win_opts) == "table", "scratch confirmation should create a Snacks window")
   assert_equal(nil, win_opts.keys.y, "lowercase y must not confirm scratch close")
   win_opts.keys.Y[2](fake_win)
   assert_true(closed, "scratch chat should close only after uppercase Y confirmation")
 end)

  test("save_scratch_chat promotes scratch to persistent history chat", function()
    local previous_save_id = history_core.make_unsavable_save_id("scratch")
    local parent = { id = 1 }
    local saved_chat = nil
    local chat = {
      id = 2,
      opts = { save_id = previous_save_id, title = "Scratch" },
      _session_scratch_parent_chat = parent,
      _meta = {
        session_scratch = {
          parent_key = "id:1",
          parent_save_id = "parent_save",
          parent_bufnr = 11,
          parent_id = 1,
          fork_start_index = 3,
          created_at = 1234,
        },
        keep = "yes",
      },
      messages = {
        { role = cc_config.constants.USER_ROLE, content = "scratch message" },
      },
    }

    local result, err = fork_utils.save_scratch_chat(chat, {
      generate_save_id = function()
        return "saved_scratch_1"
      end,
      now = function()
        return 5678
      end,
      history_api = {
        save_chat = function(target)
          saved_chat = target
        end,
        load_chat = function(save_id)
          if save_id == "saved_scratch_1" then
            return { save_id = save_id }
          end
          return nil
        end,
      },
    })

    assert_true(result, err or "save should succeed")
    assert_equal("saved_scratch_1", result.save_id, "result should report new save_id")
    assert_equal(previous_save_id, result.previous_save_id, "result should report previous save_id")
    assert_equal("saved_scratch_1", chat.opts.save_id, "chat should receive persistent save_id")
    assert_equal(nil, chat._meta.session_scratch, "scratch identity metadata should be removed")
    assert_equal("yes", chat._meta.keep, "unrelated metadata should be preserved")
    assert_equal(nil, chat._session_scratch_parent_chat, "parent object reference should be cleared")
    assert_equal(chat, saved_chat, "history API should save the promoted live chat")
    assert_true(not fork_utils.is_scratch_chat(chat), "promoted chat should no longer be scratch")

    local provenance = chat._meta.session_saved_from_scratch
    assert_true(type(provenance) == "table", "saved-from-scratch provenance should be stored")
    assert_equal(previous_save_id, provenance.previous_save_id, "previous save_id should be recorded")
    assert_equal("id:1", provenance.parent_key, "parent key should be recorded")
    assert_equal("parent_save", provenance.parent_save_id, "parent save_id should be recorded")
    assert_equal(11, provenance.parent_bufnr, "parent bufnr should be recorded")
    assert_equal(1, provenance.parent_id, "parent id should be recorded")
    assert_equal(3, provenance.fork_start_index, "fork start index should be recorded")
    assert_equal(1234, provenance.scratch_created_at, "scratch creation time should be recorded")
    assert_equal(5678, provenance.saved_at, "save time should be recorded")
  end)

  test("save_scratch_chat rejects non-scratch chat without mutation", function()
    local chat = {
      opts = { save_id = "normal" },
      _meta = { keep = "yes" },
    }

    local result, err = fork_utils.save_scratch_chat(chat, {
      history_api = {
        save_chat = function()
          error("non-scratch chat should not be saved")
        end,
      },
      generate_save_id = function()
        return "new_id"
      end,
    })

    assert_equal(nil, result, "non-scratch save should fail")
    assert_true(tostring(err):match("Only scratch"), "error should explain scratch-only behavior")
    assert_equal("normal", chat.opts.save_id, "save_id should not mutate")
    assert_equal("yes", chat._meta.keep, "metadata should not mutate")
  end)

  test("save_scratch_chat rejects busy scratch without mutation", function()
    local previous_save_id = history_core.make_unsavable_save_id("scratch")
    local chat = {
      opts = { save_id = previous_save_id },
      current_request = {},
      _meta = {
        session_scratch = { parent_key = "id:1", fork_start_index = 1 },
      },
    }

    local result, err = fork_utils.save_scratch_chat(chat, {
      history_api = {
        save_chat = function()
          error("busy chat should not be saved")
        end,
      },
      generate_save_id = function()
        return "new_id"
      end,
    })

    assert_equal(nil, result, "busy scratch save should fail")
    assert_true(tostring(err):match("busy"), "error should explain busy state")
    assert_equal(previous_save_id, chat.opts.save_id, "save_id should remain scratch")
    assert_true(fork_utils.is_scratch_chat(chat), "chat should remain scratch")
  end)

  test("save_scratch_chat rolls back when verification fails", function()
    local previous_save_id = history_core.make_unsavable_save_id("scratch")
    local parent = { id = 1 }
    local chat = {
      opts = { save_id = previous_save_id },
      _session_scratch_parent_chat = parent,
      _meta = {
        session_scratch = { parent_key = "id:1", fork_start_index = 1 },
        keep = "yes",
      },
    }

    local result, err = fork_utils.save_scratch_chat(chat, {
      generate_save_id = function()
        return "saved_but_missing"
      end,
      history_api = {
        save_chat = function() end,
        load_chat = function()
          return nil
        end,
      },
    })

    assert_equal(nil, result, "verification failure should fail")
    assert_true(tostring(err):match("verify"), "error should explain verification failure")
    assert_equal(previous_save_id, chat.opts.save_id, "save_id should be restored")
    assert_true(fork_utils.is_scratch_chat(chat), "chat should remain scratch after rollback")
    assert_equal(parent, chat._session_scratch_parent_chat, "parent reference should be restored")
    assert_equal("yes", chat._meta.keep, "unrelated metadata should be restored")
    assert_equal(nil, chat._meta.session_saved_from_scratch, "provenance should not remain after rollback")
  end)


test("fork_current_chat propagates trace membership for tracked fork and scratch", function()
  with_temp_history(function()
    install_chat_fork_stubs()
    session_trace.ensure_manifest("trace_root", {})
    local parent = {
      id = 1,
      bufnr = 11,
      adapter = "adapter",
      opts = { save_id = "root_save", title = "Root" },
      messages = {
        { role = cc_config.constants.USER_ROLE, content = "prompt" },
        { role = cc_config.constants.LLM_ROLE, content = "reply" },
      },
      _meta = {},
      tools = {},
      tool_registry = {},
      context_items = {},
      settings = {},
    }
    session_trace.set_membership(parent, session_trace.create_root_membership("trace_root", { span_id = "span_parent" }))

    local child, child_err = fork_utils.fork_current_chat(parent, { scratch = false })
    assert_true(child ~= nil, child_err or "fork should succeed")
    local child_trace = session_trace.get_membership(child)
    assert_true(type(child_trace) == "table", "fork child should receive trace membership")
    assert_equal("trace_root", child_trace.root_trace_id, "fork child root trace should match parent")
    assert_equal("fork", child_trace.session_role, "fork child role should be fork")
    assert_equal("span_parent", child_trace.parent_span_id, "fork child should link parent span")
    assert_true(child_trace.span_id ~= "span_parent", "fork child should receive a new span")

    local scratch, scratch_err = fork_utils.fork_current_chat(parent, { scratch = true })
    assert_true(scratch ~= nil, scratch_err or "scratch should succeed")
    local scratch_trace = session_trace.get_membership(scratch)
    assert_true(type(scratch_trace) == "table", "scratch child should receive trace membership")
    assert_equal("trace_root", scratch_trace.root_trace_id, "scratch root trace should match parent")
    assert_equal("scratch", scratch_trace.session_role, "scratch child role should be scratch")
    assert_equal("span_parent", scratch_trace.parent_span_id, "scratch child should link parent span")
    assert_true(fork_utils.is_scratch_chat(scratch), "tracked scratch should still be a scratch chat")

    local kinds = {}
    for _, event in ipairs(session_trace.read_events("trace_root")) do
      kinds[event.kind] = (kinds[event.kind] or 0) + 1
    end
    assert_equal(1, kinds["fork.created"], "fork.created should be recorded once")
    assert_equal(1, kinds["scratch.created"], "scratch.created should be recorded once")
  end)
end)

test("save_scratch_chat preserves tracked scratch span during promotion", function()
  with_temp_history(function()
    session_trace.ensure_manifest("trace_save_root", {})
    local previous_save_id = history_core.make_unsavable_save_id("scratch")
    local saved_meta = nil
    local chat = {
      opts = { save_id = previous_save_id },
      _meta = {
        session_scratch = { parent_key = "id:1", parent_save_id = "parent_save", fork_start_index = 2, created_at = 123 },
      },
    }
    session_trace.set_membership(chat, {
      root_trace_id = "trace_save_root",
      root_save_id = "trace_save_root",
      span_id = "span_scratch",
      parent_span_id = "span_parent",
      session_role = "scratch",
      active = true,
      started_at = 100,
    })
    local result, err = fork_utils.save_scratch_chat(chat, {
      generate_save_id = function()
        return "promoted_save_id"
      end,
      now = function()
        return 456
      end,
      history_api = {
        save_chat = function(target)
          saved_meta = vim.deepcopy(target._meta)
        end,
        load_chat = function(save_id)
          return save_id == "promoted_save_id" and { save_id = save_id } or nil
        end,
      },
    })
    assert_true(result ~= nil, err or "tracked scratch save should succeed")
    local promoted_trace = session_trace.get_membership(chat)
    assert_equal("span_scratch", promoted_trace.span_id, "promotion should preserve scratch span")
    assert_equal("promoted_scratch", promoted_trace.session_role, "promotion should update session role")
    assert_equal("span_parent", promoted_trace.parent_span_id, "promotion should preserve parent span")
    assert_true(type(saved_meta.session_trace) == "table", "saved chat should persist trace metadata")
    assert_equal("promoted_scratch", saved_meta.session_trace.session_role, "saved trace role should be promoted_scratch")
    local events = session_trace.read_events("trace_save_root")
    assert_equal(1, #events, "one scratch.saved event should be recorded")
    assert_equal("scratch.saved", events[1].kind, "event kind should be scratch.saved")
    assert_equal("span_scratch", events[1].span_id, "scratch.saved should use preserved span")
    assert_equal(previous_save_id, events[1].scratch.previous_save_id, "event should record previous scratch save_id")
    assert_equal("promoted_save_id", events[1].saved.save_id, "event should record promoted save_id")
  end)
end)

test("merge_scratch records tracked scratch merge lineage", function()
  with_temp_history(function()
    session_trace.ensure_manifest("trace_merge_root", {})
    local parent = {
      id = 1,
      opts = { save_id = "parent_save" },
      messages = {
        { role = cc_config.constants.USER_ROLE, content = "parent prompt" },
      },
      context_items = {},
      tools = {},
      add_buf_message = function() end,
    }
    session_trace.set_membership(parent, {
      root_trace_id = "trace_merge_root",
      root_save_id = "trace_merge_root",
      span_id = "span_parent",
      session_role = "root",
      active = true,
      started_at = 1,
    })
    local scratch = {
      id = 2,
      opts = { save_id = history_core.make_unsavable_save_id("scratch") },
      _session_scratch_parent_chat = parent,
      _meta = { session_scratch = { parent_key = "id:1", parent_save_id = "parent_save", fork_start_index = 1 } },
      messages = {
        { role = cc_config.constants.USER_ROLE, content = "base" },
        { role = cc_config.constants.LLM_ROLE, content = "scratch reply" },
      },
      context_items = {},
      add_buf_message = function() end,
    }
    session_trace.set_membership(scratch, {
      root_trace_id = "trace_merge_root",
      root_save_id = "trace_merge_root",
      span_id = "span_scratch",
      parent_span_id = "span_parent",
      session_role = "scratch",
      active = true,
      started_at = 2,
    })
    local ok, err = fork_utils.merge_scratch(scratch)
    assert_true(ok, err or "tracked merge should succeed")
    local events = session_trace.read_events("trace_merge_root")
    assert_equal(1, #events, "one scratch.merged event should be recorded")
    assert_equal("scratch.merged", events[1].kind, "event kind should be scratch.merged")
    assert_equal("span_scratch", events[1].span_id, "source span should be scratch")
    assert_equal("span_parent", events[1].parent_span_id, "parent span should be recorded")
    assert_equal(2, events[1].merged_range.start_index, "merged source range should start after fork")
    assert_equal(2, events[1].merged_range.end_index, "merged source range should end at scratch tail")
    assert_equal(1, events[1].appended_count, "merged event should record appended count")
    assert_equal(2, events[1].parent_appended_range.start_index, "parent appended range should be recorded")
  end)
end)

test("rewind_current_chat restores latest manual user message as editable input", function()
   local rendered_messages = nil
   local chat = {
     messages = {
       { role = cc_config.constants.USER_ROLE, content = "first", _meta = { index = 1 } },
       { role = cc_config.constants.LLM_ROLE, content = "ok", _meta = { index = 2 } },
       { role = cc_config.constants.USER_ROLE, content = "context", context = { id = "ctx" }, _meta = { index = 3 } },
       { role = cc_config.constants.USER_ROLE, content = "second", _meta = { index = 4 } },
       { role = cc_config.constants.LLM_ROLE, content = "answer", _meta = { index = 5 } },
     },
     context_items = { { id = "ctx" } },
     tools = {},
     buffer_context = {},
     opts = { compact_protected_prefix_count = 99 },
     ui = {
       render = function(_, _, messages)
         rendered_messages = messages
       end,
       display_tokens = function() end,
       follow = function() end,
     },
   }

   local ok, result = fork_utils.rewind_current_chat(chat)

   assert_true(ok, result or "rewind should succeed")
   assert_equal(2, result.removed_count, "should remove selected user message through tail")
   assert_equal(4, result.index, "should select latest manual user message")
   assert_equal(3, #chat.messages, "message stack should keep only messages before selected input")
   assert_equal("context", chat.messages[3].content, "non-manual earlier context message should remain")
   assert_equal(1, #chat.context_items, "referenced context item should remain")
   assert_equal(chat.messages, chat.tools.messages, "tools should point at current message stack")
   assert_equal(3, chat.opts.compact_protected_prefix_count, "protected prefix should be clamped")
   assert_true(type(rendered_messages) == "table", "chat should be rerendered")
   assert_equal("second", rendered_messages[#rendered_messages].content, "latest manual input should be editable tail")
 end)

  test("rewind_chat_to_user_message restores selected earlier manual user message", function()
    local rendered_messages = nil
    local chat = {
      messages = {
        { role = cc_config.constants.USER_ROLE, content = "first", _meta = { index = 1 } },
        { role = cc_config.constants.LLM_ROLE, content = "first answer", _meta = { index = 2 } },
        { role = cc_config.constants.USER_ROLE, content = "second", _meta = { index = 3 } },
        { role = cc_config.constants.LLM_ROLE, content = "second answer", _meta = { index = 4 } },
      },
      context_items = {},
      tools = {},
      buffer_context = {},
      opts = { compact_protected_prefix_count = 99 },
      ui = {
        render = function(_, _, messages)
          rendered_messages = messages
        end,
        display_tokens = function() end,
        follow = function() end,
      },
    }

    local ok, result = fork_utils.rewind_chat_to_user_message(chat, 1)

    assert_true(ok, result or "rewind_to should succeed")
    assert_equal(4, result.removed_count, "should remove selected user message through tail")
    assert_equal(1, result.index, "should rewind to explicitly selected user message")
    assert_equal(0, #chat.messages, "message stack should keep only messages before selected input")
    assert_equal(0, chat.opts.compact_protected_prefix_count, "protected prefix should be clamped to remaining stack")
    assert_true(type(rendered_messages) == "table", "chat should be rerendered")
    assert_equal("first", rendered_messages[#rendered_messages].content, "selected manual input should be editable tail")
  end)

  test("redo_current_chat rewinds and submits restored input", function()
   local submitted = false
   local chat = {
     messages = {
       { role = cc_config.constants.USER_ROLE, content = "retry me" },
       { role = cc_config.constants.LLM_ROLE, content = "old answer" },
     },
     context_items = {},
     tools = {},
     buffer_context = {},
     ui = {
       render = function() end,
       display_tokens = function() end,
       follow = function() end,
     },
     submit = function()
       submitted = true
     end,
   }

   local ok, result = fork_utils.redo_current_chat(chat, { schedule = false })

   assert_true(ok, result or "redo should succeed")
   assert_true(submitted, "redo should submit after rewind")
   assert_equal(2, result.removed_count, "redo should use rewind removal semantics")
   assert_equal(0, #chat.messages, "redo should leave previous turn removed before submit")
 end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
