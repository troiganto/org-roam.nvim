local utils = require "org-roam.api.completion.utils"

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

---Check if the cursor is right before `]]`.
---
---We need this so that completion doesn't insert superfluous brackets.
---
---@param cursor_after_line string
---@return boolean
local function double_brackets_after_cursor(cursor_after_line)
    return vim.startswith(cursor_after_line, "]]")
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
        info = utils.build_info(db, node),
    }
end

---@alias ComplItem string|vim.CompletedItem

---@param roam OrgRoam
---@param ctx MinimalContext
---@param base string
---@return ComplItem[]|{words: ComplItem[], refresh: "always"}
local function collect_completions(roam, ctx, base)
    local db_promise = roam.database:internal():next(function(db)
        if vim.fn.complete_check() ~= 0 then
            return nil
        end
        local bracketed
        base, bracketed = utils.clean_base(base)
        local skip_closing_brackets = bracketed and double_brackets_after_cursor(ctx.cursor_after_line)
        ---@type {label: string, node: org-roam.core.file.Node}[]
        local candidates = utils.collect_completion_candidates(db, function(label, node)
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
---@return integer|ComplItem[]|{words: ComplItem[], refresh: "always"}
local function omnifunc(findstart, base)
    local ctx = create_context()
    if findstart ~= 0 then
        return utils.find_start(ctx.cursor_before_line)
    else
        local roam = require "org-roam"
        return { words = collect_completions(roam, ctx, base), refresh = "always" }
    end
end

return omnifunc
