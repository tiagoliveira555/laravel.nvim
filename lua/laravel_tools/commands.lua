local M = {}

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
-- "auto": Sail se existir vendor/bin/sail + compose | true: força Sail | false: php/composer do host
-- Importante: não há fallback silencioso para o host quando o Sail falha.
M.use_sail = "auto"
M.artisan_cmd = nil -- sobrescreve o comando base do artisan, ex.: { "docker", "compose", "exec", "-T", "app", "php", "artisan" }
M.term_height = 15
M.url = nil -- URL do app; padrão: APP_URL do .env, senão http://localhost
M.prefetch = true -- carrega a lista de comandos do artisan em segundo plano (para o completion)

---------------------------------------------------------------------------
-- Utilitários
---------------------------------------------------------------------------
local SAIL = "./vendor/bin/sail"

local function warn(msg)
  vim.notify("[laravel] " .. msg, vim.log.levels.WARN)
end
local function info(msg)
  vim.notify("[laravel] " .. msg, vim.log.levels.INFO)
end

local function find_root()
  return vim.fs.root(0, { "artisan" }) or vim.fs.root(0, { "composer.json" }) or vim.fn.getcwd()
end

-- projeto tem Sail instalado? (compose + vendor/bin/sail)
local function sail_present(root)
  for _, f in ipairs({ "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml" }) do
    if vim.fn.filereadable(root .. "/" .. f) == 1 then
      return vim.fn.executable(root .. "/vendor/bin/sail") == 1
    end
  end
  return false
end

local function use_sail(root)
  if M.use_sail == "auto" then
    return sail_present(root)
  end
  return M.use_sail == true
end

local function cmd_for(root, tool, args)
  local cmd
  if tool == "artisan" then
    if M.artisan_cmd then
      cmd = vim.deepcopy(M.artisan_cmd)
    elseif use_sail(root) then
      cmd = { SAIL, "artisan" }
    else
      cmd = { "php", "artisan" }
    end
  elseif tool == "composer" then
    cmd = use_sail(root) and { SAIL, "composer" } or { "composer" }
  else -- "sail"
    cmd = { SAIL }
  end
  vim.list_extend(cmd, args or {})
  return cmd
end

local function split_args(s)
  return vim.split(vim.trim(s or ""), "%s+", { trimempty = true })
end

-- terminal em split na parte de baixo
local function term(cmd, root)
  vim.cmd(("botright %dsplit"):format(M.term_height))
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  local opts = { cwd = root }
  if vim.fn.has("nvim-0.10") == 1 then
    opts.term = true
    vim.fn.jobstart(cmd, opts)
  else
    vim.fn.termopen(cmd, opts)
  end
  vim.cmd("startinsert")
end

-- a saída pode ter avisos antes/depois do JSON
local function extract_json(out, open, close)
  local s = out:find("^%" .. open) and 1 or nil
  if not s then
    local nl = out:find("\n%" .. open)
    s = nl and nl + 1 or nil
  end
  local e = out:match(".*()%" .. close)
  if not s or not e or e < s then
    return nil
  end
  local ok, data = pcall(vim.json.decode, out:sub(s, e), { luanil = { object = true, array = true } })
  if ok then
    return data
  end
end

---------------------------------------------------------------------------
-- Artisan
---------------------------------------------------------------------------
local cache = { root = nil, names = nil, loading = false, waiters = {} }

-- cb(names | nil, err)
local function load_commands(cb)
  local root = find_root()
  if cache.root == root and cache.names then
    if cb then
      cb(cache.names)
    end
    return
  end
  if cb then
    table.insert(cache.waiters, cb)
  end
  if cache.loading then
    return
  end
  cache.loading = true

  local function done(names, err)
    cache.loading = false
    local waiters = cache.waiters
    cache.waiters = {}
    for _, f in ipairs(waiters) do
      f(names, err)
    end
  end

  local cmd = cmd_for(root, "artisan", { "list", "--format=json" })
  local ok = pcall(vim.system, cmd, { cwd = root, text = true, timeout = 30000 }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local msg = vim.trim(((res.stderr or "") ~= "" and res.stderr or res.stdout) or "")
        return done(nil, msg:sub(1, 200))
      end
      local data = extract_json(res.stdout or "", "{", "}")
      if not data or type(data.commands) ~= "table" then
        return done(nil, "JSON do artisan list inválido")
      end

      local names = {}
      for _, c in ipairs(data.commands) do
        if c.name and not c.hidden then
          names[#names + 1] = c.name
        end
      end
      table.sort(names)
      cache.root, cache.names = root, names
      done(names)
    end)
  end)
  if not ok then
    done(nil, "não consegui iniciar o artisan")
  end
end

function M.run_artisan(args)
  local root = find_root()
  if vim.fn.filereadable(root .. "/artisan") == 0 then
    return warn("artisan não encontrado em " .. root)
  end
  term(cmd_for(root, "artisan", args), root)
end

local function ask_args(prompt, on_args)
  vim.ui.input({ prompt = prompt }, function(a)
    if a ~= nil then
      on_args(split_args(a))
    end
  end)
end

function M.pick_artisan()
  load_commands(function(names, err)
    if not names then
      return warn("artisan list falhou: " .. (err or "?"))
    end
    vim.ui.select(names, { prompt = "Artisan:" }, function(c)
      if not c then
        return
      end
      ask_args("artisan " .. c .. " ", function(rest)
        M.run_artisan(vim.list_extend({ c }, rest))
      end)
    end)
  end)
end

