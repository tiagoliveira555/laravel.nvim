local M = {}

local function has_compose(root)
  for _, f in ipairs({ "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml" }) do
    if vim.fn.filereadable(root .. "/" .. f) == 1 then
      return true
    end
  end
  return false
end

function M.check()
  local h = vim.health

  h.start("laravel.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim >= 0.10")
  else
    h.error("Neovim >= 0.10 is required (vim.system, vim.fs.root, vim.ui.open)")
  end

  if require("laravel_tools").options then
    h.ok("setup() was called")
  else
    h.warn("setup() was not called", { 'Use opts = {} in your lazy.nvim spec or call require("laravel_tools").setup()' })
  end

  h.start("laravel.nvim: tools")

  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep found (translation usages search)")
  elseif vim.fn.executable("grep") == 1 then
    h.warn("ripgrep not found, falling back to grep (slower)")
  else
    h.warn("neither ripgrep nor grep found: finding translation usages will not work")
  end

  for _, bin in ipairs({ "php", "composer" }) do
    if vim.fn.executable(bin) == 1 then
      h.ok(bin .. " found on the host")
    else
      h.info(bin .. " not found on the host (fine if you only use Sail)")
    end
  end

  if vim.fn.executable("docker") == 1 then
    h.ok("docker found")
  else
    h.info("docker not found (only needed for Sail)")
  end

  h.start("laravel.nvim: optional integrations")

  for name, why in pairs({
    ["which-key"] = "group names and icons",
    ["snacks"] = "pickers and gd interception",
  }) do
    if pcall(require, name) then
      h.ok(name .. " found (" .. why .. ")")
    else
      h.info(name .. " not found (" .. why .. "); falling back to vim.ui.select / LSP")
    end
  end

  h.start("laravel.nvim: current project")

  local root = require("laravel_tools.lang").ui.find_root()
  h.info("project root: " .. root)

  if vim.fn.filereadable(root .. "/artisan") == 1 then
    h.ok("artisan found")
  else
    h.warn("artisan not found in the project root (not a Laravel project?)")
  end

  local sail = vim.fn.executable(root .. "/vendor/bin/sail") == 1
  if sail and has_compose(root) then
    h.ok("Sail detected: artisan/composer will run through ./vendor/bin/sail (use_sail = auto)")
  elseif sail then
    h.warn("vendor/bin/sail exists but no docker-compose/compose file was found")
  else
    h.info("Sail not detected: artisan/composer will run on the host")
  end
end

return M
