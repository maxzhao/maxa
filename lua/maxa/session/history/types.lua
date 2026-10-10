---@meta MaxaAI.Extension

---@alias MaxaAI.History.Pickers "telescope" | "snacks" | "fzf-lua" |  "default"

---@class MaxaAI.History.GenOpts
---@field adapter? string? The adapter to use for generation
---@field model? string? The model of the adapter to use for generation
---@field refresh_every_n_prompts? number Number of user prompts after which to refresh the title (0 to disable)
---@field max_refreshes? number Maximum number of times to refresh the title (default: 3)
---@field format_title? fun(original_title: string):string a function that applies a custom transformation to the title.

---@class MaxaAI.History.Opts
---@field default_buf_title? string A name for the chat buffer that tells that this is an auto saving chat
---@field auto_generate_title? boolean  Generate title for the chat
---@field title_generation_opts? MaxaAI.History.GenOpts Options for title generation
---@field continue_last_chat? boolean On exiting and entering neovim, loads the last chat on opening chat
---@field delete_on_clearing_chat? boolean When chat is cleared with `gx` delete the chat from history
---@field keymap? string | table Keymap to open saved chats from the chat buffer
---@field keymap_description? string Description for the history keymap (for which-key integration)
---@field picker? MaxaAI.History.Pickers Picker to use (telescope, etc.)
---@field enable_logging? boolean Enable logging for history extension
---@field auto_save? boolean Automatically save the chat whenever it is updated
---@field save_chat_keymap? string | table Keymap to save the current chat
---@field save_chat_keymap_description? string Description for the save chat keymap (for which-key integration)
---@field expiration_days? number Number of days after which chats are automatically deleted (0 to disable)
---@field picker_keymaps? {rename?: table, delete?: table, duplicate?: table, stats?: table}
---@field chat_filter? fun(chat_data: MaxaAI.History.ChatIndexData): boolean Filter function for browsing chats

---@class MaxaAI.History.ChatMessage
---@field role string
---@field content string
---@field tool_calls table
---@field opts? {visible?: boolean, tag?: string}

---@class MaxaAI.History.ChatData
---@field save_id string
---@field title? string
---@field messages MaxaAI.History.ChatMessage[]
---@field updated_at number
---@field settings table
---@field adapter string
---@field context_items? table
---@field schemas? table
---@field in_use? table
---@field name? string
---@field cycle number
---@field title_refresh_count? number
---@field cwd string Current working directory when chat was saved
---@field project_root string Project root directory when chat was saved

---@class MaxaAI.History.ChatIndexData
---@field title string
---@field updated_at number
---@field save_id string
---@field model string
---@field adapter string
---@field message_count number
---@field token_estimate number
---@field cwd string Current working directory when chat was saved
---@field project_root string Project root directory when chat was saved

---@class MaxaAI.History.UIHandlers
---@field on_preview fun(chat_data: MaxaAI.History.EntryItem): string[]
---@field on_delete fun(chat_data: MaxaAI.History.EntryItem|MaxaAI.History.EntryItem[]): nil
---@field on_select fun(chat_data: MaxaAI.History.EntryItem): nil
---@field on_open fun(): nil
---@field on_rename fun(chat_data: MaxaAI.History.EntryItem): nil
---@field on_duplicate? fun(chat_data: MaxaAI.History.EntryItem): nil
---@field on_stats? fun(chat_data: MaxaAI.History.EntryItem): nil

---@class MaxaAI.History.EntryItem : MaxaAI.History.ChatIndexData
---@field name string Display name for the item

---@class MaxaAI.History.BufferInfo
---@field bufnr number
---@field name string
---@field filename string
---@field is_visible boolean
---@field is_modified boolean
---@field is_loaded boolean
---@field lastused number
---@field windows number[]
---@field winnr number
---@field cursor_pos? number[]
---@field line_count number

---@class MaxaAI.History.EditorInfo
---@field last_active MaxaAI.History.BufferInfo|nil
---@field buffers MaxaAI.History.BufferInfo[]
