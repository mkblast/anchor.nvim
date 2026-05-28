local M = {}

local data_path = vim.fn.stdpath("data") .. "/anchor.json"

--- Get the root directory fixed at Neovim startup
---@return string
local function get_project_root()
    local cwd  = vim.fn.getcwd()
    local root = vim.fs.root(cwd, { ".git", ".hg", "Makefile", "package.json" })
    return root or cwd
end


---@class AnchorConfig
---@field root_dir string

---@type AnchorConfig
local default_config = {
    root_dir = get_project_root(),
}

M.config             = vim.deepcopy(default_config)

---@type table<string, string[]>
M.projects           = {}

---@type table<string, string>
M.toggle_history     = {}

--- Get the list of saved paths for the current project root context
---@return string[]
local function get_current_paths()
    local root = M.config.root_dir
    if not M.projects[root] then
        M.projects[root] = {}
    end
    return M.projects[root]
end

--- Execute the directory switch and update the alternating toggle history state
---@param target_dir string The absolute path to switch into
local function execute_cd(target_dir)
    local root = M.config.root_dir
    local current_dir = vim.fn.getcwd()

    if current_dir ~= target_dir then
        M.toggle_history[root] = current_dir
    end

    vim.cmd("cd " .. vim.fn.fnameescape(target_dir))
    print("-> " .. target_dir)
end

--- Serialize the current projects table state into the JSON data file
local function save_to_json()
    local file = io.open(data_path, "w")
    if file then
        local json_data = vim.json.encode(M.projects)
        file:write(json_data)
        file:close()
    else
        print("Error: Could not save data to " .. data_path)
    end
end

--- Deserialize the JSON data file into the in-memory projects table state
local function load_from_json()
    local file = io.open(data_path, "r")
    if not file then
        M.projects = {}
        return
    end

    local content = file:read("*a")
    file:close()

    local status, decoded = pcall(vim.json.decode, content)
    if status and type(decoded) == "table" then
        M.projects = decoded
    else
        M.projects = {}
    end
end

--- Add an explicit directory path to the current project's saved list and change into it
---@param path string The absolute or relative path to store and navigate to
function M.add_path(path)
    if not path or path == "" then
        print("Error: Provided path is empty or invalid.")
        return
    end

    path = vim.fn.fnamemodify(path, ":p:h")

    local current_paths = get_current_paths()
    local already_exists = false

    for _, p in ipairs(current_paths) do
        if p == path then
            already_exists = true
            break
        end
    end

    if not already_exists then
        table.insert(current_paths, path)
        save_to_json()
        print("Saved path: " .. path)
    end

    execute_cd(path)
end

--- Helper function to add the current working directory (CWD) to the project's list
function M.add_current_path()
    M.add_path(vim.fn.getcwd())
end

--- Wipe all stored paths specifically for the active project context
function M.clear_paths()
    local root = M.config.root_dir
    M.projects[root] = {}
    save_to_json()
    print("Cleared all paths for this project.")
end

--- Open the floating menu layout containing all saved paths for the current project
function M.toggle_menu()
    local buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("filetype", "anchor", { buf = buf })

    local width         = math.floor(vim.o.columns * 0.6)
    local height        = math.floor(vim.o.lines * 0.4)
    local row           = math.floor((vim.o.lines - height) / 2)
    local col           = math.floor((vim.o.columns - width) / 2)

    local project_root  = M.config.root_dir
    local opts          = {
        relative  = "editor",
        width     = width,
        height    = height,
        row       = row,
        col       = col,
        border    = "rounded",
        title     = " Paths (" .. vim.fn.fnamemodify(project_root, ":t") .. ") ",
        title_pos = "center",
    }

    local win           = vim.api.nvim_open_win(buf, true, opts)

    local current_paths = get_current_paths()
    local display_lines = vim.deepcopy(current_paths)
    if #display_lines == 0 then
        table.insert(display_lines, "  (No paths saved for this project yet)")
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)

    vim.api.nvim_set_option_value("cursorline", true, { win = win })

    local function select_path()
        local cursor     = vim.api.nvim_win_get_cursor(win)
        local line_num   = cursor[1]

        local target_dir = get_current_paths()[line_num]

        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end

        if target_dir then
            execute_cd(target_dir)
        end
    end

    vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
        buffer   = buf,
        once     = true,
        callback = function()
            local lines         = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local updated_paths = {}

            for _, line in ipairs(lines) do
                local trimmed = vim.trim(line)
                if trimmed ~= "" and not trimmed:match("^%(No paths saved") then
                    table.insert(updated_paths, trimmed)
                end
            end

            M.projects[project_root] = updated_paths
            save_to_json()
        end,
    })

    local map_opts = { silent = true, buffer = buf }
    vim.keymap.set("n", "<CR>", select_path, map_opts)
    vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, map_opts)
    vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, map_opts)
end

--- Directly switch to a path stored at a specific list index slot
---@param index integer The 1-indexed slot number of the target directory
function M.nav_to(index)
    local current_paths = get_current_paths()
    local target_dir    = current_paths[index]
    if target_dir then
        execute_cd(target_dir)
    else
        print("No path found at slot " .. index)
    end
end

--- Toggle back and forth between the current directory and the last active directory
function M.toggle_last()
    local root         = M.config.root_dir
    local previous_dir = M.toggle_history[root]

    if previous_dir then
        execute_cd(previous_dir)
    else
        print("No previous path history for this project yet.")
    end
end

load_from_json()

--- Initialize plug-in configuration state with optional user table structures
---@param opts? AnchorConfig Configuration overrides
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", default_config, opts or {})
end

return M
