local Base = require("maxa.mcphub.ui.capabilities.base")
local NuiLine = require("maxa.mcphub.utils.nuiline")
local State = require("maxa.mcphub.state")
local Text = require("maxa.mcphub.utils.text")
local highlights = require("maxa.mcphub.utils.highlights").groups
local Handlers = require("maxa.mcphub.utils.handlers")
local log = require("maxa.mcphub.utils.log")

---@class PromptHandler : CapabilityHandler
local PromptHandler = setmetatable({}, {
    __index = Base,
})
PromptHandler.__index = PromptHandler
PromptHandler.type = "prompt"
PromptHandler.arguments = {}

function PromptHandler:new(server_name, capability_info, view)
    local instance = Base:new(server_name, capability_info, view)
    setmetatable(instance, PromptHandler)
    instance.state = vim.tbl_extend("force", instance.state, {
        params = {
            values = {},
            errors = {},
        },
    })
    return instance
end

function PromptHandler:format_param_type(param)
    local handler = Handlers.TypeHandlers[param.type]
    if not handler then
        return param.type
    end
    return handler.format(param)
end

function PromptHandler:validate_all_params()
    if not self.arguments then
        return true, nil, {}
    end

    local errors = {}
    for _, argument in ipairs(self.arguments) do
        local value = self.state.params.values[argument.name]

        -- Check required fields
        if argument.required and (not value or value == "") then
            errors[argument.name] = "Required argument"
        -- Only validate non-empty values
        elseif value and value ~= "" then
            if type(value) ~= "string" then
                errors[argument.name] = "Invalid type, expected string"
            end
        end
        -- Skip validation for empty optional fields
    end

    if next(errors) then
        return false, "Some required arguments are missing or invalid", errors
    end

    return true, nil, {}
end

-- Action handling
-- Common callback logic for input handling
function PromptHandler:handle_param_update(param_name, input)
    -- Clear previous error
    self.state.params.errors[param_name] = nil
    local param = {}
    for _, v in ipairs(self.arguments) do
        if v.name == param_name then
            param = v
        end
    end

    -- Handle empty input
    if input == "" then
        -- Check if field is required
        local is_required = param.required == true
        if is_required then
            self.state.params.errors[param_name] = "Required parameter"
        else
            -- For optional fields, clear value and error
            self.state.params.values[param_name] = nil
        end
    else
        self.state.params.values[param_name] = input
    end
    self.view:draw()
end

function PromptHandler:handle_input_action(param_name)
    self:handle_input(
        string.format("%s (%s): ", param_name, "string"),
        self.state.params.values[param_name],
        function(input)
            self:handle_param_update(param_name, input)
        end
    )
end

function PromptHandler:handle_text_box(line)
    local type, context = self:get_line_info(line)
    if type == "input" then
        local param_name = context
        self:open_text_box(
            string.format("%s (%s)", param_name, "string"),
            self.state.params.values[param_name] or "",
            function(input)
                self:handle_param_update(param_name, input)
            end
        )
    end
end

function PromptHandler:handle_action(line)
    local type, context = self:get_line_info(line)
    if not type then
        return
    end

    if type == "input" then
        self:handle_input_action(context)
    elseif type == "submit" then
        self:execute()
    end
end

-- Execution
function PromptHandler:execute()
    -- Check if already executing
    if self.state.is_executing then
        vim.notify("Getting prompt...", vim.log.levels.WARN)
        return
    end

    -- Validate all parameters first
    local ok, err, errors = self:validate_all_params()
    self.state.params.errors = errors
    self.state.error = err
    if not ok then
        self.view:draw()
        return
    end

    -- Set executing state
    self.state.is_executing = true
    self.state.error = nil
    self.view:draw()

    -- Convert all parameters to their proper types
    local converted_values = {}
    for name, value in pairs(self.state.params.values) do
        converted_values[name] = value
    end

    log.debug(string.format("Getting prompt %s with parameters: %s", self.def.name, vim.inspect(converted_values)))
    -- Execute tool
    if State.hub_instance then
        State.hub_instance:get_prompt(self.server_name, self.def.name, converted_values, {
            caller = {
                type = "hubui",
                hubui = State.ui_instance,
            },
            parse_response = true,
            callback = function(response, error)
                self:handle_response(response, error)
                self.view:draw()
            end,
        })
    end
end

function PromptHandler:render_submit()
    local submit_content
    if self.state.is_executing then
        submit_content = NuiLine():append("[ " .. Text.icons.event .. " Processing... ]", highlights.muted)
    else
        submit_content = NuiLine():append("[ " .. Text.icons.gear .. " Submit ]", highlights.success_fill)
    end
    return submit_content
end

