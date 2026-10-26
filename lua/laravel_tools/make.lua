local lang = require("laravel_tools.lang")

local M = {}

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
-- "auto": ./vendor/bin/sail artisan se existir vendor/bin/sail + compose | true: força Sail | false: php do host
M.use_sail = "auto"
M.artisan = nil -- sobrescreve o comando base, ex.: { "docker", "compose", "exec", "-T", "laravel.test", "php", "artisan" }
M.timeout = 30000
M.open_max = 4 -- abre no máximo N arquivos criados (ex.: model + migration + factory)

-- flags extras por tipo, ex.: M.flags = { test = { "--pest" } }
M.flags = {}

-- eventos do framework oferecidos ao criar um Listener (além dos de app/Events)
M.extra_events = {
  "Illuminate\\Auth\\Events\\Registered",
  "Illuminate\\Auth\\Events\\Login",
  "Illuminate\\Auth\\Events\\Logout",
  "Illuminate\\Auth\\Events\\Failed",
  "Illuminate\\Auth\\Events\\Verified",
  "Illuminate\\Auth\\Events\\PasswordReset",
  "Illuminate\\Mail\\Events\\MessageSent",
}

---------------------------------------------------------------------------
-- Tipos
--   id, label
--   dir      : pasta base (relativa à raiz) usada no autocomplete; sem dir = nome simples (ex.: migration)
--   cmd      : comando artisan (make:xxx)  -> roda via Sail, respeita seus stubs e a versão do Laravel
--   template : em vez de cmd, escreve o arquivo direto (para tipos que o artisan não tem, como Action)
--   flags    : flags fixas do tipo
--   steps    : perguntas depois do nome, em ordem; cada resposta vira flags do artisan
--       { choice = { { "rótulo", { "--flag" } }, ... }, prompt = "..." }
--       { class = { dir, flag, none, extra, other }, prompt = "..." }   (escolhe uma classe existente)
-- Esc em qualquer pergunta cancela tudo (nada é criado).
---------------------------------------------------------------------------
M.types = {
  {
    id = "action",
    label = "Action",
    dir = "app/Actions",
    -- segue o estilo dos stubs do Laravel (docblock + "//"), com o trait do lorisleiva/laravel-actions
    template = function(ns, name)
      return {
        "<?php",
        "",
        "namespace " .. ns .. ";",
        "",
        "use Lorisleiva\\Actions\\Concerns\\AsAction;",
        "",
        "class " .. name,
        "{",
        "    use AsAction;",
        "",
        "    /**",
        "     * Execute the action.",
        "     */",
        "    public function handle(): void",
        "    {",
        "        //",
        "    }",
        "}",
      }
    end,
  },
  {
    id = "job",
    label = "Job",
    dir = "app/Jobs",
    cmd = "make:job",
    steps = {
      {
        prompt = "Job:",
        choice = {
          { "Na fila (ShouldQueue + Queueable)", {} },
          { "Síncrono (--sync)", { "--sync" } },
        },
      },
    },
  },
  {
    id = "listener",
    label = "Listener",
    dir = "app/Listeners",
    cmd = "make:listener",
    steps = {
      {
        prompt = "Evento que o listener escuta:",
        class = {
          dir = "app/Events",
          flag = "--event",
          none = "(sem evento)",
          extra = function()
            return M.extra_events
          end,
          other = true,
        },
      },
      {
        prompt = "Execução:",
        choice = {
          { "Síncrono", {} },
          { "Na fila (--queued)", { "--queued" } },
        },
      },
    },
  },
  { id = "event", label = "Event", dir = "app/Events", cmd = "make:event" },
  { id = "notification", label = "Notification", dir = "app/Notifications", cmd = "make:notification" },
  { id = "mail", label = "Mailable", dir = "app/Mail", cmd = "make:mail" },
  {
    id = "model",
    label = "Model",
    dir = "app/Models",
    cmd = "make:model",
    steps = {
      {
        prompt = "Model — extras:",
        choice = {
          { "Só o model", {} },
          { "+ migration (-m)", { "-m" } },
          { "+ migration + factory (-mf)", { "-mf" } },
          { "Tudo (--all)", { "--all" } },
        },
      },
    },
  },
  { id = "migration", label = "Migration", cmd = "make:migration" },
  {
    id = "controller",
    label = "Controller",
    dir = "app/Http/Controllers",
    cmd = "make:controller",
    steps = {
      {
        prompt = "Controller:",
        choice = {
          { "Simples", {} },
          { "Invokable (--invokable)", { "--invokable" } },
          { "Resource (--resource)", { "--resource" } },
          { "API (--api)", { "--api" } },
        },
      },
    },
  },
  { id = "request", label = "Form Request", dir = "app/Http/Requests", cmd = "make:request" },
  { id = "resource", label = "API Resource", dir = "app/Http/Resources", cmd = "make:resource" },
  {
    id = "policy",
    label = "Policy",
    dir = "app/Policies",
    cmd = "make:policy",
    steps = {
      {
        prompt = "Model da policy:",
        class = { dir = "app/Models", flag = "--model", none = "(policy simples)", other = true },
      },
    },
  },
  {
    id = "observer",
    label = "Observer",
    dir = "app/Observers",
    cmd = "make:observer",
    steps = {
      {
        prompt = "Model do observer:",
        class = { dir = "app/Models", flag = "--model", none = "(observer simples)", other = true },
      },
    },
  },
  { id = "rule", label = "Rule", dir = "app/Rules", cmd = "make:rule" },
  { id = "middleware", label = "Middleware", dir = "app/Http/Middleware", cmd = "make:middleware" },
  { id = "command", label = "Console Command", dir = "app/Console/Commands", cmd = "make:command" },
  { id = "component", label = "Blade Component (classe + view)", dir = "app/View/Components", cmd = "make:component" },
  { id = "seeder", label = "Seeder", dir = "database/seeders", cmd = "make:seeder" },
  {
    id = "factory",
    label = "Factory",
    dir = "database/factories",
    cmd = "make:factory",
    steps = {
      {
        prompt = "Model da factory:",
        class = { dir = "app/Models", flag = "--model", none = "(sem model)", other = true },
      },
    },
  },
  { id = "test", label = "Test (Feature)", dir = "tests/Feature", cmd = "make:test" },
  { id = "unit_test", label = "Test (Unit)", dir = "tests/Unit", cmd = "make:test", flags = { "--unit" } },
  { id = "exception", label = "Exception", dir = "app/Exceptions", cmd = "make:exception" },
  { id = "cast", label = "Cast", dir = "app/Casts", cmd = "make:cast" },
  { id = "scope", label = "Scope", dir = "app/Models/Scopes", cmd = "make:scope" },
  { id = "provider", label = "Service Provider", dir = "app/Providers", cmd = "make:provider" },
  { id = "channel", label = "Broadcast Channel", dir = "app/Broadcasting", cmd = "make:channel" },
  -- Laravel 11+
  { id = "enum", label = "Enum (Laravel 11+)", dir = "app/Enums", cmd = "make:enum" },
  { id = "interface", label = "Interface (Laravel 11+)", dir = "app/Contracts", cmd = "make:interface" },
  { id = "trait", label = "Trait (Laravel 11+)", dir = "app/Concerns", cmd = "make:trait" },
}

