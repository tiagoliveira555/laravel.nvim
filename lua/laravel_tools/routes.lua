local M = {}

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
-- "auto": usa ./vendor/bin/sail artisan se existir vendor/bin/sail + docker-compose/compose.yml
-- true: força Sail | false: usa php artisan do host
M.use_sail = "auto"

-- sobrescreve o comando base (ex.: { "docker", "compose", "exec", "-T", "laravel.test", "php", "artisan" })
M.artisan = nil

M.cache_ttl = 300 -- segundos; salvar um arquivo em routes/ também invalida
M.timeout = 30000 -- ms para o route:list
M.map_gd = true -- gd em PHP/Blade: route('x') -> Laravel, senão LSP
M.prefetch = true -- ao abrir o 1º PHP, carrega as rotas em segundo plano

---------------------------------------------------------------------------
-- Utilitários
---------------------------------------------------------------------------
local function warn(msg)
  vim.notify("[routes] " .. msg, vim.log.levels.WARN)
end
local function say(msg)
  vim.api.nvim_echo({ { msg, "WarningMsg" } }, false, {})
end

local function read_lines(path)
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end
end

local function find_root()
  return vim.fs.root(0, { "artisan" }) or vim.fs.root(0, { "composer.json" }) or vim.fn.getcwd()
end

-- abre o arquivo e posiciona o cursor (line 1-based, col 0-based)
local function open_at(path, line, col)
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, col or 0 })
    if not col then
      vim.cmd("normal! ^")
    end
    vim.cmd("normal! zz")
  end
end

---------------------------------------------------------------------------
-- route:list --json (assíncrono, com cache)
---------------------------------------------------------------------------
local state = { root = nil, routes = nil, by_name = nil, ts = 0, loading = false, waiters = {}, tried = false }

local function artisan_cmd(root)
  if M.artisan then
    return vim.deepcopy(M.artisan)
  end

  local use = M.use_sail
  if use == "auto" then
    local has_compose = false
    for _, f in ipairs({ "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml" }) do
      if vim.fn.filereadable(root .. "/" .. f) == 1 then
        has_compose = true
        break
      end
    end
    use = has_compose and vim.fn.executable(root .. "/vendor/bin/sail") == 1
  end
  if use then
    return { "./vendor/bin/sail", "artisan" }
  end
  return { "php", "artisan" }
end

-- a saída pode ter avisos antes/depois do JSON
local function parse_routes(out)
  local s = out:find("^%[") and 1 or nil
  if not s then
    local nl = out:find("\n%[")
    s = nl and nl + 1 or nil
  end
  if not s then
    return nil
  end
  local e = out:match(".*()%]")
  if not e or e < s then
    return nil
  end
  local ok, data = pcall(vim.json.decode, out:sub(s, e), { luanil = { object = true, array = true } })
  if ok and type(data) == "table" then
    return data
  end
end

-- cb(routes | nil, err)
function M.load(cb, force)
  local root = find_root()
  if state.root ~= root then
    state.root, state.routes, state.by_name, state.tried = root, nil, nil, false
  end
  if not force and state.routes and (os.time() - state.ts) < M.cache_ttl then
    return cb(state.routes)
  end

  table.insert(state.waiters, cb)
  if state.loading then
    return
  end
  state.loading = true
  state.tried = true

  local function done(routes, err)
    state.loading = false
    local waiters = state.waiters
    state.waiters = {}
    for _, f in ipairs(waiters) do
      f(routes, err)
    end
  end

  local cmd = artisan_cmd(root)
  vim.list_extend(cmd, { "route:list", "--json" })

  local ok, err = pcall(vim.system, cmd, { cwd = root, text = true, timeout = M.timeout }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local msg = vim.trim(((res.stderr or "") ~= "" and res.stderr or res.stdout) or "")
        return done(nil, ("route:list falhou (%s): %s"):format(res.code, msg:sub(1, 200)))
      end
      local routes = parse_routes(res.stdout or "")
      if not routes then
        return done(nil, "não consegui ler o JSON do route:list")
      end

      local by_name = {}
      for _, r in ipairs(routes) do
        if type(r.name) == "string" and r.name ~= "" then
          by_name[r.name] = r
        end
      end
      state.routes, state.by_name, state.ts = routes, by_name, os.time()
      done(routes)
    end)
  end)
  if not ok then
    done(nil, tostring(err))
  end
