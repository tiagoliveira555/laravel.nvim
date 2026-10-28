local M = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function expand(lhs)
  return (lhs:gsub("<[Ll]eader>", vim.g.mapleader or "\\"))
end

-- global normal-mode mapping with this lhs (handles <leader> and <Space>)
local function find_map(lhs)
  local want = expand(lhs)
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    local got = m.lhs:gsub("<[Ss]pace>", " ")
    if got == want then
      return m
    end
  end
end

local function is_lazy(m)
  local rhs = (m.rhs or ""):lower()
  return m.desc == "Lazy" or rhs == "<cmd>lazy<cr>" or rhs == ":lazy<cr>"
end

-- LazyVim's own <leader>L
local function is_changelog(m)
  return (m.desc or ""):lower():find("changelog", 1, true) ~= nil
end

local warned = false

local function wk_add(spec)
  local ok, wk = pcall(require, "which-key")
  if ok then
    wk.add(spec)
  end
end

-- LazyVim maps <leader>l to :Lazy, which makes it both a command and a prefix.
-- If the prefix is taken by Lazy, move Lazy to cfg.lazy_key. Returns true when moved.
local function move_lazy(cfg)
  local current = find_map(cfg.prefix)
  if not current or not is_lazy(current) then
    return false
  end

  local target = find_map(cfg.lazy_key)
  if target and not is_lazy(target) then
    if is_changelog(target) then
      -- LazyVim's "<leader>L" (changelog): Lazy takes its place; the changelog can move elsewhere
      if cfg.changelog_key then
        vim.keymap.set("n", cfg.changelog_key, target.callback or target.rhs, { desc = target.desc })
      end
    else
      if warned then
        return false
      end
      warned = true
      vim.notify(
        ("[laravel.nvim] %s is already mapped, so Lazy was not moved. Set keymaps.lazy_key or keymaps.prefix."):format(
          cfg.lazy_key
        ),
        vim.log.levels.WARN
      )
      return false
    end
  end

  pcall(vim.keymap.del, "n", expand(cfg.prefix))
  vim.keymap.set("n", cfg.lazy_key, "<cmd>Lazy<cr>", { desc = "Lazy" })
  return true
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
function M.setup(cfg)
  local lang = require("laravel_tools.lang")
  local commands = require("laravel_tools.commands")
  local navigate = require("laravel_tools.navigate")
  local routes = require("laravel_tools.routes")
  local make = require("laravel_tools.make")
  local livewire = require("laravel_tools.livewire")
  local move = require("laravel_tools.move")

  local prefix = cfg.prefix

  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
  end

  local function leader(suffix, rhs, desc)
    map("n", prefix .. suffix, rhs, desc)
  end

  -- translations -----------------------------------------------------------
  if cfg.translate then
    map("n", cfg.translate, function()
      lang.add()
    end, "Laravel: translations")
    map("x", cfg.translate, function()
      lang.add_visual()
    end, "Laravel: translate selection")
  end

  -- create -----------------------------------------------------------------
  leader("n", function()
    make.create()
  end, "Create (job, listener, model...)")
  leader("l", function()
    livewire.create()
  end, "New Livewire component")
  leader("A", function()
    make.create("action")
  end, "New Action")
  leader("j", function()
    make.create("job")
  end, "New Job")
  leader("L", function()
    make.create("listener")
  end, "New Listener")

  -- routes -----------------------------------------------------------------
  leader("g", function()
    routes.goto_route("action")
  end, "Go to route action")
  leader("p", function()
    routes.pick()
  end, "Route list")

  -- folders ----------------------------------------------------------------
  leader("c", function()
    navigate.pick("controllers")
  end, "Controllers")
  leader("m", function()
    navigate.pick("models")
  end, "Models")
  leader("v", function()
    navigate.pick("views")
  end, "Views")
  leader("r", function()
    navigate.pick("routes")
  end, "Route files")
  leader("w", function()
    navigate.pick("livewire")
  end, "Livewire components")
  leader("R", function()
    move.move()
  end, "Move PHP class")

  -- artisan, composer, tests ----------------------------------------------
  leader("a", "<cmd>Artisan<cr>", "Artisan")
  leader("C", "<cmd>Composer<cr>", "Composer")
  leader("M", commands.migrate, "Migrations")
  leader("t", function()
    commands.test()
  end, "Tests (artisan test)")
  leader("T", commands.tinker, "Tinker")

  -- sail -------------------------------------------------------------------
  leader("su", commands.sail_up, "Sail up")
  leader("sd", commands.sail_down, "Sail down")
  leader("sr", commands.sail_restart, "Sail restart")
  leader("ss", commands.sail_status, "Sail status")
  leader("sh", commands.sail_shell, "Sail shell")
  leader("sl", commands.sail_logs, "Sail logs")
  leader("so", commands.open, "Open app in browser")

  -- which-key (optional) ---------------------------------------------------
  if cfg.which_key then
    local icon = vim.fn.nr2char(0xe73f) .. " " -- nf-dev-laravel
    wk_add({
      { prefix, group = "Laravel", icon = { icon = icon, color = "red" } },
      { prefix .. "s", group = "Sail" },
    })
  end

  -- LazyVim: move Lazy out of the way ---------------------------------------
  -- LazyVim loads its own keymaps on VeryLazy, possibly after this plugin, so the
  -- check runs now, on the next tick, and once more after VeryLazy. It is a no-op
  -- once <leader>l is no longer mapped to Lazy.
  if cfg.move_lazy then
    local function run()
      if move_lazy(cfg) and cfg.which_key then
        wk_add({
          { cfg.lazy_key, desc = "Lazy", icon = { icon = vim.fn.nr2char(0xf04b2) .. " ", color = "blue" } },
        })
      end
    end

    run()
    vim.schedule(run)
    vim.api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      once = true,
      callback = function()
        vim.schedule(run)
      end,
    })
  end
end

return M
