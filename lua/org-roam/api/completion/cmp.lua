local types = require "cmp.types"
local utils = require "org-roam.api.completion.utils"

---@class org-roam.api.completion.CmpSource
---@field private roam OrgRoam
local Source = {}

---@param roam OrgRoam
---@return org-roam.api.completion.CmpSource
function Source:new(roam)
    return setmetatable({ roam = roam }, { __index = self })
end

---@return string
function Source.get_debug_name()
    return "org-roam"
end

---@return boolean
function Source:is_available()
    return vim.bo.filetype == "org"
end

---@return lsp.PositionEncodingKind
function Source:get_position_encoding_kind()
    return types.lsp.PositionEncodingKind.UTF8
end

---@param ctx cmp.Context
---@param callback fun(response: lsp.CompletionResponse|nil): nil
---@return OrgPromise<nil>
function Source:complete_with_context(ctx, callback)
    return self.roam.database:internal():next(function(db)
        if ctx.aborted then
            return nil
        end
        local start = utils.find_start(ctx.cursor_before_line)
        local stop = ctx.cursor.character + utils.find_stop(ctx.cursor_after_line)
        local base = ctx.cursor_before_line:sub(start)
        base = utils.clean_base(base)
        ---@type lsp.CompletionItem[]
        local items = utils.collect_completion_candidates(db, function(label, node)
            ---@type lsp.CompletionItem
            local item = {
                label = label,
                labelDetails = { description = node.id },
                textEdit = {
                    newText = ("[[id:%s][%s]]"):format(node.id, label),
                    range = {
                        ["start"] = { line = ctx.cursor.line, character = start },
                        ["end"] = { line = ctx.cursor.line, character = stop },
                    },
                },
                data = node,
            }
            return item
        end)
        return callback({
            isIncomplete = false,
            items = items,
            itemDefaults = {
                insertTextMode = types.lsp.InsertTextMode.AsIs,
                insertTextFormat = types.lsp.InsertTextFormat.PlainText,
            },
        })
    end)
end

---@param params cmp.SourceCompletionApiParams
---@param callback fun(response: lsp.CompletionResponse|nil): nil
---@return OrgPromise<nil>
function Source:complete(params, callback)
    return self:complete_with_context(params.context, callback)
end

---@param completion_item lsp.CompletionItem
---@param callback fun(completion_item: lsp.CompletionItem|nil): nil
---@return OrgPromise<nil>
function Source:resolve(completion_item, callback)
    return self.roam.database:internal():next(function(db)
        ---@type org-roam.core.file.Node
        local node = completion_item.data
        completion_item.documentation = utils.build_info(db, node)
        return callback(completion_item)
    end)
end

return Source
