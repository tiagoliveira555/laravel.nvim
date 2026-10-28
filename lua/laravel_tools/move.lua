local lang = require("laravel_tools.lang")

local M = {}

M.command = "phpantom_lsp"
M.timeout = 30000

---------------------------------------------------------------------------
-- Utilitários
---------------------------------------------------------------------------

local function notify(message, level)
  vim.notify("[laravel.nvim] " .. message, level or vim.log.levels.INFO)
end

local function normalize(path)
  return vim.fs.normalize(path)
end

local function relative_path(path, root)
  path = normalize(path)
  root = normalize(root)

  if path == root then
    return "."
  end

  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
end

local function is_inside(path, root)
  return relative_path(path, root) ~= nil
end

local function display_path(path, root)
  return relative_path(path, root) or path
end

local function read_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  return table.concat(vim.fn.readfile(path), "\n")
end

---------------------------------------------------------------------------
-- Composer / PSR-4
---------------------------------------------------------------------------

local function read_composer(root)
  local path = root .. "/composer.json"
  local content = read_file(path)

  if not content then
    return nil, "composer.json não encontrado."
  end

  local ok, composer = pcall(vim.json.decode, content)

  if not ok or type(composer) ~= "table" then
    return nil, "não foi possível interpretar o composer.json."
  end

  local mappings = {}

  for _, section in ipairs({ "autoload", "autoload-dev" }) do
    local psr4 = composer[section] and composer[section]["psr-4"] or {}

    for namespace, directories in pairs(psr4) do
      if type(directories) == "string" then
        directories = { directories }
      end

      if type(directories) == "table" then
        for _, directory in ipairs(directories) do
          if type(directory) == "string" then
            mappings[#mappings + 1] = {
              namespace = namespace:gsub("\\+$", ""),
              directory = normalize(root .. "/" .. directory),
            }
          end
        end
      end
    end
  end

  -- Prefixos mais específicos devem ser avaliados primeiro.
  table.sort(mappings, function(a, b)
    if #a.namespace ~= #b.namespace then
      return #a.namespace > #b.namespace
    end

    return #a.directory > #b.directory
  end)

  return mappings
end

local function namespace_for_directory(directory, root, mappings)
  directory = normalize(directory)

  for _, mapping in ipairs(mappings) do
    if is_inside(directory, mapping.directory) or directory == mapping.directory then
      local relative = relative_path(directory, mapping.directory)
      local suffix = relative == "." and "" or relative:gsub("/", "\\")

      if suffix == "" then
        return mapping.namespace
      end

      if mapping.namespace == "" then
        return suffix
      end

      return mapping.namespace .. "\\" .. suffix
    end
  end

  return nil
end

local function source_fqcn(source)
  local content = read_file(source)

  if not content then
    return nil, "não foi possível ler o arquivo de origem."
  end

  local namespace = content:match("%f[%w_]namespace%s+([%w_\\]+)%s*;")

  if not namespace then
    return nil, "não foi encontrada uma declaração de namespace no arquivo."
  end

  local class_name = vim.fn.fnamemodify(source, ":t:r")

  if not class_name:match("^[%a_][%w_]*$") then
    return nil, "o nome do arquivo não corresponde a um nome de classe PHP válido."
  end

  return namespace .. "\\" .. class_name
end

local function target_fqcn(destination, source, root, mappings)
  local namespace = namespace_for_directory(destination, root, mappings)

  if not namespace then
    return nil, "a pasta de destino não corresponde a nenhum mapeamento PSR-4 do composer.json."
  end

  local class_name = vim.fn.fnamemodify(source, ":t:r")

  if namespace == "" then
    return class_name
  end

  return namespace .. "\\" .. class_name
end

---------------------------------------------------------------------------
-- Autocomplete de diretórios
---------------------------------------------------------------------------

