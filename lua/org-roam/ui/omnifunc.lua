---@class MinimalContext
---@field public cursor vim.Position
---@field public cursor_line string
---@field public cursor_before_line string
---@field public cursor_after_line string

---@return MinimalContext
local function create_context()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1]
    local col = cursor[2] + 1
    local cursor_line = vim.api.nvim_get_current_line()
    local ctx = {
        cursor = { row = row, col = col },
        cursor_line = cursor_line,
        cursor_before_line = cursor_line:sub(1, col - 1),
        cursor_after_line = cursor_line:sub(col),
    }
    return ctx
end

local RE_UNMATCHED_OPEN_BRACKET = vim.regex("\\[\\[\\%(.*\\]\\]\\)\\@!")
local RE_UNMATCHED_CLOSING_BRACKET = vim.regex("\\%(\\[\\[.*\\)\\@<!\\]\\]")
local RE_LAST_SPACE = vim.regex(".*\\zs\\s")
local RE_FIRST_SPACE = vim.regex("\\s")

---@param cursor_before_line string
---@return integer
local function find_start(cursor_before_line)
    local start, stop = RE_UNMATCHED_OPEN_BRACKET:match_str(cursor_before_line)
    if start then
        return start
    end
    start, stop = RE_LAST_SPACE:match_str(cursor_before_line)
    if stop then
        return stop
    end
    return 0
end

---@param cursor_after_line string
---@return integer
local function find_stop(cursor_after_line)
    local start, stop = RE_UNMATCHED_CLOSING_BRACKET:match_str(cursor_after_line)
    if stop then
        return stop
    end
    start, stop = RE_FIRST_SPACE:match_str(cursor_after_line)
    if start then
        return start
    end
    return 0
end

---Check if the cursor is right before `]]`.
---
---We need this so that completion doesn't insert superfluous brackets.
---
---@param cursor_after_line string
---@return boolean
local function double_brackets_after_cursor(cursor_after_line)
    return vim.startswith(cursor_after_line, "]]")
end

---Remove leading brackets in the completion base
---
---If the base looks like `'[[label'`, this returns `'label', true`.
---If the base looks like `'[[url][label'`, this returns `'label', true`.
---Otherwise, this returns `base, false`.
---
---@param base string
---@return string, boolean
local function clean_base(base)
    if not vim.startswith(base, "[[") then
        return base, false
    end
    local start, stop = base:find("][", 1, true)
    if start then
        return base:sub(stop + 1), true
    end
    return base:sub(3), true
end

---@param node org-roam.core.file.Node
---@return string
local function build_info_headline(node)
    local width = 80 -- TODO make this configurable, e.g. via `org_tags_column`
    local stars = node.level > 0 and ("*"):rep(node.level) or "#+TITLE:"
    local tags = ""
    local padding = ""
    if #node.tags > 0 then
        tags = " :" .. table.concat(node.tags, ":") .. ":"
        padding = (" "):rep(width - stars:len() - node.title:len() - tags:len() - 1)
    end
    return ("%s %s%s%s"):format(stars, node.title, padding, tags)
end

