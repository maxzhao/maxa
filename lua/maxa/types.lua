---@meta Tree-sitter

---@class vim.treesitter.LanguageTree
---@field parse function

---@class TSNode
---@field start_pos function
---@field end_pos function
---@field type function
---@field parent function

---@class TSQuery

---@meta MaxaAI

---@alias MaxaAI.Chat.Messages MaxaAI.Chat.Message[]

---@class MaxaAI.Chat.Message
---@field role string Role of the author (e.g. "user", "llm", "system", "tool")
---@field content string The raw Markdown/text content of the message (optional for tool-only entries)
---@field tools? table Optional tool data
---@field tools.call_id? string Correlation ID linking a tool result to its request
---@field tools.calls? MaxaAI.Chat.ToolCall[] Array of tool calls
---@field tools.id? string Adapter output-item ID when distinct from call_id
---@field opts? table Optional metadata used by the UI and processing
---@field opts.index? number If set, the message was inserted at this index
---@field opts.visible? boolean Whether the message should be shown in the chat UI
---@field _meta? table Internal static metadata (e.g. { sent = true })
---@field _meta.id? number Unique identifier for the message (generated via hash)
---@field _meta.cycle? number The chat turn cycle when this message was added
---@field _meta.index? number The index of the chat message in the messages stack
---@field _meta.tag? string A tag to identify special messages (e.g. "system_prompt_from_config", "tool")
---@field context? { id?: string, path?: string, mimetype?: string, url?: string } Optional context object
---@field reasoning? MaxaAI.Chat.Reasoning Optional reasoning object returned by some adapters
---@field type? string Optional message type used by the UI (e.g. "llm_message", "tool_message", "reasoning_message")
---@field _raw? any Any adapter-specific raw payload stored with the message
---@field created_at? number Unix timestamp (optional, helpful for sorting/logging)
---@field tokens? number Optional token count associated with this message

---@class MaxaAI.Chat.ToolFunctionCall
---@field name string Name of the function/tool (e.g. "run", "search tool")
---@field arguments string|table Raw JSON string or parsed table of arguments

---@class MaxaAI.Chat.ToolCall
---@field id string Adapter output-item/tool-use ID
---@field call_id? string Correlation ID for the tool result; prefer this over id when matching results
---@field type string Typically "function" (adapter/tool-specific)
---@field _index? number Position index when returned by adapters
---@field ["function"]? MaxaAI.Chat.ToolFunctionCall Function descriptor (adapter key name is "function")
---@field result? any Optional execution result or intermediate payload

---@class MaxaAI.Chat.Reasoning
---@field content string The LLM's chain-of-thought / internal reasoning (often markdown)
---@field meta? table Optional structured reasoning metadata

---@class MaxaAI.SlashCommandAnchor
---@field row integer 0-based buffer row
---@field col integer 0-based byte column

---@class MaxaAI.SlashCommandContext
---@field bufnr? integer
---@field cursor? table
---@field slash_anchor? MaxaAI.SlashCommandAnchor
---@field slash_anchor_extmark? integer
---@field slash_token? string
---@field slash_range? { start: MaxaAI.SlashCommandAnchor, end: MaxaAI.SlashCommandAnchor }
---@field pre_slash_command_input? string
---@field pre_slash_command_name? string

---@class MaxaAI.SlashCommand
---@field Chat MaxaAI.Chat The chat buffer
---@field config table The config of the slash command
---@field context MaxaAI.SlashCommandContext The context of the chat buffer from the completion menu
---@field opts table The options for the slash command
---@field output fun(selected: table, opts: table): nil The function to call when a selection is made

---@class MaxaAI.SlashCommandArgs
---@field Chat MaxaAI.Chat The chat buffer
---@field config table The config of the slash command
---@field context MaxaAI.SlashCommandContext The context of the chat buffer from the completion menu
---@field opts table The options for the slash command

---@class MaxaAI.Tools.Tool
---@field name string The name of the tool
---@field cmds table The commands to execute
---@field function_call table The function call from the LLM
---@field schema table The schema that the LLM must use in its response to execute a tool
---@field system_prompt string | fun(schema: table): string The system prompt to the LLM explaining the tool and the schema
---@field opts? table The options for the tool
---@field env? fun(schema: table): table|nil Any environment variables that can be used in the *_cmd fields. Receives the parsed schema from the LLM
---@field handlers table Functions which handle the execution of a tool
---@field handlers.setup? fun(self: MaxaAI.Tools.Tool, tools: MaxaAI.Tools): any Function used to setup the tool. Called before any commands
---@field handlers.on_exit? fun(self: MaxaAI.Tools.Tool, tools: MaxaAI.Tools): any Function to call at the end of a group of commands or functions
---@field output? table Functions which handle the output after every execution of a tool
---@field output.error? fun(self: MaxaAI.Tools.Tool, tools: MaxaAI.Tools, cmd: table, stderr: table, stdout?: table): any The function to call if an error occurs
---@field output.success? fun(self: MaxaAI.Tools.Tool, tools: MaxaAI.Tools, cmd: table, stdout: table): any Function to call if the tool is successful
---@field output.cancelled? fun(self: MaxaAI.Tools.Tool, tools: MaxaAI.Tools, cmd: table): any Function to call if the tool is cancelled
---@field args table The arguments sent over by the LLM when making the request
---@field tool table The tool configuration from the config file

---@class MaxaAI.SlashCommand.Provider
---@field output function The function to call when a selection is made
---@field provider table The path to the provider
---@field title string The title of the provider's window
---@field SlashCommand MaxaAI.SlashCommand

---@class MaxaAI.SlashCommand.ProviderArgs
---@field output function The function to call when a selection is made
---@field SlashCommand MaxaAI.SlashCommand
---@field title string The title of the provider's window

---@class MaxaAI.Actions.Provider
---@field validate table Validate an item
---@field resolve table Resolve an item into an action
---@field context table Store all arguments in this table

---@class MaxaAI.Actions.ProvidersArgs Arguments that can be injected into the chat
---@field validate table Validate an item
---@field resolve table Resolve an item into an action
---@field context table The buffer context

---@class MaxaAI.BufferContext
---@field bufnr number The buffer number
---@field buftype string The buffer type
---@field cursor_pos number[] The cursor position as [line, col]
---@field cwd string Exact working directory captured when the buffer context was created
---@field project_root? string Closest project root containing `.maxa`, `.git`, `.svn`, or `.hg`
---@field end_col number The end column of the selection
---@field end_line number The end line of the selection
---@field filetype string The filetype of the buffer
---@field filename string The name of the file
---@field is_visual boolean Whether the selection is visual
---@field is_normal boolean Whether the selection is normal
---@field lines string[] The lines in the buffer
---@field line_count number The number of lines in the buffer
---@field mode string The current mode
---@field start_line number The start line of the selection
---@field start_col number The start column of the selection
---@field winnr number The window number