end

function M.invalidate()
  state.ts = 0
end

-- recarrega em segundo plano
function M.refresh()
  M.load(function(routes, err)
    if not routes and err then
      warn(err)
    end
  end, true)
end

---------------------------------------------------------------------------
-- Classe -> arquivo (PSR-4 do composer.json)
---------------------------------------------------------------------------
local psr4_cache = {}

local function psr4_map(root)
  if psr4_cache[root] then
    return psr4_cache[root]
  end
  local list = {}
  local lines = read_lines(root .. "/composer.json")
  if lines then
    local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"), { luanil = { object = true, array = true } })
    if ok and type(data) == "table" then
      for _, sect in ipairs({ "autoload", "autoload-dev" }) do
        local p = data[sect] and data[sect]["psr-4"]
        for prefix, dirs in pairs(p or {}) do
          if type(dirs) ~= "table" then
            dirs = { dirs }
          end
          for _, d in ipairs(dirs) do
            list[#list + 1] = { prefix = prefix, dir = d }
          end
        end
      end
    end
  end
  table.sort(list, function(a, b)
    return #a.prefix > #b.prefix
  end)
  psr4_cache[root] = list
  return list
end

local function class_to_file(root, class)
  for _, e in ipairs(psr4_map(root)) do
    if class:sub(1, #e.prefix) == e.prefix then
      local rest = class:sub(#e.prefix + 1):gsub("\\", "/")
      local path = ("%s/%s/%s.php"):format(root, (e.dir:gsub("/+$", "")), rest)
      if vim.fn.filereadable(path) == 1 then
        return path
      end
    end
  end
end

-- "App\\X\\Ctrl@metodo" | "App\\Livewire\\X" | "Closure" -> class, method
local function parse_action(action)
  if type(action) ~= "string" or action == "" or action == "Closure" then
    return nil
  end
  local class, method = action:match("^(.-)@(.+)$")
  class = class or action
  if class:match("^Illuminate\\Routing\\") then
    return nil
  end
  return class, method
end

-- linha/coluna da função (ou da declaração da classe) dentro do arquivo
local function locate_in_class(path, class, method)
  local lines = read_lines(path) or {}
  local short = class:match("([^\\]+)$")

  local function find(pat, name)
    for i, l in ipairs(lines) do
      local s, e = l:find(pat)
      if s and not l:sub(e + 1, e + 1):match("[%w_]") then
        local ns = l:find(name, s, true)
        return i, (ns or s) - 1
      end
    end
  end

  if method then
    local i, c = find("function%s+" .. vim.pesc(method), method)
    if i then
      return i, c
    end
  end
  local i, c = find("class%s+" .. vim.pesc(short), short)
  return i, c
end

---------------------------------------------------------------------------
-- Definição da rota em routes/**/*.php
-- O nome final vem de grupos (->name('tenant.')), então procuramos o literal
-- do nome completo e, depois, de sufixos cada vez menores:
-- tenant.auth.password.reset -> auth.password.reset -> password.reset -> reset
---------------------------------------------------------------------------
local function narrow(hits, short, method)
  if #hits <= 1 or (not short and not method) then
    return hits
  end
  local out = {}
  for _, h in ipairs(hits) do
    local blob = table.concat(h.lines, " ", math.max(1, h.lnum - 3), h.lnum)
    if (short and blob:find(short, 1, true)) or (method and blob:find("'" .. method .. "'", 1, true)) then
      out[#out + 1] = h
    end
  end
  return #out > 0 and out or hits
end

local function find_definition(root, name, route)
  local files = vim.fn.glob(root .. "/routes/**/*.php", false, true)
  table.sort(files)

  local class, method = parse_action(route and route.action)
  local short = class and class:match("([^\\]+)$")

  local segs = vim.split(name, ".", { plain = true })
  local cache = {}

  for i = 1, #segs do
    local suffix = table.concat(segs, ".", i)
    local pat = "->name%s*%(%s*(['\"])" .. vim.pesc(suffix) .. "%1"
    local hits = {}
    for _, f in ipairs(files) do
      local lines = cache[f]
      if not lines then
        lines = read_lines(f) or {}
        cache[f] = lines
      end
      for ln, l in ipairs(lines) do
        if l:find(pat) then
          hits[#hits + 1] = { file = f, lnum = ln, lines = lines }
        end
      end
    end
    if #hits > 0 then
      return narrow(hits, short, method)
    end
  end
end

local function pick_hit(root, hits)
  if #hits == 1 then
    return open_at(hits[1].file, hits[1].lnum)
  end
  vim.ui.select(hits, {
    prompt = "Definições da rota:",
    format_item = function(h)
      local rel = h.file:sub(#root + 2)
      return ("%s:%d  %s"):format(rel, h.lnum, vim.trim(h.lines[h.lnum]):sub(1, 100))
    end,
  }, function(choice)
    if choice then
      open_at(choice.file, choice.lnum)
    end
  end)
end

---------------------------------------------------------------------------
-- Destino: definição (routes/*.php) ou action (controller/Livewire)
---------------------------------------------------------------------------
local function goto_definition(root, name, route)
  local hits = find_definition(root, name, route)
  if not hits then
    return false
  end
  pick_hit(root, hits)
  return true
end

local function goto_action(root, route)
  local class, method = parse_action(route.action)
  if not class then
    return false
  end
  local path = class_to_file(root, class)
  if not path then
    return false
  end
  local line, col = locate_in_class(path, class, method)
  open_at(path, line, col)
  return true
end

local function open_route(root, name, route, mode)
  local order = mode == "action" and { "action", "definition" } or { "definition", "action" }
  for _, what in ipairs(order) do
    local ok
    if what == "action" then
      ok = goto_action(root, route)
    else
      ok = goto_definition(root, name, route)
    end
    if ok then
      return
    end
  end
  warn(("sem destino para '%s' (action: %s)"):format(name, route.action or "?"))
end

---------------------------------------------------------------------------
-- Nome da rota sob o cursor: route('x'), to_route('x'), redirectRoute('x'),
-- routeIs('x'), Route::has('x'), Route::is('x')  (inclui Blade: href="{{ route('x') }}")
---------------------------------------------------------------------------
local ROUTE_FNS = {
  "route",
  "to_route",
  "redirectRoute",
  "routeIs",
  "Route::has",
  "Route::is",
  "signedRoute",
  "temporarySignedRoute", -- URL::signedRoute(...), URL::temporarySignedRoute(...)
}

local function route_name_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  for _, fn in ipairs(ROUTE_FNS) do
    local init = 1
    local pat = vim.pesc(fn) .. "%s*%(%s*()(['\"])(.-)%2()"
    while true do
      local s, _, p1, _, name, p2 = line:find(pat, init)
      if not s then
        break
      end
      init = s + 1
      local prev = s > 1 and line:sub(s - 1, s - 1) or ""
      if not prev:match("[%w_$]") and col >= p1 and col <= p2 - 1 then
        if name ~= "" and not name:find("*", 1, true) then
          return name
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Rota inexistente: sugere nomes parecidos (ex.: 'home' -> 'tenant.home')
---------------------------------------------------------------------------
-- nomes que terminam em ".<name>" ou que contêm o texto
local function similar_routes(name)
  local out = {}
  for _, r in ipairs(state.routes or {}) do
    local n = r.name
    if type(n) == "string" and n ~= "" and (n:sub(-(#name + 1)) == "." .. name or n:find(name, 1, true)) then
      out[#out + 1] = r
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return vim.list_slice(out, 1, 50)
end

local function route_missing(root, name, mode)
  local items = similar_routes(name)
  if #items == 0 then
    local total = 0
    for _ in pairs(state.by_name or {}) do
      total = total + 1
    end
    return warn(("rota '%s' não existe no route:list (%d rotas nomeadas)"):format(name, total))
  end

  vim.ui.select(items, {
    prompt = ("'%s' não existe; rotas parecidas:"):format(name),
    format_item = function(r)
      return ("%s   %s /%s"):format(r.name, r.method or "", r.uri or "")
    end,
  }, function(choice)
    if choice then
      open_route(root, choice.name, choice, mode)
    end
  end)
end

---------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------
-- mode: "definition" (padrão: routes/*.php) | "action" (controller / componente Livewire)
-- fallback: chamado quando não há route('...') sob o cursor
function M.goto_route(mode, fallback)
  local name = route_name_at_cursor()
  if not name then
    if fallback then
      return fallback()
    end
    return say("Nenhum route('...') sob o cursor")
  end

  mode = mode or "definition"
  local root = find_root()
  if not state.routes or (os.time() - state.ts) >= M.cache_ttl then
    say("Carregando rotas (route:list)…")
  end

  M.load(function(routes, err)
    if not routes then
      return warn(err or "não foi possível listar as rotas")
    end

    local route = state.by_name[name]
    if route then
      return open_route(root, name, route, mode)
    end

    -- o cache pode estar velho: recarrega uma vez (a menos que tenha acabado de carregar)
    if (os.time() - state.ts) < 3 then
      return route_missing(root, name, mode)
    end

    say("Rota não encontrada; recarregando route:list…")
    M.load(function(fresh, err2)
      if not fresh then
        return warn(err2 or "não foi possível listar as rotas")
      end
      local found = state.by_name[name]
      if found then
        return open_route(root, name, found, mode)
      end
      route_missing(root, name, mode)
    end, true)
  end)
end

-- lista todas as rotas nomeadas; Enter abre a definição
function M.pick()
  M.load(function(routes, err)
    if not routes then
      return warn(err or "não foi possível listar as rotas")
    end
    local items = {}
    for _, r in ipairs(routes) do
      if r.name then
        items[#items + 1] = r
      end
    end
    table.sort(items, function(a, b)
      return a.name < b.name
    end)

    local root = find_root()
    vim.ui.select(items, {
      prompt = "Rotas:",
      format_item = function(r)
        return ("%s   %s /%s   %s"):format(r.name, r.method or "", r.uri or "", r.action or "")
      end,
    }, function(choice)
      if choice then
        open_route(root, choice.name, choice, "definition")
      end
    end)
  end)
end

local function lsp_definition()
  if _G.Snacks and Snacks.picker and Snacks.picker.lsp_definitions then
    return Snacks.picker.lsp_definitions()
  end
  vim.lsp.buf.definition()
end

-- O gd do LazyVim chama Snacks.picker.lsp_definitions(). Em vez de disputar o mapeamento
-- (o LazyVim o reaplica quando o servidor LSP registra capacidades depois do attach),
-- interceptamos essa função: com route('...') sob o cursor vai para o Laravel, senão segue o LSP.
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
    local ft = vim.bo.filetype
    if (ft == "php" or ft == "blade") and route_name_at_cursor() then
      return M.goto_route("definition")
    end
    return orig(...)
  end
end

-- chamar uma vez (ex.: em config/keymaps.lua)
function M.setup()
  local group = vim.api.nvim_create_augroup("LaravelRoutes", { clear = true })

  vim.api.nvim_create_user_command("RoutesRefresh", M.refresh, { desc = "Recarrega as rotas (route:list)" })

  -- editou rotas: recarrega em segundo plano
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*/routes/*.php",
    callback = function()
      M.invalidate()
      M.refresh()
    end,
  })

  if M.prefetch then
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = { "php", "blade" },
      callback = function()
        local root = find_root()
        if state.root == root and (state.routes or state.loading or state.tried) then
          return
        end
        if vim.fn.filereadable(root .. "/artisan") == 0 then
          return
        end
        vim.defer_fn(function()
          M.load(function() end)
        end, 500) -- falha em silêncio (ex.: Sail parado)
      end,
    })
  end

  if M.map_gd then
    patch_snacks()
    vim.schedule(patch_snacks) -- caso o Snacks ainda não estivesse carregado

    local function attach(buf)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local ft = vim.bo[buf].filetype
      if ft ~= "php" and ft ~= "blade" then
        return
      end
      vim.keymap.set("n", "gd", function()
        M.goto_route("definition", lsp_definition)
      end, { buffer = buf, desc = "Goto Definition (route() → Laravel, senão LSP)" })
    end

    -- schedule: roda depois do LazyVim registrar o gd dele
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(ev)
        vim.schedule(function()
          attach(ev.buf)
        end)
      end,
    })
    -- buffers sem LSP (ex.: Blade)
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = { "php", "blade" },
      callback = function(ev)
        vim.defer_fn(function()
          attach(ev.buf)
        end, 150)
      end,
    })
  end
end

return M