local function subdirs(path)
  local items = {}

  if vim.fn.isdirectory(path) ~= 1 then
    return items
  end

  for _, name in ipairs(vim.fn.readdir(path)) do
    if vim.fn.isdirectory(path .. "/" .. name) == 1 then
      items[#items + 1] = name
    end
  end

  table.sort(items)

  return items
end

local function norm_name(name)
  return (name:gsub("[%-_%s]", ""):lower())
end

local function resolve_dirs(root, dirpart)
  local current = root
  local resolved = ""

  for segment in dirpart:gmatch("[^/]+") do
    local found

    for _, name in ipairs(subdirs(current)) do
      if norm_name(name) == norm_name(segment) then
        found = name
        break
      end
    end

    if not found then
      return nil
    end

    current = current .. "/" .. found
    resolved = resolved .. found .. "/"
  end

  return resolved, current
end

local function completer(root)
  return function(text)
    text = (text or ""):gsub("\\", "/")

    local dirpart, prefix = text:match("^(.*/)(.*)$")

    if not dirpart then
      dirpart, prefix = "", text
    end

    local resolved, directory = resolve_dirs(root, dirpart)

    if not resolved then
      return {}
    end

    local items = {}
    local wanted = norm_name(prefix)

    for _, name in ipairs(subdirs(directory)) do
      if norm_name(name):sub(1, #wanted) == wanted then
        items[#items + 1] = {
          word = resolved .. name .. "/",
        }
      end
    end

    return items
  end
end

local function current_default(root, source)
  local relative = relative_path(source, root)

  if not relative then
    return ""
  end

  local directory = vim.fs.dirname(relative)

  return directory == "." and "" or (directory .. "/")
end

---------------------------------------------------------------------------
-- Execução do PHPantom
---------------------------------------------------------------------------

local function run_phpantom(root, source_fqcn, target_fqcn, dry_run, callback)
  local command = { M.command, "move" }

  if dry_run then
    command[#command + 1] = "--dry-run"
  end

  vim.list_extend(command, {
    "--project-root",
    root,
    source_fqcn,
    target_fqcn,
  })

  local ok, process = pcall(vim.system, command, {
    cwd = root,
    text = true,
    timeout = M.timeout,
  }, vim.schedule_wrap(callback))

  if not ok then
    notify("não foi possível executar " .. M.command .. ": " .. tostring(process), vim.log.levels.ERROR)
  end
end

local function output_of(result)
  local stdout = vim.trim(result.stdout or "")
  local stderr = vim.trim(result.stderr or "")

  if stdout ~= "" and stderr ~= "" then
    return stdout .. "\n" .. stderr
  end

  return stdout ~= "" and stdout or stderr
end

local function show_failure(action, result)
  local output = output_of(result)

  notify(
    action .. " falhou (código " .. tostring(result.code) .. ")." .. (output ~= "" and "\n" .. output or ""),
    vim.log.levels.ERROR
  )
end

---------------------------------------------------------------------------
-- Confirmação
---------------------------------------------------------------------------

local function confirm_move(root, source, target, source_fqcn, target_fqcn)
  run_phpantom(root, source_fqcn, target_fqcn, true, function(preview)
    if preview.code ~= 0 then
      return show_failure("A prévia da movimentação", preview)
    end

    local preview_output = output_of(preview)

    if preview_output == "" then
      preview_output = "O PHPantom não retornou detalhes para a prévia."
    end

    local choices = {
      {
        label = "Confirmar movimentação",
        value = "confirm",
      },
      {
        label = "Cancelar",
        value = "cancel",
      },
    }

    vim.ui.select(choices, {
      prompt = "Mover classe PHP?",
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice or choice.value ~= "confirm" then
        return
      end

      -- Revalida a prévia antes de efetuar a operação.
      run_phpantom(root, source_fqcn, target_fqcn, true, function(recheck)
        if recheck.code ~= 0 then
          return show_failure("A validação da movimentação", recheck)
        end

        run_phpantom(root, source_fqcn, target_fqcn, false, function(result)
          if result.code ~= 0 then
            return show_failure("A movimentação", result)
          end

          notify(
            "movimentação concluída:\n"
              .. source_fqcn
              .. "\n→ "
              .. target_fqcn
              .. "\n"
              .. (output_of(result) ~= "" and output_of(result) or "PHPantom concluiu a operação.")
          )

          -- Abre o arquivo no novo local.
          vim.cmd("edit " .. vim.fn.fnameescape(target))
        end)
      end)
    end)
  end)
end

---------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------

function M.move()
  local source = normalize(vim.api.nvim_buf_get_name(0))

  if source == "" or vim.fn.filereadable(source) ~= 1 then
    return notify("o buffer atual não corresponde a um arquivo existente.", vim.log.levels.WARN)
  end

  if not source:match("%.php$") then
    return notify("o arquivo atual não é PHP.", vim.log.levels.WARN)
  end

  if vim.bo.modified then
    return notify("salve o arquivo antes de movê-lo.", vim.log.levels.WARN)
  end

  local root = lang.ui.find_root()

  if not root or root == "" then
    return notify("não foi possível localizar a raiz do projeto.", vim.log.levels.ERROR)
  end

  root = normalize(root)

  if not is_inside(source, root) then
    return notify("o arquivo está fora da raiz do projeto.", vim.log.levels.WARN)
  end

  if vim.fn.executable(M.command) ~= 1 then
    return notify("'" .. M.command .. "' não foi encontrado no PATH.", vim.log.levels.ERROR)
  end

  local mappings, composer_error = read_composer(root)

  if not mappings then
    return notify(composer_error, vim.log.levels.ERROR)
  end

  local source_class, source_error = source_fqcn(source)

  if not source_class then
    return notify(source_error, vim.log.levels.ERROR)
  end

  lang.ui.input({
    title = "Mover classe PHP",
    footer = "<Tab> navega · <CR> seleciona/confirma · <Esc> cancela",
    default = current_default(root, source),
    complete = completer(root),
  }, function(input)
    if input == nil then
      return
    end

    input = vim.trim(input):gsub("\\", "/"):gsub("/+$", "")

    if input == "" then
      return notify("informe a pasta de destino.", vim.log.levels.WARN)
    end

    if input:sub(1, 1) == "/" or input:match("^%a:") then
      return notify("informe um caminho relativo à raiz do projeto.", vim.log.levels.WARN)
    end

    local destination = normalize(root .. "/" .. input)

    if not is_inside(destination, root) then
      return notify("a pasta de destino está fora do projeto.", vim.log.levels.WARN)
    end

    if vim.fn.isdirectory(destination) ~= 1 then
      return notify("a pasta de destino não existe: " .. input, vim.log.levels.WARN)
    end

    if normalize(vim.fs.dirname(source)) == destination then
      return notify("o arquivo já está nessa pasta.", vim.log.levels.WARN)
    end

    local target = normalize(destination .. "/" .. vim.fs.basename(source))

    if vim.fn.filereadable(target) == 1 or vim.fn.isdirectory(target) == 1 then
      return notify(
        "já existe um arquivo ou diretório no destino: " .. display_path(target, root),
        vim.log.levels.ERROR
      )
    end

    local target_class, target_error = target_fqcn(destination, source, root, mappings)

    if not target_class then
      return notify(target_error, vim.log.levels.ERROR)
    end

    if source_class == target_class then
      return notify("o namespace e a classe de destino não mudariam.", vim.log.levels.WARN)
    end

    -- Mostra o resumo antes da confirmação para dar contexto à escolha.
    notify(
      "Prévia da movimentação:\n"
        .. display_path(source, root)
        .. "\n→ "
        .. display_path(target, root)
        .. "\n\n"
        .. source_class
        .. "\n→ "
        .. target_class
    )

    confirm_move(root, source, target, source_class, target_class)
  end)
end

return M
