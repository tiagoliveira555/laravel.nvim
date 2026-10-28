local M = {}

---@class LaravelToolsKeymaps
---@field enabled boolean register the default keymaps
---@field prefix string leader prefix for the Laravel group
---@field translate string|false mapping for the translation helper (normal + visual)
---@field which_key boolean register group names/icons in which-key (if installed)
---@field move_lazy boolean if the prefix is mapped to :Lazy (LazyVim default for <leader>l), move Lazy to lazy_key
---@field lazy_key string where Lazy goes when move_lazy is on (replaces LazyVim's own <leader>L changelog mapping)
---@field changelog_key string|nil optional new key for LazyVim's changelog, which lazy_key displaces

M.defaults = {
  -- "auto": use Sail when vendor/bin/sail and a compose file exist | true: force Sail | false: host php/composer
  -- There is no silent fallback to the host when Sail fails.
  use_sail = "auto",

  -- Override the base artisan command,
  -- e.g. { "docker", "compose", "exec", "-T", "app", "php", "artisan" }
  artisan = nil,

  keymaps = {
    enabled = true,
    prefix = "<leader>l",
    translate = "gl",
    which_key = true,
    move_lazy = true,
    lazy_key = "<leader>L",
  },

  -- Per-module options. Anything set here overrides the module default.
  -- See the README for the full list.
  commands = {}, -- :Artisan / :Composer / :Sail / tinker / tests / migrations
  routes = {}, -- route('name') navigation
  make = {}, -- make:* wizard (extra_types = {} registers your own types)
  livewire = {}, -- Livewire component creator
  lang = {}, -- translations
  navigate = {}, -- view()/config()/env() navigation and folder pickers
  tinker = {}, -- Tinker board
  move = {}, -- PHPantom class/file movement
}

local function is_list(t)
  return (vim.islist or vim.tbl_islist)(t)
end

-- copies `values` into `mod`: dict-like tables are merged one level deep, everything else replaces
local function apply(mod, values)
  for k, v in pairs(values or {}) do
    local cur = mod[k]
    if type(v) == "table" and type(cur) == "table" and not is_list(v) then
      mod[k] = vim.tbl_extend("force", cur, v)
    else
      mod[k] = v
    end
  end
end

function M.setup(user)
  if vim.fn.has("nvim-0.10") == 0 then
    return vim.notify("[laravel.nvim] Neovim >= 0.10 is required", vim.log.levels.ERROR)
  end

  local opts = vim.tbl_deep_extend("force", M.defaults, user or {})
  M.options = opts

  local lang = require("laravel_tools.lang")
  local commands = require("laravel_tools.commands")
  local navigate = require("laravel_tools.navigate")
  local routes = require("laravel_tools.routes")
  local make = require("laravel_tools.make")
  local livewire = require("laravel_tools.livewire")
  local tinker = require("laravel_tools.tinker")
  local move = require("laravel_tools.move")

  -- shared options first, so per-module options can still override them
  commands.use_sail, commands.artisan_cmd = opts.use_sail, opts.artisan
  routes.use_sail, routes.artisan = opts.use_sail, opts.artisan
  make.use_sail, make.artisan = opts.use_sail, opts.artisan
  tinker.use_sail, tinker.artisan = opts.use_sail, opts.artisan

  local extra_types = opts.make.extra_types
  opts.make.extra_types = nil

  apply(lang, opts.lang)
  apply(commands, opts.commands)
  apply(navigate, opts.navigate)
  apply(routes, opts.routes)
  apply(make, opts.make)
  apply(livewire, opts.livewire)
  apply(tinker, opts.tinker)
  apply(move, opts.move)

  for _, t in ipairs(extra_types or {}) do
    make.add_type(t)
  end

  lang.setup()
  commands.setup()
  navigate.setup()
  routes.setup()
  tinker.setup()

  if opts.keymaps.enabled then
    require("laravel_tools.keymaps").setup(opts.keymaps)
  end
end

return M
