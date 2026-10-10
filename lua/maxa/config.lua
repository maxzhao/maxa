local providers = require("maxa.providers")

local builtin_tools = require("maxa.interactions.chat.tools.builtin")
local upload_hostname = require("maxa.utils.env").get("MAXA_CERT_DOMAIN")
if not upload_hostname or upload_hostname == "" then
  upload_hostname = "127.0.0.1"
end

local constants = {
  LLM_ROLE = "llm",
  USER_ROLE = "user",
  SYSTEM_ROLE = "system",
}

local defaults = {
  adapters = {
    http = {
      opts = {
        allow_insecure = true, -- Skip TLS certificate verification; set false to enforce it
        show_defaults = false,
        cache_models_for = 1800, -- Cache adapter models for this long (seconds)
        show_presets = true, -- Show preset adapters
        show_model_choices = true, -- Show model choices when changing adapter
      },
    },
    opts = {
      cmd_timeout = 300000, -- Timeout for commands that resolve env variables (milliseconds)
    },
  },
  constants = constants,
  maxa = {
    proxy = "env", -- Default address source; provider opt-in is still required
    presets = {},
    defaults = {
      chat = {},
      compact = { adapter = "inherit" },
      image = { model = "gpt-image-2.5", text_model = "gpt-5.5", requested_size = "auto", output_format = "png" },
      tts = { model = "gpt-4o-mini-tts", voice = "alloy", response_format = "mp3", speed = 1 },
      video = { model = "sora-2", seconds = 6, size = "1280x720", resolution_name = "720p", generation_preset = "normal" },
    },
    -- The effective catalog combines protocol adapter choices and model_limits; add
    -- supported gateway models here rather than repeating them per provider.
    models = {
      ["gpt-6-astra"] = {
        llm = {
          openai_responses = {
            formatted_name = "GPT-6-astra",
            opts = { has_function_calling = true, has_vision = true, can_reason = true },
          },
        },
      },
      ["gpt-6-sol"] = {
        llm = {
          openai_responses = {
            formatted_name = "GPT-6-sol",
            opts = { has_function_calling = true, has_vision = true, can_reason = true },
          },
        },
      },
      ["gpt-6.1-sol"] = {
        llm = {
          openai_responses = {
            formatted_name = "GPT-6.1-sol",
            opts = { has_function_calling = true, has_vision = true, can_reason = true },
          },
        },
      },
      ["gpt-6-luna"] = {
        llm = {
          openai_responses = {
            formatted_name = "GPT-6-luna",
            opts = { has_function_calling = true, has_vision = true, can_reason = true },
          },
        },
      },
      ["gpt-5.6-sol"] = {
        llm = {
          openai_responses = {
            formatted_name = "GPT-5.6-sol",
            opts = { has_function_calling = true, has_vision = true, can_reason = true },
          },
        },
      },
      ["gpt-5.6-terra"] = {
        llm = {
          openai_responses = {
            formatted_name = "GPT-5.6-terra",
            opts = { has_function_calling = true, has_vision = true, can_reason = true },
          },
        },
      },
      ["gpt-5.6-luna"] = {
        llm = {
          openai_responses = {
            formatted_name = "GPT-5.6-luna",
            opts = { has_function_calling = true, has_vision = true, can_reason = true },
          },
        },
      },
      ["claude-opus-5"] = {
        llm = {
          anthropic_messages = { formatted_name = "Claude Opus 5", opts = { can_reason = true, has_vision = true } },
        },
      },
      ["claude-fable-5"] = {
        llm = {
          anthropic_messages = { formatted_name = "Claude Fable 5", opts = { can_reason = true, has_vision = true } },
        },
      },
      ["deepseek-v4-flash"] = {
        llm = {
          openai_responses = {
            formatted_name = "DeepSeek V4 Flash",
            opts = { has_function_calling = true, can_reason = true },
          },
        },
      },
    },
    providers = {},
    protocol_defaults = {},
    model_limits = { adapter_overrides = {}, model_overrides = {} },
    lifecycle = {
      watchdog = {
        connect_timeout_ms = 180000,
        first_response_timeout_ms = 180000,
        response_idle_timeout_ms = 180000,
        tool_args_idle_timeout_ms = 180000,
        check_interval_ms = 10000,
      },
      token_decision = { threshold_percent = 95, primary_finish_rounds = 8, emergency_finish_rounds = 3 },
    },
    recovery = {
      network_issue = { max_retries = 5, delays = { 10, 20, 30, 60, 60 } },
      rate_limited = { max_retries = 5, delays = { 10, 20, 30, 60, 60 } },
      token_limit = { max_retries = 5, delays = { 10, 20, 30, 60, 60 } },
    },
    compaction = {
      profile = "balanced",
      summarize_timeout_ms = 120000,
      batch_wait_ms = 300000,
      rate_limit_delay_ms = 2000,
      max_concurrency = 0,
    },
    translate = {
      allowed_extensions = { "md", "markdown", "txt", "rst", "adoc" },
      target_language = "简体中文",
      window = "vsplit",
      keymap = "<leader>at",
      force_keymap = "<leader>aT",
    },
    telegram_bridge = {
      enabled = false,
      url = "http://127.0.0.1:8765",
      token = "",
      poll_timeout = 30,
      heartbeat_interval_ms = 10000,
      version = "maxa-nvim",
      auto_start = false,
      upload = { max_retries = 5 },
    },
    genai = {
      output_dir = vim.fn.stdpath("cache") .. "/genai-media",
    },
    status = {
      spinner = {
        spinners = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
        interval_ms = 100,
        default_text = "请求中...",
        tool_args_debounce_ms = 2000,
      },
      state = { refresh_interval_ms = 100 },
    },
    tools = {
      edit_file = {
        parser = { default_delimiter = "EDIT_FILE" },
        locator = { fuzzy_threshold = 0.8, enable_fuzzy_matching = true },
      },
    },
    subagent = { max_recursion_depth = 5 },
    chat_upload = { hostname = upload_hostname, cli = vim.fn.stdpath("config") .. "/tools/chat-upload/src/cli.mjs" },
    file_links = { port = 43128, allowed_roots = { ".maxa" } },
    mcphub = {
      use_bundled_binary = true,
      mcp_request_timeout = 600000,
      explicit_server_activation = true,
    },
  },
  interactions = {
    -- BACKGROUND INTERACTION -------------------------------------------------
    background = {
    },
    -- CHAT INTERACTION -------------------------------------------------------
    chat = {
      adapter = "openai",
      roles = {
        ---The header name for the LLM's messages
        ---@type string|fun(adapter: MaxaAI.HTTPAdapter): string
        llm = function(adapter)
          local adapter_name = adapter.formatted_name or adapter.name or "LLM"
          local model_name = adapter.model and adapter.model.name
          if model_name and model_name ~= "" then
            return adapter_name .. " (" .. model_name .. ")"
          end
          return adapter_name
        end,

        ---The header name for your messages
        ---@type string
        user = "Me",
      },
      tools = builtin_tools.apply({
        opts = {
          auto_submit_errors = true, -- Send any errors to the LLM automatically?
          auto_submit_success = true, -- Send any successful output to the LLM automatically?
          folds = {
            enabled = true, -- Fold tool output in the buffer?
            failure_words = { -- Words that indicate an error in the tool output. Used to apply failure highlighting
              "cancelled",
              "error",
              "failed",
              "incorrect",
              "invalid",
              "rejected",
            },
          },
          ---Tools that are always loaded in a chat buffer
          ---@type string[]
          default_tools = vim.deepcopy(builtin_tools.names),
        },
      }),
      slash_commands = {
        ["buffer"] = {
          callback = "interactions.chat.slash_commands.builtin.buffer",
          description = "Insert open buffers",
          opts = {
            contains_code = true,
            provider = providers.pickers, -- telescope|fzf_lua|mini_pick|snacks|default
          },
        },
        ["compact"] = {
          callback = "interactions.chat.slash_commands.builtin.compact",
          description = "Clears some of the chat history, keeping a summary in context",
          enabled = function(opts)
            if opts.adapter and opts.adapter.type == "http" then
              return true
            end
            return false
          end,
          opts = {
            contains_code = false,
          },
        },
        ["quickfix"] = {
          callback = "interactions.chat.slash_commands.builtin.quickfix",
          description = "Insert quickfix list entries",
          opts = {
            contains_code = true,
          },
        },
        ["file"] = {
          callback = "interactions.chat.slash_commands.builtin.file",
          description = "Insert a file",
          opts = {
            contains_code = true,
            max_lines = 1000,
            provider = providers.pickers, -- telescope|fzf_lua|mini_pick|snacks|default
          },
        },
        ["help"] = {
          callback = "interactions.chat.slash_commands.builtin.help",
          description = "Insert content from help tags",
          opts = {
            contains_code = false,
            max_lines = 128, -- Maximum amount of lines to of the help file to send (NOTE: Each vimdoc line is typically 10 tokens)
            provider = providers.help, -- telescope|fzf_lua|mini_pick|snacks
          },
        },
        ["image"] = {
          callback = "interactions.chat.slash_commands.builtin.image",
          description = "Insert an image",
          ---@param opts { adapter: MaxaAI.HTTPAdapter }
          ---@return boolean
          enabled = function(opts)
            if opts.adapter and opts.adapter.opts then
              return opts.adapter.opts.vision == true
            end
            return false
          end,
          opts = {
            dirs = {}, -- Directories to search for images
            filetypes = { "png", "jpg", "jpeg", "gif", "webp" }, -- Filetypes to search for
            provider = providers.images, -- telescope|snacks|default
          },
        },
        ["souls"] = {
          callback = "interactions.chat.slash_commands.builtin.souls",
          description = "Select an Agency Soul for this Chat",
        },
        ["now"] = {
          callback = "interactions.chat.slash_commands.builtin.now",
          description = "Insert the current date and time",
          opts = {
            contains_code = false,
          },
        },
        ["symbols"] = {
          callback = "interactions.chat.slash_commands.builtin.symbols",
          description = "Insert symbols for a selected file",
          opts = {
            contains_code = true,
            provider = providers.pickers, -- telescope|fzf_lua|mini_pick|snacks|default
          },
        },
        ["terminal"] = {
          callback = "interactions.chat.slash_commands.builtin.terminal",
          description = "Insert terminal output",
          opts = {
            contains_code = false,
          },
        },
        ["collapse"] = {
          callback = "maxa.session.slash_commands.collapse",
          description = "Fork 并关闭当前会话，摘要上次 collapse 之后的消息",
          opts = { contains_code = false },
        },
        ["compact_rescue"] = {
          callback = "maxa.session.slash_commands.compact_rescue",
          description = "交接式救援压缩 - 分段后由用户消息选择档位",
          opts = { contains_code = false },
        },
        ["compact_silent"] = {
          callback = "maxa.session.slash_commands.compact_silent",
          description = "交接式静默压缩 - 按配置选择档位并续接新会话",
          opts = { contains_code = false },
        },
        ["pick_session"] = {
          callback = "maxa.session.slash_commands.pick_session",
          description = "选择历史会话 - 弹出 Picker 选择后插入 save_id",
          opts = {
            contains_code = false,
          },
        },
        ["trace_start"] = {
          callback = "maxa.session.slash_commands.trace_start",
          description = "启动当前会话的 opt-in lineage trace 并回填可恢复对话",
          opts = {
            contains_code = false,
          },
        },
        ["pick_draft"] = {
          callback = "maxa.session.slash_commands.pick_draft",
          description = "选择草稿文件 - 弹出 Picker 选择后插入项目相对路径",
          opts = {
            contains_code = false,
          },
        },
        ["pick_spec"] = {
          callback = "maxa.session.slash_commands.pick_spec",
          description = "选择规格文件 - 弹出 Picker 选择后插入项目相对路径",
          opts = {
            contains_code = false,
          },
        },
        ["pick_article"] = {
          callback = "maxa.session.slash_commands.pick_article",
          description = "选择文章 - 弹出 Picker 选择后插入项目相对路径",
          opts = {
            contains_code = false,
          },
        },
        ["upload"] = {
          callback = "maxa.session.chat_upload.slash_command",
          description = "启动局域网上传页面，提交后插入项目相对路径",
          opts = {
            contains_code = false,
          },
        },
        ["tg_upload"] = {
          callback = "maxa.session.telegram_upload.slash_command",
          description = "通过 Telegram 回复一个文件或纯文字并插入当前 Chat",
          opts = {
            contains_code = false,
          },
        },
        ["latest_draft"] = {
          callback = "maxa.session.slash_commands.latest_draft",
          description = "插入最近修改草稿文件的项目相对路径",
          opts = {
            contains_code = false,
          },
        },
        ["fork"] = {
          callback = "maxa.session.slash_commands.fork",
          description = "复制当前会话为新的持久历史分支",
          opts = {
            contains_code = false,
          },
        },
        ["scratch"] = {
          callback = "maxa.session.slash_commands.scratch",
          description = "复制当前会话为临时草稿分支，不保存历史",
          opts = {
            contains_code = false,
          },
        },
        ["save"] = {
          callback = "maxa.session.slash_commands.save",
          description = "保存当前 scratch 临时会话为普通历史会话",
          opts = {
            contains_code = false,
          },
        },
        ["merge"] = {
          callback = "maxa.session.slash_commands.merge",
          description = "将 scratch 分支新增消息完整合回父会话并关闭 scratch",
          opts = {
            contains_code = false,
          },
        },
        ["summarize"] = {
          callback = "maxa.session.slash_commands.summarize",
          description = "从用户消息列表选择起点，摘要该消息到会话末尾",
          opts = {
            contains_code = false,
          },
        },
        ["rewind"] = {
          callback = "maxa.session.slash_commands.rewind",
          description = "回退到最近一次用户输入或 ask 答复，并恢复到编辑区",
          opts = {
            contains_code = false,
          },
        },
        ["rewind_to"] = {
          callback = "maxa.session.slash_commands.rewind_to",
          description = "选择用户输入或 ask 答复，回退并恢复到编辑区",
          opts = {
            contains_code = false,
          },
        },
        ["redo"] = {
          callback = "maxa.session.slash_commands.redo",
          description = "回退到最近一次用户输入或 ask 答复，并立即重新发送",
          opts = {
            contains_code = false,
          },
        },
        ["clear_protected_prefix"] = {
          callback = "maxa.session.slash_commands.clear_protected_prefix",
          description = "清理当前或指定历史会话的 protected prefix 计数",
          opts = {
            contains_code = false,
          },
        },
        ["save_fragment"] = {
          callback = "maxa.session.slash_commands.save_fragment",
          description = "保存当前 chat 选中消息为 .maxa/fragments JSON 片段",
          opts = {
            contains_code = false,
          },
        },
        ["insert_fragment"] = {
          callback = "maxa.session.slash_commands.insert_fragment",
          description = "选择 .maxa/fragments JSON 片段并追加到当前 chat",
          opts = {
            contains_code = false,
          },
        },
        ["repeat"] = {
          callback = "maxa.interactions.chat.tools.builtin.slash_commands.repeat",
          description = "重复发送当前消息 - 每次 LLM 回复后自动重发，Ctrl+C 中断",
          opts = {
            contains_code = false,
          },
        },
        ["load"] = {
          callback = "interactions.chat.slash_commands.builtin.load",
          description = "Load selected Abilities or content as tool messages before the user input",
          opts = { contains_code = false },
        },
        ["pick_ability"] = {
          callback = "maxa.interactions.chat.tools.builtin.slash_commands.pick_ability",
          description = "选择 Ability - 弹出 Picker 选择后插入 Ability 名",
          opts = {
            contains_code = false,
          },
        },
        opts = {},
      },
      keymaps = {
        session_status_panel = {
          modes = { n = "gD" },
          callback = function(chat)
            require("maxa.session.session_status_panel").open(chat)
          end,
          description = "[Session] Inspect session status",
        },
        notify_when_done = {
          modes = { n = "<leader>an" },
          callback = function(chat)
            require("maxa.session.notify_when_done").toggle(chat)
          end,
          description = "[Human Assist] Toggle notify when done",
        },
        soft_stop = {
          modes = { n = "<leader>ax" },
          callback = function(chat)
            require("maxa.lifecycle.chat_soft_stop").request(chat)
          end,
          description = "[Request] Soft stop after current operation",
        },
        context_limit_stop = {
          modes = { n = "<leader>aX" },
          callback = function(chat)
            require("maxa.lifecycle.chat_context_limit_stop").toggle(chat)
          end,
          description = "[Request] Stop when context usage reaches a limit",
        },
        options = {
          modes = { n = "?" },
          callback = "keymaps.options",
          description = "Options",
          hide = true,
        },
        completion = {
          modes = { i = "<C-_>" },
          index = 1,
          callback = "keymaps.completion",
          description = "[Chat] Completion menu",
        },
        send = {
          modes = {
            n = { "<CR>", "<C-s>" },
            i = "<C-s>",
            s = "<C-s>",
          },
          index = 2,
          callback = "keymaps.send",
          description = "[Request] Send response",
        },
        hide = {
          modes = { n = "q" },
          index = 3,
          callback = "keymaps.hide_or_close",
          description = "[Chat] Exit if idle; hide if running",
        },
        close = {
          modes = { n = "Q", i = "<C-q>" },
          index = 4,
          callback = "keymaps.close",
          description = "[Chat] Exit; confirm if running or unsaved scratch",
        },
        stop = {
          modes = { n = "<C-c>", i = "<C-c>" },
          index = 5,
          callback = "keymaps.stop",
          description = "[Request] Interrupt; keep chat",
        },
        clear = {
          modes = { n = "gx" },
          index = 6,
          callback = "keymaps.clear",
          description = "[Chat] Clear",
        },
        rewind_message = {
          modes = { n = "gr" },
          callback = "keymaps.rewind_message",
          description = "[Chat] Rewind to message under cursor",
        },
        codeblock = {
          modes = { n = "gc" },
          index = 7,
          callback = "keymaps.codeblock",
          description = "[Chat] Insert codeblock",
        },
        yank_code = {
          modes = { n = "gy" },
          index = 8,
          callback = "keymaps.yank_code",
          description = "[Chat] Yank code",
        },
        next_chat = {
          modes = { n = "}" },
          index = 11,
          callback = "keymaps.next_chat",
          description = "[Nav] Next chat",
        },
        previous_chat = {
          modes = { n = "{" },
          index = 12,
          callback = "keymaps.previous_chat",
          description = "[Nav] Previous chat",
        },
        next_header = {
          modes = { n = "]]" },
          index = 13,
          callback = "keymaps.next_header",
          description = "[Nav] Next header",
        },
        previous_header = {
          modes = { n = "[[" },
          index = 14,
          callback = "keymaps.previous_header",
          description = "[Nav] Previous header",
        },
        next_user_message = {
          modes = { n = "]u" },
          callback = "keymaps.next_user_message",
          description = "[Nav] Next user message",
        },
        previous_user_message = {
          modes = { n = "[u" },
          callback = "keymaps.previous_user_message",
          description = "[Nav] Previous user message",
        },
        change_adapter = {
          modes = { n = "ga" },
          index = 15,
          callback = "keymaps.change_adapter",
          description = "[Adapter] Change session LLM/media adapter",
        },
        fold_code = {
          modes = { n = "gf" },
          index = 15,
          callback = "keymaps.fold_code",
          description = "[Chat] Fold code",
        },
        inspect_message = {
          modes = { n = "gi" },
          callback = "keymaps.inspect_message",
          description = "[Chat] Inspect message input and output at cursor",
        },
        debug_messages = {
          modes = { n = "gd", x = "gd" },
          index = 16,
          callback = "keymaps.debug_messages",
          description = "[Chat] Edit selected messages or all when none is selected",
        },
        open_tool_window = {
          modes = { n = "gs" },
          callback = "keymaps.open_tool_window",
          description = "[Tool] Open SubAgent at cursor in a float",
        },
        goto_file_under_cursor = {
          modes = { n = "gR" },
          index = 19,
          callback = "keymaps.goto_file_under_cursor",
          description = "[Chat] Open file under cursor",
        },
      },
      opts = {
        blank_prompt = "", -- The prompt to use when the user doesn't provide a prompt
        completion_provider = providers.completion, -- blink|cmp|default
        debounce = 150, -- Time to debounce user input (milliseconds)
        -- Fallback for new main-agent Chats; a saved global listener default takes precedence.
        notify_when_done_default = false,

        register = "+", -- The register to use for yanking code
        wait_timeout = 2e6, -- Time to wait for user response before timing out (milliseconds)
        yank_jump_delay_ms = 400, -- Delay before jumping back from the yanked code (milliseconds )

        ---@type string|fun(path: string)
        goto_file_action = function(...)
          return require("maxa.utils.ui").tabnew_reuse(...)
        end,

        ---Runtime contract and selected Soul for the chat's system messages.
        ---@param ctx MaxaAI.SystemPrompt.Context
        ---@return {runtime: string, soul: string}
        system_prompt = function(ctx)
          local runtime = require("maxa.prompts.runtime")
          return {
            runtime = runtime.GenerateRuntimePrompt(ctx),
            soul = runtime.ResolveSoul(ctx),
          }
        end,
      },
    },
  },
  -- DISPLAY OPTIONS ----------------------------------------------------------
  display = {
    chat = {
      icons = {
        --chat_context = " ",
        chat_fold = " ",
        tool_pending = "  ",
        tool_in_progress = "  ",
        tool_failure = "  ",
        tool_success = "  ",
      },

      -- Window options for the chat buffer
      window = {
        buflisted = false, -- List the chat buffer in the buffer list?
        sticky = false, -- Chat buffer remains open when switching tabs

        layout = "vertical", -- float|vertical|horizontal|buffer
        full_height = true, -- for vertical layout
        position = nil, -- left|right|top|bottom (nil will default depending on vim.opt.splitright|vim.opt.splitbelow)

        width = 0.5, ---@return number|fun(): number
        height = 0.8, ---@return number|fun(): number
        border = "single",
        relative = "editor",

        -- Ensure that long paragraphs of markdown are wrapped
        opts = {
          breakindent = true,
          linebreak = true,
          wrap = true,
          number = false,
          relativenumber = false,
        },
      },

      -- Options for any windows that open within the chat buffer
      floating_window = {
        ---@return number|fun(): number
        width = function()
          return vim.o.columns - 5
        end,
        ---@return number|fun(): number
        height = function()
          return vim.o.lines - 2
        end,
        row = "center",
        col = "center",
        relative = "editor",
        opts = {},
      },

      -- Options for diff windows that open within the chat buffer
      diff_window = {
        ---@return number|fun(): number
        width = function()
          return math.min(120, vim.o.columns - 10)
        end,
        ---@return number|fun(): number
        height = function()
          return vim.o.lines - 4
        end,
        opts = {
          number = true,
        },
      },

      -- Chat buffer options --------------------------------------------------
      auto_scroll = true, -- Automatically scroll down and place the cursor at the end?
      intro_message = "~",

      separator = "─", -- The separator between the different messages in the chat buffer
      show_header_separator = true, -- Show header separators in the chat buffer? Set this to false if you're using an external markdown formatting plugin

      fold_reasoning = true, -- Fold the reasoning content in the chat buffer?
      show_reasoning = true, -- Show reasoning content in the chat buffer?

      show_tools_processing = false, -- Show the loading message when tools are being executed?
      show_token_count = true, -- Show the token count for each response?
      start_in_insert_mode = false, -- Open the chat buffer in insert mode?

      ---The function to display the token count
      ---@param tokens number
      ---@param adapter MaxaAI.HTTPAdapter
      token_count = function(tokens, adapter) -- The function to display the token count
        return " (" .. tokens .. " tokens)"
      end,
    },
    icons = {
      warning = " ",
    },
  },
  -- EXTENSIONS ------------------------------------------------------
  extensions = {
    history = {
      opts = {
        picker = "snacks",
        title_generation_opts = { default_role = "title" },
      },
    },
  },
  -- GENERAL OPTIONS ----------------------------------------------------------
  opts = {
    log_level = "ERROR", -- TRACE|DEBUG|ERROR|INFO
    language = "中文", -- The language used for LLM responses

    -- If this is false then any default prompt that is marked as containing code
    -- will not be sent to the LLM. Please note that whilst I have made every
    -- effort to ensure no code leakage, using this is at your own risk
    ---@type boolean|function
    ---@return boolean
    send_code = true,

    job_start_delay = 1500, -- Delay in milliseconds between cmd tools
    submit_delay = 2000, -- Delay in milliseconds before auto-submitting the chat buffer
  },
}

