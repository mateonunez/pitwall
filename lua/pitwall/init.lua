-- pitwall for Neovim: the lanes from inside the editor.
--
--   :Pitwall          pick a lane (Telescope when installed, vim.ui.select otherwise); <CR> goes to it in tmux,
--                     <C-f> opens its folder here (tab-local cd, then find files), 1 2 3 answer it when it asks
--   :PitwallCd        cd this tab to a lane's folder (its worktree)
--   require("pitwall").status()   "◆2 ✓1" for a statusline: lanes that wait on you, refreshed in the background
--
-- Everything goes through the pitwall CLI (`pitwall ls --json`, `peek`, `go`, `answer`): no state of its own.
-- An answer is sent only after a confirm, and only to a lane that asks (the CLI refuses any other).

local M = {}

local cfg = { bin = "pitwall", refresh = 5000 }
local cache = { lanes = {}, status = "" }

local glyph = { asking = "◆", done = "✓", working = "⠙", idle = "○", gone = "✗" }

local function run(args)
  local out = vim.system(vim.list_extend({ cfg.bin }, args), { text = true }):wait()
  return out.code == 0 and out.stdout or nil, out.stderr
end

local function lanes()
  local out = run({ "ls", "--json" })
  local ok, data = pcall(vim.json.decode, out or "[]")
  return ok and data or {}
end

local function label(l)
  local what = (l.state == "asking" and l.question ~= vim.NIL and l.question) or l.task or ""
  return string.format("%s %-18s %-8s %s", glyph[l.state] or "·", l.window, l.session, what)
end

local function go(l) run({ "go", l.ref }) end

local function cd(l, find)
  if not l.folder or l.folder == "" then return end
  vim.cmd.tcd(vim.fn.fnameescape(l.folder))
  vim.notify("pitwall: " .. l.window .. " → " .. l.folder)
  if find then
    local ok, builtin = pcall(require, "telescope.builtin")
    if ok then builtin.find_files({ cwd = l.folder }) end
  end
end

local function answer(l, key)
  if l.state ~= "asking" then return vim.notify("pitwall: " .. l.window .. " is not asking", vim.log.levels.WARN) end
  local q = (l.question ~= vim.NIL and l.question) or "its question"
  if vim.fn.confirm(string.format("Answer %s to %s?\n%s", key, l.window, q), "&Yes\n&No", 2) ~= 1 then return end
  local _, err = run({ "answer", l.ref, key })
  vim.notify(err and err ~= "" and err or ("pitwall: answered " .. key .. " to " .. l.window))
end

local function telescope(list, on_pick)
  local pickers, finders, conf = require("telescope.pickers"), require("telescope.finders"), require("telescope.config").values
  local actions, state, previewers = require("telescope.actions"), require("telescope.actions.state"), require("telescope.previewers")
  pickers.new({}, {
    prompt_title = "pitwall · lanes",
    finder = finders.new_table({
      results = list,
      entry_maker = function(l) return { value = l, display = label(l), ordinal = label(l) } end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "the lane's screen",
      define_preview = function(self, entry)
        local out = run({ "peek", entry.value.ref, "60" }) or ""
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(out, "\n"))
      end,
    }),
    attach_mappings = function(bufnr, map)
      local function with(fn) return function() local e = state.get_selected_entry(); actions.close(bufnr); fn(e.value) end end
      actions.select_default:replace(with(on_pick or go))
      map({ "i", "n" }, "<C-f>", with(function(l) cd(l, true) end))
      for _, k in ipairs({ "1", "2", "3" }) do map("n", k, with(function(l) answer(l, k) end)) end
      return true
    end,
  }):find()
end

function M.pick(on_pick)
  local list = lanes()
  if #list == 0 then return vim.notify("pitwall: no lanes (is pitwall loaded in this tmux?)", vim.log.levels.WARN) end
  if pcall(require, "telescope") then return telescope(list, on_pick) end
  vim.ui.select(list, { prompt = "pitwall lanes", format_item = label }, function(l) if l then (on_pick or go)(l) end end)
end

function M.status() return cache.status end

local function refresh()
  vim.system({ cfg.bin, "ls", "--json" }, { text = true }, function(out)
    local ok, data = pcall(vim.json.decode, out.stdout or "[]")
    if not ok then return end
    local a, d = 0, 0
    for _, l in ipairs(data) do
      if l.state == "asking" then a = a + 1 elseif l.state == "done" then d = d + 1 end
    end
    cache.lanes = data
    cache.status = (a > 0 and ("◆" .. a) or "") .. ((a > 0 and d > 0) and " " or "") .. (d > 0 and ("✓" .. d) or "")
  end)
end

function M.setup(opts)
  cfg = vim.tbl_extend("force", cfg, opts or {})
  if vim.fn.executable(cfg.bin) == 0 or not vim.env.TMUX then return end -- outside tmux there are no lanes
  vim.api.nvim_create_user_command("Pitwall", function() M.pick() end, { desc = "pitwall: pick a lane" })
  vim.api.nvim_create_user_command("PitwallCd", function() M.pick(function(l) cd(l, false) end) end,
    { desc = "pitwall: cd this tab to a lane's folder" })
  refresh()
  local timer = vim.uv.new_timer()
  timer:start(cfg.refresh, cfg.refresh, function() refresh() end)
end

return M
