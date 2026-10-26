local lang = require("laravel_tools.lang")

local M = {}

-- pastas (relativas à raiz do projeto)
M.class_dir = "app/Livewire"
M.view_dir = "resources/views/livewire"
M.namespace = "App\\Livewire"

-- depois de criar:
--   "both"  : classe + blade, cada um em seu buffer na mesma janela (termina na classe)
--   "split" : classe + blade lado a lado
--   "class" : só a classe
--   "none"  : não abre nada
M.open = "both"

---------------------------------------------------------------------------
-- Utilitários
---------------------------------------------------------------------------
local function warn(msg)
  vim.notify("[livewire] " .. msg, vim.log.levels.WARN)
end

local function info(msg)
  vim.notify("[livewire] " .. msg, vim.log.levels.INFO)
end

-- create-event / create_event / createEvent -> CreateEvent
local function studly(s)
  local out = {}
  for part in s:gmatch("[^%-_%s]+") do
    out[#out + 1] = part:sub(1, 1):upper() .. part:sub(2)
  end
  return table.concat(out)
end

-- CreateEvent -> create-event (mesmo comportamento do Str::kebab)
local function kebab(s)
  local out = {}
  for i = 1, #s do
    local c = s:sub(i, i)
    if i > 1 and c:match("%u") then
      out[#out + 1] = "-"
    end
    out[#out + 1] = c:lower()
  end
  return table.concat(out)
end

-- para comparar ignorando caixa, hífen e underscore
local function norm(s)
  return (s:gsub("[%-_%s]", ""):lower())
end

-- aceita / \ e . como separadores
local function normalize_sep(text)
  return (text:gsub("[\\%.]", "/"))
end

-- "Tenant/App/Home/Novo" -> { "Tenant", "App", "Home", "Novo" }
local function parse(text)
  text = normalize_sep(vim.trim(text))
  if text:match("/$") then
    return nil, "falta o nome do componente depois da última pasta"
  end

  local segs = {}
  for seg in text:gmatch("[^/]+") do
    local s = studly(seg)
    if not s:match("^[%a_][%w_]*$") then
      return nil, ("nome inválido: '%s'"):format(seg)
    end
    segs[#segs + 1] = s
  end
  if #segs == 0 then
    return nil, "nome vazio"
  end
  return segs
end

---------------------------------------------------------------------------
-- Autocomplete: pastas existentes em app/Livewire, nível por nível
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

-- resolve "tenant/app/" para "Tenant/App/" usando as pastas reais (ignora caixa)
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

local function completer(root)
  local base = root .. "/" .. M.class_dir

  return function(text)
    text = normalize_sep(text)
    local dirpart, prefix = text:match("^(.*/)(.*)$")
    if not dirpart then
      dirpart, prefix = "", text
    end

    local real, dir = resolve_dirs(base, dirpart)
    if not real then
      return {}
    end

    local items, want = {}, norm(prefix)
    for _, name in ipairs(subdirs(dir)) do
      if norm(name):sub(1, #want) == want then
        items[#items + 1] = { word = real .. name .. "/" }
      end
    end
    return items
  end
end

---------------------------------------------------------------------------
-- Templates (edite à vontade)
---------------------------------------------------------------------------
function M.class_template(ns, name, view_name)
  return {
    "<?php",
    "",
    "namespace " .. ns .. ";",
    "",
    "use Illuminate\\Contracts\\View\\View;",
    "use Livewire\\Component;",
    "",
    "class " .. name .. " extends Component",
    "{",
    "    public function render(): View",
    "    {",
    "        return view('" .. view_name .. "');",
    "    }",
    "}",
  }
end

function M.view_template()
  return {
    "<div>",
    "    ",
    "</div>",
  }
end

---------------------------------------------------------------------------
-- Criação
---------------------------------------------------------------------------
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function open_files(class_path, view_path)
  if M.open == "none" then
    return
  end
  vim.cmd("normal! m'")
  if M.open == "both" then
    -- um buffer para cada, na mesma janela: abre a view primeiro e termina na classe
    -- (a view fica como buffer alternativo: <C-^> ou <leader>bb alterna entre os dois)
    vim.cmd("edit " .. vim.fn.fnameescape(view_path))
    vim.cmd("edit " .. vim.fn.fnameescape(class_path))
  elseif M.open == "split" then
    vim.cmd("edit " .. vim.fn.fnameescape(class_path))
    vim.cmd("rightbelow vsplit " .. vim.fn.fnameescape(view_path))
    vim.cmd("wincmd p") -- foco volta para a classe
  else
    vim.cmd("edit " .. vim.fn.fnameescape(class_path))
  end
end

local function make(root, segs)
  local name = segs[#segs]
  local dirs = vim.list_slice(segs, 1, #segs - 1)

  local view_segs = {}
  for i, s in ipairs(segs) do
    view_segs[i] = kebab(s)
  end

  local ns = M.namespace
  if #dirs > 0 then
    ns = ns .. "\\" .. table.concat(dirs, "\\")
  end

  local class_path =
    table.concat(vim.list_extend({ root, M.class_dir }, vim.list_extend(vim.deepcopy(dirs), { name .. ".php" })), "/")
  local view_path = ("%s/%s/%s.blade.php"):format(root, M.view_dir, table.concat(view_segs, "/"))
  local view_name = "livewire." .. table.concat(view_segs, ".")

  local created = {}

  if vim.fn.filereadable(class_path) == 1 then
    warn("já existe, não sobrescrevi: " .. vim.fn.fnamemodify(class_path, ":."))
  else
    write(class_path, M.class_template(ns, name, view_name))
    created[#created + 1] = vim.fn.fnamemodify(class_path, ":.")
  end

  if vim.fn.filereadable(view_path) == 1 then
    warn("já existe, não sobrescrevi: " .. vim.fn.fnamemodify(view_path, ":."))
  else
    write(view_path, M.view_template())
    created[#created + 1] = vim.fn.fnamemodify(view_path, ":.")
  end

  if #created > 0 then
    info("criado: " .. table.concat(created, "  +  "))
  end
  open_files(class_path, view_path)
end

-- sugestão inicial: pasta do arquivo atual (classe em app/Livewire ou view em livewire/)
local function current_default(root)
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(0))

  local cdir = vim.fs.normalize(root .. "/" .. M.class_dir) .. "/"
  if file:sub(1, #cdir) == cdir then
    local d = vim.fs.dirname(file:sub(#cdir + 1))
    return d == "." and "" or (d .. "/")
  end

  local vdir = vim.fs.normalize(root .. "/" .. M.view_dir) .. "/"
  if file:sub(1, #vdir) == vdir then
    local d = vim.fs.dirname(file:sub(#vdir + 1))
    if d == "." then
      return ""
    end
    local out = {}
    for seg in d:gmatch("[^/]+") do
      out[#out + 1] = studly(seg)
    end
    return table.concat(out, "/") .. "/"
  end

  return ""
end

---------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------
-- default (opcional): texto inicial do input, ex.: "Tenant/App/"
function M.create(default)
  local root = lang.ui.find_root()
  if vim.fn.isdirectory(root .. "/" .. M.class_dir) == 0 and vim.fn.filereadable(root .. "/artisan") == 0 then
    return warn("não parece um projeto Laravel (sem artisan nem " .. M.class_dir .. ")")
  end

  lang.ui.input({
    title = "Novo componente Livewire",
    footer = "Tenant/App/Home/Nome  ·  <Tab> navega · <CR> aceita/cria · <Esc> cancela",
    default = default or current_default(root),
    complete = completer(root),
  }, function(v)
    if v == nil then
      return
    end
    if vim.trim(v) == "" then
      return
    end
    local segs, err = parse(v)
    if not segs then
      return warn(err)
    end
    make(root, segs)
  end)
end

return M