local M = {
  config = vim.deepcopy(defaults),
}
-- Entrypoint declarations are evaluated before setup(); retain only the early
-- Maxa options, then reapply them when the complete LazyVim opts arrive.
local early_maxa
function M.configure_early(maxa)
  early_maxa = vim.deepcopy(maxa or {})
  local declared = vim.deepcopy(early_maxa)
  if declared.lifecycle and declared.lifecycle.watchdog then
    declared.lifecycle.watchdog = require("maxa.lifecycle.chat_request_watchdog").normalize(declared.lifecycle.watchdog)
  end
  local previous_presets = M.config.maxa.presets
  local next_maxa = vim.tbl_deep_extend("force", vim.deepcopy(defaults.maxa), declared)
  next_maxa.lifecycle.watchdog = require("maxa.lifecycle.chat_request_watchdog").options(next_maxa.lifecycle.watchdog)
  for name in pairs(previous_presets) do
    previous_presets[name] = nil
  end
  for name, value in pairs(next_maxa.presets) do
    previous_presets[name] = value
  end
  next_maxa.presets = previous_presets
  M.config.maxa = require("maxa.presets").compose(next_maxa, early_maxa)
  local preset, err = require("maxa.presets").get_default("chat")
  assert(preset and not preset.inherit, err or "maxa.defaults.chat.adapter is required")
