local Capabilities = {}

function Capabilities.create_handler(type, server_name, capability, view)
    local handlers = {
        tool = require("maxa.mcphub.ui.capabilities.tool"),
        resource = require("maxa.mcphub.ui.capabilities.resource"),
        resourceTemplate = require("maxa.mcphub.ui.capabilities.resourceTemplate"),
        prompt = require("maxa.mcphub.ui.capabilities.prompt"),
        preview = require("maxa.mcphub.ui.capabilities.preview"),
        createServer = require("maxa.mcphub.ui.capabilities.createServer"),
    }

    local handler = handlers[type]
    if not handler then
        vim.notify("Unknown capability type: " .. tostring(type), vim.log.levels.ERROR)
        return nil
    end

    return handler:new(server_name, capability, view)
end

return Capabilities
