local RE_UNMATCHED_OPEN_BRACKET = vim.regex("\\[\\[\\%(.*\\]\\]\\)\\@!")
local RE_UNMATCHED_CLOSING_BRACKET = vim.regex("\\%(\\[\\[.*\\)\\@<!\\]\\]")
local RE_LAST_SPACE = vim.regex(".*\\zs\\s")
local RE_FIRST_SPACE = vim.regex("\\s")

---@class org-roam.api.completion.Utils
M = {}

---@param cursor_before_line string
---@return integer
function M.find_start(cursor_before_line)
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
function M.find_stop(cursor_after_line)
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

---Remove leading brackets in the completion base
---
---If the base looks like `'[[label'`, this returns `'label', true`.
---If the base looks like `'[[url][label'`, this returns `'label', true`.
---Otherwise, this returns `base, false`.
---
---@param base string
---@return string, boolean
function M.clean_base(base)
    if not vim.startswith(base, "[[") then
        return base, false
    end
    local start, stop = base:find("][", 1, true)
    if start then
        return base:sub(stop + 1), true
    end
    return base:sub(3), true
end

---@generic T
---@param db org-roam.core.Database
---@param transform fun(label: string, node: org-roam.core.file.Node): `T`
---@return T[]
function M.collect_completion_candidates(db, transform)
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
function M.build_info(db, node)
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

return M