---------------------------------------------------------------------------
-- Composer
---------------------------------------------------------------------------
local COMPOSER_CMDS = {
  "install",
  "update",
  "require",
  "remove",
  "dump-autoload",
  "outdated",
  "show",
  "why",
  "why-not",
  "validate",
  "audit",
  "diagnose",
  "clear-cache",
  "status",
}

function M.run_composer(args)
  local root = find_root()
  if vim.fn.filereadable(root .. "/composer.json") == 0 then
    return warn("composer.json não encontrado")
  end
  term(cmd_for(root, "composer", args), root)
end

function M.pick_composer()
  vim.ui.select(COMPOSER_CMDS, { prompt = "Composer:" }, function(c)
    if not c then
      return
    end
    ask_args("composer " .. c .. " ", function(rest)
      M.run_composer(vim.list_extend({ c }, rest))
    end)
  end)
end

---------------------------------------------------------------------------
-- Sail
---------------------------------------------------------------------------
local SAIL_CMDS = {
  "up",
  "down",
  "stop",
  "restart",
  "ps",
  "logs",
  "shell",
  "root-shell",
  "artisan",
  "composer",
  "php",
  "node",
  "npm",
  "yarn",
  "test",
  "tinker",
  "build",
  "rebuild",
}

function M.sail(args)
  local root = find_root()
  if not sail_present(root) then
    return warn("Sail não encontrado (vendor/bin/sail + docker-compose.yml)")
  end
  term(cmd_for(root, "sail", args), root)
end

function M.sail_up()
  M.sail({ "up", "-d" })
end
function M.sail_down()
  M.sail({ "down" })
end
function M.sail_restart()
  M.sail({ "restart" })
end
function M.sail_shell()
  M.sail({ "shell" })
end
function M.sail_logs()
  M.sail({ "logs", "-f", "--tail=200" })
end
function M.tinker()
  require("laravel_tools.tinker").toggle()
end
function M.tinker_repl()
  M.run_artisan({ "tinker" })
end

function M.test(args)
  M.run_artisan(vim.list_extend({ "test" }, args or {}))
end

-- containers rodando? (assíncrono)
function M.sail_status()
  local root = find_root()
  if not sail_present(root) then
    return warn("Sail não encontrado")
  end
  vim.system({ SAIL, "ps" }, { cwd = root, text = true, timeout = 15000 }, function(res)
    vim.schedule(function()
      local out = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
      local lines = vim.split(out, "\n", { trimempty = true })
      if res.code ~= 0 or #lines <= 1 then
        return warn("Sail parado — rode :Sail up -d  (ou <leader>Lsu)")
      end
      info("Sail rodando:\n" .. out)
    end)
  end)
end

local function app_url(root)
  if M.url then
    return M.url
  end
  if vim.fn.filereadable(root .. "/.env") == 1 then
    for _, l in ipairs(vim.fn.readfile(root .. "/.env")) do
      local v = l:match("^APP_URL%s*=%s*[\"']?([^\"'%s]+)")
      if v then
        return v
      end
    end
  end
  return "http://localhost"
end

function M.open()
  local url = app_url(find_root())
  vim.ui.open(url)
  info("abrindo " .. url)
end

local MIGRATE = {
  "migrate",
  "migrate:status",
  "migrate:rollback",
  "migrate:fresh",
  "migrate:fresh --seed",
  "migrate:refresh",
  "db:seed",
}

function M.migrate()
  vim.ui.select(MIGRATE, { prompt = "Migrations:" }, function(c)
    if c then
      M.run_artisan(split_args(c))
    end
  end)
end

---------------------------------------------------------------------------
-- Setup: comandos de usuário (:Artisan, :Composer, :Sail)
---------------------------------------------------------------------------
local function complete_first(list)
  return function(lead, line)
    local parts = vim.split(vim.trim(line), "%s+")
    if #parts > 2 or (#parts == 2 and line:match("%s$")) then
      return {}
    end
    local out = {}
    for _, n in ipairs(list) do
      if n:sub(1, #lead) == lead then
        out[#out + 1] = n
      end
    end
    return out
  end
end

function M.setup()
  vim.api.nvim_create_user_command("Artisan", function(o)
    if o.args == "" then
      return M.pick_artisan()
    end
    M.run_artisan(split_args(o.args))
  end, {
    nargs = "*",
    desc = "Artisan (via Sail se disponível)",
    complete = function(lead, line)
      if not cache.names then
        load_commands()
      end
      return complete_first(cache.names or {})(lead, line)
    end,
  })

  vim.api.nvim_create_user_command("Composer", function(o)
    if o.args == "" then
      return M.pick_composer()
    end
    M.run_composer(split_args(o.args))
  end, { nargs = "*", desc = "Composer (via Sail se disponível)", complete = complete_first(COMPOSER_CMDS) })

  vim.api.nvim_create_user_command("Sail", function(o)
    if o.args == "" then
      return vim.ui.select(SAIL_CMDS, { prompt = "Sail:" }, function(c)
        if c then
          M.sail({ c })
        end
      end)
    end
    M.sail(split_args(o.args))
  end, { nargs = "*", desc = "Laravel Sail", complete = complete_first(SAIL_CMDS) })

  if M.prefetch then
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("LaravelTools", { clear = true }),
      pattern = { "php", "blade" },
      once = true,
      callback = function()
        if vim.fn.filereadable(find_root() .. "/artisan") == 0 then
          return
        end
        vim.defer_fn(function()
          load_commands()
        end, 800) -- assíncrono: falha em silêncio (ex.: Sail parado)
      end,
    })
  end
end

return M
