---@alias ComplKind "v"|"f"|"m"|"t"|"d"

---@class Compl
---@field word string
---@field abbr string?
---@field menu string?
---@field info string?
---@field kind ComplKind?
---@field icase boolean?
---@field equal boolean?
---@field dup boolean?
---@field empty boolean?
---@field user_data any?

---@alias ComplItem string|Compl

local RE_UNMATCHED_BRACKET = vim.regex("\\[\\[\\(.*\\]\\]\\)\\@!")
local RE_LAST_SPACE = vim.regex(".*\\zs\\s")

---@return integer
local function find_start()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1 -- make zero-indexed
    local col = cursor[2]
    local start, stop = RE_UNMATCHED_BRACKET:match_line(0, row, 0, col)
    if start then
        return start
    end
    start, stop = RE_LAST_SPACE:match_line(0, row, 0, col)
    if stop then
        return stop
    end
    return 0
end

---Check if the cursor is right before `]]`.
---
---We need this so that completion doesn't insert superfluous brackets.
---
---@return boolean
local function double_brackets_after_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1 -- make zero-indexed
    local col = cursor[2]
    local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
    line = line:sub(col + 1)
    return vim.startswith(line, "]]")
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
    if not start then
        return base:sub(3), true
    end
    return base:sub(stop + 1), true
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
---@return Compl
local function make_compl(db, node, matched, skip_closing_brackets)
    return {
        word = ("[[id:%s][%s%s"):format(node.id, matched, skip_closing_brackets and "" or "]]"),
        abbr = matched,
        menu = node.level > 0 and ("*"):rep(node.level) or "file",
        info = build_info(db, node),
    }
end

---@param db org-roam.core.Database
---@return {label:string, node:org-roam.core.file.Node}[]
local function collect_completion_candidates(db)
    local items = {}
    for _, id in ipairs(db:ids()) do
        ---@type org-roam.core.file.Node
        local node = db:get(id)
        items[#items + 1] = { label = node.title, node = node }
        for _, alias in ipairs(node.aliases) do
            items[#items + 1] = { label = alias, node = node }
        end
    end
    return items
end

---@param roam OrgRoam
---@param base string
---@return ComplItem[]|{words:ComplItem[], refresh:"always"}
local function collect_completions(roam, base)
    local bracketed
    base, bracketed = clean_base(base)
    local skip_closing_brackets = bracketed and double_brackets_after_cursor()
    local db_promise = roam.database:internal():next(function(db)
        if vim.fn.complete_check() ~= 0 then
            return nil
        end
        local candidates = collect_completion_candidates(db)
        if base ~= "" then
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
return function(findstart, base)
    if findstart ~= 0 then
        return find_start()
    else
        local roam = require "org-roam"
        return { words = collect_completions(roam, base), refresh = "always" }
    end
end