-- para registrar tipos próprios ou de pacotes: require(...).add_type({ id = ..., label = ..., dir = ..., cmd = ... })
function M.add_type(t)
  table.insert(M.types, t)
end

---------------------------------------------------------------------------
-- Utilitários
---------------------------------------------------------------------------
local function warn(msg)
  vim.notify("[make] " .. msg, vim.log.levels.WARN)
end
local function info(msg)
  vim.notify("[make] " .. msg, vim.log.levels.INFO)
end

local function studly(s)
  local out = {}
  for part in s:gmatch("[^%-_%s]+") do
    out[#out + 1] = part:sub(1, 1):upper() .. part:sub(2)
  end
  return table.concat(out)
end

local function norm(s)
  return (s:gsub("[%-_%s]", ""):lower())
end

local function normalize_sep(text)
  return (text:gsub("[\\%.]", "/"))
end

local function find_root()
  return lang.ui.find_root()
end

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

local function open_files(paths)
  vim.cmd("normal! m'")
  local n = math.min(#paths, M.open_max)
  -- abre do último para o primeiro: termina no arquivo principal (o primeiro)
  for i = n, 1, -1 do
    vim.cmd("edit " .. vim.fn.fnameescape(paths[i]))
  end
end

---------------------------------------------------------------------------
-- Autocomplete de pastas (por nível, ignorando caixa e hífen)
---------------------------------------------------------------------------
local function subdirs(path)
  local out = {}
  if vim.fn.isdirectory(path) == 0 then
    return out
  end
  for _, name in ipairs(vim.fn.readdir(path)) do
    if vim.fn.isdirectory(path .. "/" .. name) == 1 then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function resolve_dirs(base, dirpart)
  local cur, real = base, ""
  for seg in dirpart:gmatch("[^/]+") do
    local found
    for _, name in ipairs(subdirs(cur)) do
      if norm(name) == norm(seg) then
        found = name
        break
      end
    end
    if not found then
      return nil
    end
    cur = cur .. "/" .. found
    real = real .. found .. "/"
  end
  return real, cur
end

local function completer(root, dir)
  local base = root .. "/" .. dir
  return function(text)
    text = normalize_sep(text)
    local dirpart, prefix = text:match("^(.*/)(.*)$")
    if not dirpart then
      dirpart, prefix = "", text
    end

    local real, cur = resolve_dirs(base, dirpart)
    if not real then
      return {}
    end

    local items, want = {}, norm(prefix)
    for _, name in ipairs(subdirs(cur)) do
      if norm(name):sub(1, #want) == want then
        items[#items + 1] = { word = real .. name .. "/" }
      end
    end
    return items
  end
end

-- sugestão inicial: pasta do arquivo atual (no mesmo tipo) ou o mesmo caminho de outra camada
-- (ex.: estou em app/Livewire/Tenant/App/Home/X.php e app/Jobs/Tenant/App/Home já existe)
local function current_default(root, t)
  if not t.dir then
    return ""
  end
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  local rootn = vim.fs.normalize(root) .. "/"
  if file:sub(1, #rootn) ~= rootn then
    return ""
  end
  local rel = file:sub(#rootn + 1)

  local bases = { "app/Livewire" }
  for _, x in ipairs(M.types) do
    if x.dir then
      bases[#bases + 1] = x.dir
    end
  end
  table.sort(bases, function(a, b)
    return #a > #b
  end)

  for _, b in ipairs(bases) do
    if rel:sub(1, #b + 1) == b .. "/" then
      local sub = vim.fs.dirname(rel:sub(#b + 2))
      if sub ~= "." and vim.fn.isdirectory(root .. "/" .. t.dir .. "/" .. sub) == 1 then
        return sub .. "/"
      end
      return ""
    end
  end
  return ""
end

---------------------------------------------------------------------------
-- Perguntas (steps)
---------------------------------------------------------------------------
-- classes de uma pasta app/...: { { label = "Tenant\\Foo", fqcn = "App\\Events\\Tenant\\Foo" } }
local function list_classes(root, dir)
  local base = root .. "/" .. dir
  local ns = (dir:gsub("^app", "App"):gsub("/", "\\"))

  local out = {}
  for _, f in ipairs(vim.fn.globpath(base, "**/*.php", false, true)) do
    local rel = f:sub(#base + 2, -5)
    local label = (rel:gsub("/", "\\"))
    out[#out + 1] = { label = label, fqcn = ns .. "\\" .. label }
  end
  table.sort(out, function(a, b)
    return a.label < b.label
  end)
  return out
end

local function run_steps(root, steps, i, flags, done)
  local step = steps[i]
  if not step then
    return done(flags)
  end

  local function advance(extra)
    local f = vim.deepcopy(flags)
    vim.list_extend(f, extra or {})
    run_steps(root, steps, i + 1, f, done)
  end

  if step.choice then
    local labels = {}
    for k, c in ipairs(step.choice) do
      labels[k] = c[1]
    end
    return vim.ui.select(labels, { prompt = step.prompt }, function(choice, idx)
      if not choice then
        return
      end -- Esc: cancela tudo
      advance(step.choice[idx][2])
    end)
  end

  local cls = step.class
  local entries = { { label = cls.none or "(nenhum)", none = true } }
  for _, c in ipairs(list_classes(root, cls.dir)) do
    entries[#entries + 1] = { label = c.label, fqcn = c.fqcn }
  end
  local extra = type(cls.extra) == "function" and cls.extra() or cls.extra or {}
  for _, fqcn in ipairs(extra) do
    entries[#entries + 1] = { label = fqcn, fqcn = fqcn }
  end
  if cls.other then
    entries[#entries + 1] = { label = "✎ Outra classe (digitar)…", other = true }
  end

  vim.ui.select(entries, {
    prompt = step.prompt,
    format_item = function(e)
      return e.label
    end,
  }, function(e)
    if not e then
      return
    end -- Esc: cancela tudo
    if e.none then
      return advance()
    end
    if e.other then
      return vim.ui.input({ prompt = "Classe completa (ex.: App\\Events\\Foo): " }, function(v)
        v = v and vim.trim(v) or ""
        if v ~= "" then
          advance({ cls.flag .. "=" .. v })
        end
      end)
    end
    advance({ cls.flag .. "=" .. e.fqcn })
  end)
end

---------------------------------------------------------------------------
-- Execução
---------------------------------------------------------------------------
local ansi = "\27%[[%d;]*[A-Za-z]"

-- caminhos "[app/Jobs/X.php]" impressos pelo artisan
local function collect_paths(root, out)
  local paths, seen = {}, {}
  for p in out:gmatch("%[([^%]\n]+%.php)%]") do
    local abs = p:sub(1, 1) == "/" and p or (root .. "/" .. p)
    if not seen[abs] and vim.fn.filereadable(abs) == 1 then
      seen[abs] = true
      paths[#paths + 1] = abs
    end
  end
  return paths
end

local function run_artisan(root, t, name, extra)
  local cmd = artisan_cmd(root)
  vim.list_extend(cmd, { t.cmd, name })
  vim.list_extend(cmd, t.flags or {})
  vim.list_extend(cmd, M.flags[t.id] or {})
  vim.list_extend(cmd, extra or {})
  table.insert(cmd, "--no-interaction")

  vim.api.nvim_echo({ { ("Criando %s…"):format(t.label), "WarningMsg" } }, false, {})

  local ok, err = pcall(vim.system, cmd, { cwd = root, text = true, timeout = M.timeout }, function(res)
    vim.schedule(function()
      local out = ((res.stdout or "") .. "\n" .. (res.stderr or "")):gsub(ansi, "")
      local paths = collect_paths(root, out)
      if #paths == 0 then
        -- "already exists", comando inexistente nesta versão, Sail parado, etc.
        local msg = vim.trim(out)
        return warn(msg ~= "" and msg:sub(1, 300) or ("falhou (código %s)"):format(res.code))
      end
      open_files(paths)
    end)
  end)
  if not ok then
    warn(tostring(err))
  end
end

local function write_direct(root, t, segs)
  local name = segs[#segs]
  local dirs = vim.list_slice(segs, 1, #segs - 1)

  local ns = (t.dir:gsub("^app", "App"):gsub("/", "\\"))
  if #dirs > 0 then
    ns = ns .. "\\" .. table.concat(dirs, "\\")
  end

  local parts = { root, t.dir }
  vim.list_extend(parts, dirs)
  local folder = table.concat(parts, "/")
  local path = folder .. "/" .. name .. ".php"

  if vim.fn.filereadable(path) == 1 then
    warn("já existe: " .. vim.fn.fnamemodify(path, ":."))
    return open_files({ path })
  end

  vim.fn.mkdir(folder, "p")
  vim.fn.writefile(t.template(ns, name), path)
  info("criado: " .. vim.fn.fnamemodify(path, ":."))
  open_files({ path })
end

---------------------------------------------------------------------------
-- Nome
---------------------------------------------------------------------------
local function parse_name(text, t)
  text = vim.trim(text)
  if text == "" then
    return nil, "nome vazio"
  end

  if not t.dir then -- nome simples (migration...)
    if text:find("%s") then
      return nil, "sem espaços: use snake_case (create_posts_table)"
    end
    return { text }
  end

  text = normalize_sep(text)
  if text:match("/$") then
    return nil, "falta o nome depois da última pasta"
  end

  local segs = {}
  for seg in text:gmatch("[^/]+") do
    local s = studly(seg)
    if not s:match("^[%a_][%w_]*$") then
      return nil, ("nome inválido: '%s'"):format(seg)
    end
    segs[#segs + 1] = s
  end
  return segs
end

---------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------
local function create_type(t)
  local root = find_root()

  lang.ui.input({
    title = "Novo " .. t.label,
    footer = (t.dir and (t.dir .. "/Nome") or "nome") .. "  ·  <Tab> navega · <CR> aceita/cria · <Esc> cancela",
    default = current_default(root, t),
    complete = t.dir and completer(root, t.dir) or nil,
  }, function(v)
    if v == nil then
      return
    end
    local segs, err = parse_name(v, t)
    if not segs then
      return warn(err)
    end

    if t.template then
      return write_direct(root, t, segs)
    end

    local name = table.concat(segs, "/")
    run_steps(root, t.steps or {}, 1, {}, function(flags)
      run_artisan(root, t, name, flags)
    end)
  end)
end

-- type_id (opcional): "job", "listener", "model"... Sem argumento, mostra a lista de tipos.
function M.create(type_id)
  if type_id then
    for _, t in ipairs(M.types) do
      if t.id == type_id then
        return create_type(t)
      end
    end
    return warn("tipo desconhecido: " .. type_id)
  end

  vim.ui.select(M.types, {
    prompt = "Criar:",
    format_item = function(t)
      return t.label
    end,
  }, function(t)
    if t then
      create_type(t)
    end
  end)
end

return M