---@param db org-roam.core.Database
---@param node org-roam.core.file.Node
---@return string
local function build_info(db, node)
    ---@param node? org-roam.core.file.Node
    ---@return string
    ---@diagnostic disable-next-line:redefined-local
    local function get_title(node)
        return node and node.title or "<unknown node>"
    end
    local lines = {
        build_info_headline(node),
        "",
        "- origin ::",
        "- links to ::",
        "- linked by ::",
    }
    if node.origin then
        ---@type org-roam.core.file.Node?
        local origin = db:get(node.origin)
        lines[3] = ("%s %s"):format(lines[3], get_title(origin))
    end
    if not vim.tbl_isempty(node.linked) then
        local links = {}
        for id, _ in pairs(node.linked) do
            ---@type org-roam.core.file.Node?
            local target = db:get(id)
            links[#links + 1] = get_title(target)
        end
        lines[4] = ("%s %s"):format(lines[4], table.concat(links, ", "))
    end
    local backlinks = db:get_backlinks(node.id)
    if not vim.tbl_isempty(backlinks) then
        local links = {}
        for id, _ in pairs(backlinks) do
            ---@type org-roam.core.file.Node?
            local source = db:get(id)
            links[#links + 1] = get_title(source)
        end
        lines[5] = ("%s %s"):format(lines[5], table.concat(links, ", "))
    end
    lines[#lines + 1] = " "
    return table.concat(lines, "\n")
end

---@param db org-roam.core.Database
---@param node org-roam.core.file.Node
---@param matched string
---@param skip_closing_brackets boolean
---@return vim.CompletedItem
local function make_compl(db, node, matched, skip_closing_brackets)
    return {
        word = ("[[id:%s][%s%s"):format(node.id, matched, skip_closing_brackets and "" or "]]"),
        abbr = matched,
        menu = node.level > 0 and ("*"):rep(node.level) or "file",
        info = build_info(db, node),
    }
end

---@generic T
---@param db org-roam.core.Database
---@param transform fun(label: string, node: org-roam.core.file.Node): `T`
---@return T[]
local function collect_completion_candidates(db, transform)
    local items = {}
    for _, id in ipairs(db:ids()) do
        ---@type org-roam.core.file.Node
        local node = db:get(id)
        items[#items + 1] = transform(node.title, node)
        for _, alias in ipairs(node.aliases) do
            items[#items + 1] = transform(alias, node)
        end
    end
    return items
end

---@alias ComplItem string|vim.CompletedItem

---@param roam OrgRoam
---@param ctx MinimalContext
---@param base string
---@return ComplItem[]|{words:ComplItem[], refresh:"always"}
local function collect_completions(roam, ctx, base)
    local db_promise = roam.database:internal():next(function(db)
        if vim.fn.complete_check() ~= 0 then
            return nil
        end
        local bracketed
        base, bracketed = clean_base(base)
        local skip_closing_brackets = bracketed and double_brackets_after_cursor(ctx.cursor_after_line)
        ---@type {label: string, node: org-roam.core.file.Node}[]
        local candidates = collect_completion_candidates(db, function(label, node)
            return { label = label, node = node }
        end)
        if base ~= "" then
            ---@type {label: string, node: org-roam.core.file.Node}[]
            candidates = vim.fn.matchfuzzy(candidates, base, { matchseq = true, key = "label" })
        end
        for _, candidate in ipairs(candidates) do
            local compl = make_compl(db, candidate.node, candidate.label, skip_closing_brackets)
            local status = vim.fn.complete_add(compl)
            if status == 0 then -- out of memory
                return nil
            end
        end
        return nil
    end)
    local success, error = pcall(db_promise.wait, db_promise)
    if not success then
        vim.notify(vim.inspect(error), vim.log.levels.ERROR, {})
    end
    return {}
end

---@param findstart 0|1
---@param base string
---@return integer|ComplItem[]|{words:ComplItem[], refresh:"always"}
local function omnifunc(findstart, base)
    local ctx = create_context()
    if findstart ~= 0 then
        return find_start(ctx.cursor_before_line)
    else
        local roam = require "org-roam"
        return { words = collect_completions(roam, ctx, base), refresh = "always" }
    end
end

local has_cmp, cmp = pcall(require, "cmp")
if not has_cmp then
    return omnifunc
end

local types = require "cmp.types"

---@class org-roam.ui.omnifunc.Source: cmp.Source
local Source = {}

---@return org-roam.ui.omnifunc.Source
function Source.new()
    local self = setmetatable({}, { __index = Source })
    return self
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
    return "utf-8"
end

-- ---@return string
-- function Source:get_keyword_pattern()
--     return "\\[\\["
-- end

---@param params cmp.SourceCompletionApiParams
---@param callback fun(response: lsp.CompletionResponse|nil)
---@return nil
function Source:complete(params, callback)
    local roam = require "org-roam"
    local ctx = params.context
    roam.database:internal():next(function(db)
        if params.context.aborted then
            return nil
        end
        local start = find_start(ctx.cursor_before_line)
        local stop = ctx.cursor.character + find_stop(ctx.cursor_after_line)
        local base = ctx.cursor_before_line:sub(start)
        base = clean_base(base)
        ---@type lsp.CompletionItem[]
        local items = collect_completion_candidates(db, function(label, node)
            ---@type lsp.CompletionItem
            local item = {
                label = label,
                labelDetails = { description = node.id },
                textEdit = {
                    newText = ("[[id:%s][%s]]"):format(node.id, label),
                    range = {
                        start = { line = ctx.cursor.line, character = start },
                        ["end"] = { line = ctx.cursor.line, character = stop },
                    },
                },
                data = node,
            }
            return item
        end)
        callback({
            isIncomplete = false,
            items = items,
            itemDefaults = {
                insertTextMode = types.lsp.InsertTextMode.AsIs,
                insertTextFormat = types.lsp.InsertTextFormat.PlainText,
            },
        })
        return nil
    end)
end

---@param completion_item lsp.CompletionItem
---@param callback fun(completion_item: lsp.CompletionItem|nil)
---@return nil
function Source:resolve(completion_item, callback)
    local roam = require "org-roam"
    roam.database:internal():next(function(db)
        ---@type org-roam.core.file.Node
        local node = completion_item.data
        completion_item.documentation = build_info(db, node)
        callback(completion_item)
        return nil
    end)
end

cmp.register_source("org-roam", Source.new())

return omnifunc