-- Rendering
function PromptHandler:render_param_form(line_offset)
    -- Clear previous line tracking
    self:clear_line_tracking()

    local lines = {}

    local arguments = self.def.arguments
    local is_function = type(arguments) == "function"
    -- Parameters section
    vim.list_extend(
        lines,
        self:render_section_start((is_function and "(" .. Text.icons.event .. " Dynamic) " or "") .. "Input Params")
    )
    arguments = self:get_arguments(arguments)
    self.arguments = arguments
    if not arguments or not next(arguments) then
        -- No parameters case
        local placeholder = NuiLine():append("No arguments required ", highlights.muted)

        -- Submit button
        local submit_content = self:render_submit()
        vim.list_extend(
            lines,
            self:render_section_content({ placeholder, NuiLine():append(" ", highlights.muted), submit_content }, 2)
        )

        -- Track submit line
        self:track_line(line_offset + #lines, "submit")
    else
        -- Render each parameter
        for _, argument in ipairs(arguments) do
            -- Parameter name and type
            local name_line = NuiLine()
                :append(argument.required and "* " or "  ", highlights.error)
                :append(argument.name, highlights.success)
                :append(string.format(" (%s)", "string"), highlights.muted)
            vim.list_extend(lines, self:render_section_content({ name_line }, 2))

            -- Description if any
            if argument.description then
                for _, desc_line in ipairs(Text.multiline(argument.description, highlights.muted)) do
                    vim.list_extend(lines, self:render_section_content({ desc_line }, 4))
                end
            end

            -- Input field
            local value = self.state.params.values[argument.name]
            local input_line = NuiLine():append("> ", highlights.success):append(value or "", highlights.info)
            vim.list_extend(lines, self:render_section_content({ input_line }, 2))

            -- Track input line
            self:track_line(line_offset + #lines, "input", argument.name)

            -- Error if any
            if self.state.params.errors[argument.name] then
                local error_lines = Text.multiline(self.state.params.errors[argument.name], highlights.error)
                vim.list_extend(lines, self:render_section_content(error_lines, 2))
            end

            table.insert(lines, Text.pad_line(NuiLine():append("│", highlights.muted)))
        end

        -- Submit button
        local submit_content = self:render_submit()
        vim.list_extend(lines, self:render_section_content({ submit_content }, 2))

        -- Track submit line
        self:track_line(line_offset + #lines, "submit")
    end

    -- Error message
    if self.state.error then
        local error_lines = Text.multiline(self.state.error, highlights.error)
        vim.list_extend(lines, self:render_section_content(error_lines, 2))
    end
    vim.list_extend(lines, self:render_section_end())
    return lines
end

function PromptHandler:get_arguments(arguments)
    local base = {}
    arguments = self.def.arguments
    if not arguments or (type(arguments) ~= "function" and not next(arguments or {})) then
        arguments = base
    end
    local parsedArguments = arguments
    if type(arguments) == "function" then
        local ok, schema = pcall(arguments, self.def)
        if not ok then
            local err = "Error in arguments function: " .. tostring(schema)
            self.state.error = err
            log.error(err)
            parsedArguments = base
        else
            parsedArguments = schema or base
        end
    end
    local function validate_arguments(args, name)
        for _, arg in ipairs(args) do
            if type(arg) ~= "table" then
                return {
                    ok = false,
                    error = "Argument should be a table in " .. name .. " prompt",
                }
            end
            if not arg.name or arg.name == "" then
                return {
                    ok = false,
                    error = "Argument name is required in " .. name .. " prompt",
                }
            end
        end
        return { ok = true }
    end
    local res = validate_arguments(parsedArguments, self.def.name)
    if not res.ok then
        local err = "Error in arguments function: " .. tostring(res.error)
        self.state.error = err
        log.error(err)
        return base
    end
    return parsedArguments
end

function PromptHandler:render(line_offset)
    line_offset = line_offset or 0
    local lines = {}
    vim.list_extend(lines, vim.tbl_map(Text.pad_line, Text.multiline(self:get_description(), highlights.muted)))
    table.insert(lines, Text.pad_line(NuiLine()))
    -- Parameter form
    vim.list_extend(lines, self:render_param_form(line_offset + #lines))
    table.insert(lines, Text.pad_line(NuiLine())) -- Empty line

    if not self.state.result then
        return lines
    end

    vim.list_extend(lines, self:render_section_start("Result"))

    -- Handle text content
    if self.state.result then
        ---@diagnostic disable-next-line: undefined-field
        local messages = self.state.result.messages or {}
        for _, message in ipairs(messages) do
            vim.list_extend(lines, self:render_section_content({ " " }))
            local role = message.role
            local output = message.output
            vim.list_extend(lines, self:render_section_content({ NuiLine():append(role, highlights.success) }))
            vim.list_extend(lines, self:render_output(output))
        end
    end

    vim.list_extend(lines, self:render_section_end())
    return lines
end

return PromptHandler
