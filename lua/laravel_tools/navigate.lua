local M = {}

---------------------------------------------------------------------------
-- Utilitários
---------------------------------------------------------------------------
local function warn(msg)
  vim.notify("[goto] " .. msg, vim.log.levels.WARN)
end

local function find_root()
  return vim.fs.root(0, { "artisan" }) or vim.fs.root(0, { "composer.json" }) or vim.fn.getcwd()
end

local function open_at(path, line)
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    vim.cmd("normal! ^zz")
  end
end

local function read_lines(path)
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end
end

---------------------------------------------------------------------------
-- Destinos
---------------------------------------------------------------------------
local function go_view(root, name)
  if name:find("::", 1, true) then
    return warn("view de pacote não suportada: " .. name)
  end
  local rel = name:gsub("%.", "/")

  for _, ext in ipairs({ ".blade.php", ".php" }) do
    local p = ("%s/resources/views/%s%s"):format(root, rel, ext)
    if vim.fn.filereadable(p) == 1 then
      return open_at(p)
    end
  end

  local target = ("%s/resources/views/%s.blade.php"):format(root, rel)
  vim.ui.select({ "Criar", "Cancelar" }, { prompt = ("View '%s' não existe:"):format(name) }, function(c)
    if c ~= "Criar" then
      return
    end
    vim.fn.mkdir(vim.fs.dirname(target), "p")
    vim.fn.writefile({}, target)
    open_at(target)
  end)
end

-- config('app.name') -> config/app.php, na linha de 'name' (segue o caminho aninhado)
local function go_config(root, key)
  local segs = vim.split(key, ".", { plain = true })
  local path = ("%s/config/%s.php"):format(root, segs[1])
  local lines = read_lines(path)
  if not lines then
    return warn("arquivo de config não existe: config/" .. segs[1] .. ".php")
  end

  local line = 1
  for i = 2, #segs do
    local pat = "^%s*['\"]" .. vim.pesc(segs[i]) .. "['\"]%s*=>"
    local found
    for ln = (i == 2 and 1 or line + 1), #lines do
      if lines[ln]:match(pat) then
        found = ln
        break
      end
    end
    if not found then
      break
    end
    line = found
  end
  open_at(path, line)
end

local function go_env(root, key)
  for _, f in ipairs({ ".env", ".env.example" }) do
    local path = root .. "/" .. f
    local lines = read_lines(path)
    if lines then
      local pat = "^%s*" .. vim.pesc(key) .. "%s*="
      for i, l in ipairs(lines) do
        if l:match(pat) then
          return open_at(path, i)
        end
      end
    end
  end
  warn(key .. " não está no .env nem no .env.example")
end

---------------------------------------------------------------------------
-- O que reconhecer sob o cursor
-- fn: token da função | arg: posição da string (1 ou 2) | skip: prefixo que invalida
---------------------------------------------------------------------------
local SPECS = {
  { kind = "view", fn = "Route::view", arg = 2 },
  { kind = "view", fn = "View::make", arg = 1 },
  { kind = "view", fn = "view", arg = 1, skip = "Route::" }, -- view('x') e ->view('x') (mailables)
  { kind = "view", fn = "markdown", arg = 1 },
  { kind = "view", fn = "@include", arg = 1 },
  { kind = "view", fn = "@includeIf", arg = 1 },
  { kind = "view", fn = "@extends", arg = 1 },
  { kind = "config", fn = "config", arg = 1 },
  { kind = "config", fn = "Config::get", arg = 1 },
  { kind = "env", fn = "env", arg = 1 },
}

local GO = { view = go_view, config = go_config, env = go_env }

local function arg_at_cursor(line, col, spec)
  local pf = vim.pesc(spec.fn)
  local pat
  if spec.arg == 1 then
    pat = pf .. "%s*%(%s*()(['\"])(.-)%2()"
  else
    pat = pf .. "%s*%(%s*['\"].-['\"]%s*,%s*()(['\"])(.-)%2()"
  end

  local init = 1
  while true do
    local s, _, p1, _, name, p2 = line:find(pat, init)
    if not s then
      return
    end
    init = s + 1

    local ok = true
    if spec.fn:sub(1, 1) ~= "@" then
      local prev = s > 1 and line:sub(s - 1, s - 1) or ""
      if prev:match("[%w_$]") then
        ok = false
      end
    end
    if ok and spec.skip and s > #spec.skip and line:sub(s - #spec.skip, s - 1) == spec.skip then
      ok = false
    end

    if ok and name ~= "" and col >= p1 and col <= p2 - 1 then
      return name
    end
  end
end

-- tenta tratar o que está sob o cursor; true se tratou
local function handle()
  local ft = vim.bo.filetype
  if ft ~= "php" and ft ~= "blade" then
    return false
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  for _, spec in ipairs(SPECS) do
    local name = arg_at_cursor(line, col, spec)
    if name then
      GO[spec.kind](find_root(), name)
      return true
    end
  end
  return false
end

-- para quem quiser mapear manualmente
function M.goto_cursor()
  if not handle() then
    vim.lsp.buf.definition()
  end
end

---------------------------------------------------------------------------
-- Pickers de pastas (Snacks.picker.files; senão vim.ui.select)
---------------------------------------------------------------------------
M.dirs = {
  controllers = { "app/Http/Controllers", "Controllers" },
  models = { "app/Models", "Models" },
  views = { "resources/views", "Views" },
  routes = { "routes", "Rotas" },
  livewire = { "app/Livewire", "Livewire" },
  policies = { "app/Policies", "Policies" },
  jobs = { "app/Jobs", "Jobs" },
  migrations = { "database/migrations", "Migrations" },
}

function M.pick(name)
  local d = M.dirs[name]
  if not d then
    return warn("pasta desconhecida: " .. tostring(name))
  end

  local dir = find_root() .. "/" .. d[1]
  if vim.fn.isdirectory(dir) == 0 then
    return warn("a pasta não existe: " .. d[1])
  end

  if _G.Snacks and Snacks.picker and Snacks.picker.files then
    return Snacks.picker.files({ cwd = dir, title = d[2] })
  end

  local files = vim.fn.globpath(dir, "**/*.*", false, true)
  table.sort(files)
  vim.ui.select(files, {
    prompt = d[2] .. ":",
    format_item = function(f)
      return f:sub(#dir + 2)
    end,
  }, function(f)
    if f then
      open_at(f)
    end
  end)
end

---------------------------------------------------------------------------
-- Setup: o gd do LazyVim chama Snacks.picker.lsp_definitions(); interceptamos essa função
-- (se o laravel_routes também interceptar, os dois se encadeiam: cada um chama o anterior)
---------------------------------------------------------------------------
local function patch_snacks()
  if M._patched or not (_G.Snacks and Snacks.picker) then
    return
  end
  local orig = Snacks.picker.lsp_definitions
  if type(orig) ~= "function" then
    return
  end
  M._patched = true
  Snacks.picker.lsp_definitions = function(...)
    if handle() then
      return
    end
    return orig(...)
  end
end

function M.setup()
  patch_snacks()
  vim.schedule(patch_snacks)
end

return M
