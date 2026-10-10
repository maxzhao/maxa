---@class BaseResponse
---@field output_handler function|nil Async callback handler
---@field error fun(self: BaseResponse, message: string, details?: table): table Send error response
---@field result table Response data
local BaseResponse = {}
BaseResponse.__index = BaseResponse

function BaseResponse:new(output_handler)
    local instance = {
        output_handler = output_handler,
        result = {},
    }
    return setmetatable(instance, self)
end

function BaseResponse:send(result)
    local final_result = result or self.result
    if self.output_handler then
        -- Async with callback
        self.output_handler({
            result = final_result,
        })
    else
        -- Sync return
        return {
            result = final_result,
        }
    end
end

---@alias MCPResourceContent { uri: string, text?: string, blob?: string, mimeType: string }
---@alias MCPContent { type: "text"|"image"|"audio"|"resource", text?: string, data?: string, resource?: MCPResourceContent, mimeType?: string }

---@class ToolResponse : BaseResponse
---@field result { content: MCPContent[] }
---@field text fun(self: ToolResponse, text: string): ToolResponse Add text content
---@field image fun(self: ToolResponse, data: string, mime: string): ToolResponse Add image content
---@field audio fun(self: ToolResponse, data: string, mime: string): ToolResponse Add audio content
---@field resource fun(self: ToolResponse, resource: MCPResourceContent): ToolResponse Add resource content
---@field error fun(self: ToolResponse|BaseResponse, message: string, details?: table): table Send error response
---@field send fun(self: ToolResponse, result?: table): table Send response
local ToolResponse = setmetatable({}, { __index = BaseResponse })
ToolResponse.__index = ToolResponse

function ToolResponse:new(output_handler)
    local instance = BaseResponse:new(output_handler)
    instance.result = { content = {} }
    setmetatable(instance, self)
    return instance
end

function ToolResponse:text(text)
    if type(text) ~= "string" then
        text = vim.inspect(text)
    end
    table.insert(self.result.content, {
        type = "text",
        text = text,
    })
    return self
end

function ToolResponse:image(data, mime)
    table.insert(self.result.content, {
        type = "image",
        data = data,
        mimeType = mime,
    })
    return self
end

function ToolResponse:audio(data, mime)
    table.insert(self.result.content, {
        type = "audio",
        data = data,
        mimeType = mime or "audio/mp3",
    })
    return self
end

function ToolResponse:resource(resource)
    table.insert(self.result.content, {
        type = "resource",
        resource = resource,
    })
    return self
end

function ToolResponse:error(message, details)
    if type(message) ~= "string" then
        message = vim.inspect(message)
    end
    local result = {
        isError = true,
        content = {
            {
                type = "text",
                text = message,
            },
        },
    }

    -- Add details if provided
    if details then
        table.insert(result.content, {
            type = "text",
            text = "Details: " .. vim.inspect(details),
        })
    end

    -- Auto-send error response
    return self:send(result)
end

---@class ResourceResponse : BaseResponse
local ResourceResponse = setmetatable({}, { __index = BaseResponse })
ResourceResponse.__index = ResourceResponse

---@return ResourceResponse
function ResourceResponse:new(output_handler, uri, template)
    ---@class BaseResponse
    local instance = BaseResponse:new(output_handler)
    instance.uri = uri
    instance.template = template
    instance.result = { contents = {} }
    setmetatable(instance, self)
    return instance --[[@as ResourceResponse]]
end

function ResourceResponse:text(text, mime)
    if type(text) ~= "string" then
        text = vim.inspect(text)
    end
    table.insert(self.result.contents, {
        uri = self.uri,
        text = text,
        mimeType = mime or "text/plain",
    })
    return self
end

function ResourceResponse:blob(data, mime)
    table.insert(self.result.contents, {
        uri = self.uri,
        blob = data,
        mimeType = mime or "application/octet-stream",
    })
    return self
end

function ResourceResponse:image(data, mime)
    table.insert(self.result.contents, {
        uri = self.uri,
        blob = data,
        mimeType = mime or "image/png",
    })
    return self
end

function ResourceResponse:audio(data, mime)
    table.insert(self.result.contents, {
        uri = self.uri,
        blob = data,
        mimeType = mime or "audio/mp3",
    })
    return self
end

function ResourceResponse:error(message, details)
    if type(message) ~= "string" then
        message = vim.inspect(message)
    end
    -- For resources, we return error as a text resource
    self.result = {
        contents = {
            {
                uri = self.uri,
                text = message .. (details and ("\nDetails: " .. vim.inspect(details)) or ""),
                mimeType = "text/plain",
            },
        },
    }
    return self:send(self.result)
end

---@class PromptResponse : BaseResponse
local PromptResponse = setmetatable({}, { __index = BaseResponse })
PromptResponse.__index = PromptResponse

function PromptResponse:new(output_handler, name, description)
    ---@class BaseResponse
    local instance = BaseResponse:new(output_handler)
    instance.name = name
    instance.description = description
    instance.result = { messages = {} }
    instance.current_role = "user" -- Default role is user
    setmetatable(instance, self)
    return instance
end

-- Role state setters
function PromptResponse:user()
    self.current_role = "user"
    return self
end

function PromptResponse:llm()
    self.current_role = "assistant"
    return self
end

function PromptResponse:system()
    self.current_role = "system"
    return self
end

function PromptResponse:text(text)
    if type(text) ~= "string" then
        text = vim.inspect(text)
    end
    table.insert(self.result.messages, {
        role = self.current_role,
        content = {
            type = "text",
            text = text,
        },
    })
    return self
end

function PromptResponse:image(data, mime)
    table.insert(self.result.messages, {
        role = self.current_role,
        content = {
            type = "image",
            data = data,
            mimeType = mime or "image/png",
        },
    })
    return self
end

function PromptResponse:blob(data, mime)
    table.insert(self.result.messages, {
        role = self.current_role,
        content = {
            type = "blob",
            data = data,
            mimeType = mime or "application/octet-stream",
        },
    })
    return self
end

function PromptResponse:audio(data, mime)
    table.insert(self.result.messages, {
        role = self.current_role,
        content = {
            type = "audio",
            data = data,
            mimeType = mime or "audio/mp3",
        },
    })
    return self
end

function PromptResponse:resource(resource)
    table.insert(self.result.messages, {
        role = self.current_role,
        content = {
            type = "resource",
            resource = resource,
        },
    })
    return self
end

function PromptResponse:error(message, details)
    if type(message) ~= "string" then
        message = vim.inspect(message)
    end
    -- Switch to system role for error, then send
    self:user():text(message .. (details and ("\nDetails: " .. vim.inspect(details)) or ""))
    return self:send(self.result)
end

return {
    ToolResponse = ToolResponse,
    ResourceResponse = ResourceResponse,
    PromptResponse = PromptResponse,
}