end
function M.runtime()
  return M.config.maxa
end

local function replace_config(next_config)
  for key in pairs(M.config) do
    M.config[key] = nil
  end
  for key, value in pairs(next_config) do
    M.config[key] = value
  end
end

---@return table
function M.snapshot()
  return vim.deepcopy(M.config)
end

---@param snapshot table
function M.restore(snapshot)
  if type(snapshot) ~= "table" then
    error("Maxa AI config restore requires a snapshot table")
  end
  local previous_presets = M.config.maxa.presets
  local restored = vim.deepcopy(snapshot)
  for name in pairs(previous_presets) do
    previous_presets[name] = nil
  end
  for name, value in pairs(restored.maxa.presets) do
    previous_presets[name] = value
  end
  restored.maxa.presets = previous_presets
  replace_config(restored)
  require("maxa.adapters.proxy").configure(M.config.maxa.proxy)
end

---@param keymaps table<string, table|boolean>
local function remove_disabled_keymaps(keymaps)
  local enabled = {}
  for name, keymap in pairs(keymaps) do
    if keymap ~= false then
      enabled[name] = keymap
    end
  end
  return enabled
end

---@param args? table
M.setup = function(args)
  args = vim.deepcopy(args or {})

  if args.constants then
    return vim.notify(
      "Your config table cannot have the field `constants`",
      vim.log.levels.ERROR,
      { title = "Maxa AI" }
    )
  end

  -- TODO: Remove in v19.0.0
  if args.strategies then
    args.interactions = vim.tbl_deep_extend("force", vim.deepcopy(defaults.interactions), args.strategies)
    args.strategies = nil
  end

  local declared_http = args.adapters and args.adapters.http or {}
  for name in pairs(declared_http) do
    assert(name == "opts", "HTTP adapter " .. tostring(name) .. " must be declared under maxa.providers")
  end
  assert(
    not (declared_http.opts and declared_http.opts.proxy ~= nil),
    "adapters.http.opts.proxy is obsolete; use maxa.proxy and provider.proxy"
  )
  assert(
    args.prompt_library == nil,
    "prompt_library is obsolete; use fixed project/global prompt directories and ABILITY.yaml prompts"
  )
  assert(
    not (args.display and args.display.action_palette),
    "display.action_palette is obsolete; use Chat slash commands"
  )
  local declared_maxa = vim.tbl_deep_extend("force", {}, early_maxa or {}, args.maxa or {})
  if declared_maxa.lifecycle and declared_maxa.lifecycle.watchdog then
    declared_maxa.lifecycle.watchdog = require("maxa.lifecycle.chat_request_watchdog").normalize(declared_maxa.lifecycle.watchdog)
  end
  local next_config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), args, { maxa = declared_maxa })
  next_config.maxa.lifecycle.watchdog = require("maxa.lifecycle.chat_request_watchdog").options(next_config.maxa.lifecycle.watchdog)
  require("maxa.presets").compose(next_config.maxa, declared_maxa)
  if declared_maxa.defaults or declared_maxa.presets then
    local preset, err = require("maxa.presets").get_default("chat", next_config.maxa)
    assert(preset and not preset.inherit, err or "maxa.defaults.chat.adapter is required")
  end
  require("maxa.adapters.proxy").configure(next_config.maxa.proxy)
  local generated = require("maxa.provider_config").configure(
    next_config.maxa.providers,
    next_config.maxa.presets,
    next_config.maxa.protocol_defaults
  )
  next_config.adapters.http = vim.tbl_extend("force", next_config.adapters.http, generated)
  -- The composition root validates its mandatory preset before setup; standalone
  -- consumers may configure the library without constructing a default Chat.

  next_config.interactions.chat.keymaps = remove_disabled_keymaps(next_config.interactions.chat.keymaps)

  -- Set the diagnostic namespace for Debug settings information
  next_config.INFO_NS = vim.api.nvim_create_namespace("MaxaAI-info")
  local previous_presets = M.config.maxa.presets
  for name in pairs(previous_presets) do
    previous_presets[name] = nil
  end
  for name, value in pairs(next_config.maxa.presets) do
    previous_presets[name] = value
  end
  next_config.maxa.presets = previous_presets
  replace_config(next_config)

  local diagnostic_config = {
    underline = false,
    virtual_text = {
      spacing = 2,
      severity = { min = vim.diagnostic.severity.INFO },
    },
    signs = false,
  }
  vim.diagnostic.config(diagnostic_config, M.config.INFO_NS)
end

---Determine if code can be sent to the LLM
---@return boolean
M.can_send_code = function()
  if type(M.config.opts.send_code) == "boolean" then
    return M.config.opts.send_code
  elseif type(M.config.opts.send_code) == "function" then
    return M.config.opts.send_code()
  end
  return false
end

return setmetatable(M, {
  __index = function(_, key)
    if key == "setup" then
      return M.setup
    end
    return rawget(M.config, key)
  end,
})
