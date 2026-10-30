# laravel.nvim

A pure-Lua Neovim toolkit for Laravel projects, built to feel at home in [LazyVim](https://www.lazyvim.org). No extra daemon and no required plugin dependencies: everything goes through `artisan` (Sail-aware) or plain file parsing in Lua.

- **Translations**: turn any string into `__('key')`, jump from a key to its translation, find where a key is used, and get key completion while typing.
- **Route navigation**: `gd` on `route('name')` jumps to the definition in `routes/*.php`, even for names built by route groups.
- **`make:*` wizard**: create jobs, models, controllers, listeners and 30 other types with folder autocompletion, option prompts and automatic opening of the generated files.
- **Livewire**: create the component class and its Blade view in one step.
- **PHP class moving**: move classes between project directories with PSR-4 namespace resolution, destination preview and confirmation.
- **View / config / env navigation**: `gd` on `view('x')`, `@include`, `config('a.b')`, `env('X')`.
- **Artisan, Composer and Sail**: commands with completion, a migrations menu, tinker, tests, Sail status/up/down.

> [!IMPORTANT]
> **LazyVim users:** LazyVim maps `<leader>l` to `:Lazy`. laravel.nvim uses `<leader>l` as its prefix, so by default it **moves Lazy to `<leader>L`** automatically (replacing LazyVim's own `<leader>L` changelog mapping). Opt out with `keymaps = { move_lazy = false }` or pick another prefix. Details in [Installation](#lazyvim-lazy-moves-to-leaderl).

## Requirements

- Neovim **>= 0.10** (uses `vim.system`, `vim.fs.root`, `vim.ui.open`)
- A Laravel project (`artisan` in the root)
- Optional:
  - [ripgrep](https://github.com/BurntSushi/ripgrep) for finding translation usages (falls back to `grep`)
  - [which-key.nvim](https://github.com/folke/which-key.nvim) for group names and icons
  - [snacks.nvim](https://github.com/folke/snacks.nvim) for pickers and for hooking into LazyVim's `gd`
  - Docker + [Laravel Sail](https://laravel.com/docs/sail) if you develop in containers
  - [blade-nav.nvim](https://github.com/RicardoRamirezR/blade-nav.nvim), strongly recommended for Livewire and Blade components (see [below](#recommended-companion-blade-navnvim))
  - `phpantom_lsp` for moving PHP classes. The move feature requires the executable to be available in your system's `PATH`.

## Installation

### LazyVim / lazy.nvim

```lua
-- lua/plugins/laravel.lua
return {
  "tiagoliveira555/laravel.nvim",
  main = "laravel_tools",
  event = "VeryLazy",
  opts = {},
}
```

#### LazyVim: Lazy moves to `<leader>L`

LazyVim maps `<leader>l` to `:Lazy`. That would make `<leader>l` both a command and a prefix, so the Laravel group would hang on `timeoutlen`. To avoid it, **laravel.nvim moves Lazy to `<leader>L` automatically** when it finds `<leader>l` mapped to Lazy, and shows it as "Lazy" in which-key.

- It only touches the mapping if it is actually Lazy. Anything else on `<leader>l` is left alone.
- LazyVim itself maps `<leader>L` to "LazyVim Changelog". Lazy takes that key over; set `changelog_key` to keep the changelog on another key.
- If `<leader>L` is taken by anything else, nothing is moved and you get a warning.
- Opt out, or choose where Lazy goes:

```lua
opts = {
  keymaps = {
    move_lazy = false,             -- do not touch Lazy
    -- lazy_key = "<leader>uL",     -- or move Lazy somewhere else
    -- changelog_key = "<leader>uC", -- keep LazyVim's changelog on another key
    -- prefix = "<leader>k",        -- or use another Laravel prefix and keep Lazy on <leader>l
  },
}
```

The repository is called `laravel.nvim`, but the Lua module is `laravel_tools`, which is why the spec sets `main`. This avoids clashing with the `laravel` module of other Laravel plugins if you have them installed.

Run `:checkhealth laravel_tools` to verify your setup.

## Configuration

All options with their defaults:

```lua
opts = {
  -- "auto": use Sail when vendor/bin/sail and a compose file exist
  -- true:   always use Sail
  -- false:  always use the host php/composer
  -- There is no silent fallback to the host when Sail fails.
  use_sail = "auto",

  -- Override the base artisan command, e.g.
  -- { "docker", "compose", "exec", "-T", "app", "php", "artisan" }
  artisan = nil,

  keymaps = {
    enabled = true,
    prefix = "<leader>l",
    translate = "gl", -- normal + visual mode; false to disable
    which_key = true, -- register group names/icons
    move_lazy = true, -- if the prefix is mapped to :Lazy (LazyVim), move Lazy to lazy_key
    lazy_key = "<leader>L", -- replaces LazyVim's <leader>L (changelog)
    changelog_key = nil, -- e.g. "<leader>uC" to keep LazyVim's changelog reachable
  },

  commands = {
    term_height = 15, -- height of the terminal split
    url = nil, -- app URL; default: APP_URL from .env, else http://localhost
    prefetch = true, -- load the artisan command list in the background (for completion)
  },

  routes = {
    cache_ttl = 300, -- seconds; saving a file in routes/ also refreshes
    timeout = 30000, -- ms for `route:list`
    map_gd = true, -- gd in PHP/Blade: route('x') -> Laravel, otherwise LSP
    prefetch = true,
  },

  make = {
    timeout = 30000,
    open_max = 4, -- open at most N created files (model + migration + factory...)
    flags = {}, -- extra flags per type, e.g. { test = { "--pest" } }
    extra_events = { "Illuminate\\Auth\\Events\\Registered", --[[ ... ]] },
    extra_types = {}, -- your own types, see "Custom make types"
  },

  livewire = {
    class_dir = "app/Livewire",
    view_dir = "resources/views/livewire",
    namespace = "App\\Livewire",
    open = "both", -- "both" | "split" | "class" | "none"
  },

  lang = {
    debug = false, -- show warnings/errors
    custom_input = true, -- own input window with autocomplete; false = vim.ui.input
    open_after_create = true, -- open the translation file after creating a key
    usages_ui = "select", -- "select" | "quickfix"
    echo = true, -- short messages in the command line
    key_assist = true, -- key completion inside __('...') in insert mode
  },

  navigate = {
    -- folder pickers; entries are merged with the defaults
    -- dirs = { actions = { "app/Actions", "Actions" } },
  },
}
```

## Default keymaps

With the default prefix `<leader>l`:

| Key | Mode | Action |
| --- | --- | --- |
| `gl` | n, x | Translations (see below) |
| `<leader>ln` | n | Create anything (`make:*` wizard) |
| `<leader>ll` | n | New Livewire component |
| `<leader>lA` / `lj` / `lL` | n | New Action / Job / Listener |
| `<leader>lg` | n | Go to the action (controller/Livewire) of the `route('x')` under the cursor |
| `<leader>lp` | n | Pick from all named routes |
| `<leader>lR` | n | Move the current PHP class |
| `<leader>lc` `lm` `lv` `lr` `lw` | n | Find files in controllers / models / views / routes / Livewire |
| `<leader>la` | n | Artisan picker |
| `<leader>lC` | n | Composer picker |
| `<leader>lM` | n | Migrations menu |
| `<leader>lt` / `lT` | n | `artisan test` / tinker |
| `<leader>ls` + `u d r s h l o` | n | Sail up / down / restart / status / shell / logs / open app |
| `<leader>L` | n | Lazy (moved from `<leader>l` when `move_lazy` is on) |

`gd` is also extended in PHP and Blade files, see [Go to definition](#go-to-definition).

## Features

### Translations

`gl` does the right thing depending on where the cursor is:

| Cursor on | Result |
| --- | --- |
| A string literal (`'Save'`) | Replaced by `__('key')`. If the text already exists in the default locale it is reused (you choose if there are several); otherwise you type the key (with path autocomplete) and the translation, which is written to the lang file. |
| `__('key')` | Jumps to the translation. If it exists in several locales you pick the file. If it does not exist, it is created in the default locale, pre-filled from the key and from the `:placeholder` props found in the call. |
| Inside a lang file | Finds where the key is used (ripgrep). One hit jumps straight to it, several open a picker or the quickfix list. |
| A visual selection | The selected text becomes `__('key')`. In Blade, loose text becomes `{{ __('key') }}` and component attributes become `:attr="__('key')"`. |

Details:

- Keys like `tenant/app.events.joined` map to `lang/<locale>/tenant/app.php` (nested arrays, alignment of `=>` is preserved). Keys without a group, or containing spaces, go to `lang/<locale>.json`.
- The default locale comes from `APP_LOCALE` in `.env`, then `config/app.php`.
- Lang files are parsed in Lua, so PHP does not have to be installed.
- In insert mode, inside `__('...')`, `trans()`, `trans_choice()`, `Lang::get()` and `@lang()`, a floating list suggests keys level by level (folder, file, array). `<Tab>`/`<S-Tab>` move, `<CR>` accepts. Other completion sources are paused inside the key (blink.cmp and nvim-cmp).

### Go to definition

In PHP and Blade, `gd` first checks what is under the cursor and falls back to your LSP otherwise:

| Under the cursor | Goes to |
| --- | --- |
| `route('name')`, `to_route`, `Route::has`, `routeIs`, `signedRoute`... | The `->name('...')` definition in `routes/**/*.php` |
| `view('x')`, `View::make`, `Route::view`, `markdown`, `@include`, `@extends` | The Blade file (offers to create it if it does not exist) |
| `config('app.name')` | `config/app.php`, on the `name` line |
| `env('X')` | `.env` (or `.env.example`) |

Route names produced by groups (`->name('tenant.')`) are resolved by searching the full name and then progressively shorter suffixes, narrowing by controller/method when there are several matches. Routes are read from `artisan route:list --json`, cached, and refreshed in the background whenever you save a file in `routes/`. If the name is not in the cache, `route:list` is reloaded once automatically (covers routes added outside `routes/`). If it still does not exist, you get a picker with similar names (for example `tenant.home` for `home`) or a message saying how many named routes were loaded.

Use `<leader>lg` to jump to the controller method or Livewire component instead of the route definition.

Package views (`vendor::view`) are not supported yet.

### `make:*` wizard

`<leader>ln` opens a list of types. You then type a name in a small floating window that autocompletes existing folders (case and hyphen insensitive) and starts in the folder of the file you are editing. Some types ask follow-up questions:

- **Model**: just the model, `-m`, `-mf` or `--all`
- **Controller**: plain, invokable, resource, API
- **Job**: queued or `--sync`
- **Listener**: which event (existing ones in `app/Events`, common framework events, or any class), queued or not
- **Policy / Observer / Factory**: which model

`Esc` at any step cancels everything; nothing is created. Generated files are opened for you (up to `open_max`).

Types: Action, Job, Listener, Event, Notification, Mailable, Model, Migration, Controller, Form Request, API Resource, Policy, Observer, Rule, Middleware, Console Command, Blade Component, Seeder, Factory, Feature/Unit Test, Exception, Cast, Scope, Service Provider, Broadcast Channel, Enum, Interface and Trait.

Everything runs through `artisan` (via Sail when available), so your customised stubs and your Laravel version are respected. The exception is **Action**, which artisan does not have: the file is written directly using the `AsAction` trait from [lorisleiva/laravel-actions](https://github.com/lorisleiva/laravel-actions).

#### Custom make types

```lua
opts = {
  make = {
    extra_types = {
      -- uses an artisan command from a package
      { id = "livewire_form", label = "Livewire Form", dir = "app/Livewire/Forms", cmd = "livewire:form" },
      -- or writes a file directly
      {
        id = "dto",
        label = "DTO",
        dir = "app/DTOs",
        template = function(namespace, name)
          return { "<?php", "", "namespace " .. namespace .. ";", "", "final class " .. name, "{", "}" }
        end,
      },
    },
  },
}
```

### Livewire

`<leader>ll` creates `app/Livewire/<Path>/<Name>.php` and `resources/views/livewire/<path>/<name>.blade.php` together, with the same folder autocompletion. Existing files are never overwritten. Override `class_template` / `view_template` to change what gets written:

```lua
opts = {
  livewire = {
    view_template = function()
      return { "<div>", "    {{-- --}}", "</div>" }
    end,
  },
}
```

### Move PHP classes

`<leader>lR` moves the PHP class in the current buffer to another directory in your Laravel project.

The feature uses [`phpantom_lsp`](https://github.com/phpantom) to perform the move and resolve class references. The executable must be installed and available in your system's `PATH`.

How it works:

1. Open the PHP class you want to move.
2. Press `<leader>lR`.
3. Choose the destination directory using the folder input and its autocomplete.
4. Review the source and destination paths and the class names.
5. Confirm the operation or cancel it.

The destination namespace is determined from the project's `composer.json` PSR-4 mappings. Both `autoload` and `autoload-dev` mappings are considered, so the feature can work with classes in application code and development-only directories when those directories are configured.

Before executing the move, the plugin validates the source file, destination directory, namespace mapping and target path. It checks the proposed move with `phpantom_lsp` in dry-run mode and asks for confirmation before proceeding.

**Requirements and notes:**

- `phpantom_lsp` must be executable from Neovim's environment.
- The project must contain a valid `composer.json` with a matching PSR-4 mapping for the destination.
- The destination directory must already exist inside the project.
- The destination file must not already exist.
- Save the current PHP file before starting the operation.

You can also invoke the feature from Lua:

```lua
require("laravel_tools.move").move()
```

### Artisan, Composer and Sail

| Command | Description |
| --- | --- |
| `:Artisan [args]` | Runs artisan in a terminal split. Command names are completed from `artisan list --format=json`. Without arguments it opens a picker. |
| `:Composer [args]` | Same for composer. |
| `:Sail [args]` | Laravel Sail. Without arguments it opens a picker. |
| `:RoutesRefresh` | Reloads the route cache. |

In `auto` mode Sail is used only when `vendor/bin/sail` and a compose file are present. If Sail is installed but stopped, commands fail visibly (use `<leader>lsu`); they never silently run on the host.

## Recommended companion: blade-nav.nvim

For the best Livewire and Blade experience, install [blade-nav.nvim](https://github.com/RicardoRamirezR/blade-nav.nvim) alongside this plugin. The two cover different ground and do not overlap on keys:

| | Plugin | Key |
| --- | --- | --- |
| **Create** a Livewire component (class + view) | laravel.nvim | `<leader>ll` |
| `gd` on `route()`, `view()`, `config()`, `env()` and `make:*` wizard | laravel.nvim | `gd`, `<leader>ln` |
| Jump from a component tag to its file: `<x-button>`, `<livewire:counter />`, `@livewire('counter')`, `@include`, `@extends` | blade-nav.nvim | `gf` |
| Completion for Blade and Livewire components | blade-nav.nvim | in the completion menu (nvim-cmp, blink.cmp, coq) |

laravel.nvim creates the Livewire component and blade-nav.nvim takes you between the component tag in your Blade view and its class. Together they cover the full create, navigate and complete loop.

```lua
-- lua/plugins/blade-nav.lua
return {
  "RicardoRamirezR/blade-nav.nvim",
  ft = { "blade", "php" },
  opts = {},
}
```

Notes:

- blade-nav.nvim 2.x requires nvim-treesitter with the `php` and `html` parsers. Check its README for its current spec and options.
- With blink.cmp, blade-nav.nvim 2.x registers itself as a completion source. If you added a manual `blade-nav` provider to your blink config for an older version, check its README before keeping it.
- Run `:checkhealth blade-nav` and `:checkhealth laravel_tools` if something does not work.

## Lua API

Every feature is available without keymaps:

```lua
require("laravel_tools.make").create("job")
require("laravel_tools.livewire").create("Admin/")
require("laravel_tools.move").move()
require("laravel_tools.routes").goto_route("definition") -- or "action"
require("laravel_tools.routes").pick()
require("laravel_tools.lang").add()          -- translate/navigate under the cursor
require("laravel_tools.navigate").pick("models")
require("laravel_tools.commands").run_artisan({ "migrate" })
```

Set `keymaps = { enabled = false }` and map what you want.

## Troubleshooting

- **The Laravel group waits before opening**: `<leader>l` is still mapped to something else. If it is Lazy, leave `move_lazy` on. If it is another mapping, remove it or set `keymaps.prefix`.
- **`artisan list` / `route:list` fail silently**: the background prefetch is silent on purpose. Run `:Artisan list` or `:RoutesRefresh` to see the error. With Sail, make sure the containers are up.
- **Moving a PHP class fails**: verify that `phpantom_lsp` is installed and available in `PATH`, the destination directory exists, and `composer.json` contains a matching PSR-4 mapping.
- **No translation usages found**: install ripgrep and check that the key is written in single or double quotes.
- Anything else: `:checkhealth laravel_tools`.

## Contributing

Issues and pull requests are welcome. To hack on the plugin locally:

```lua
{ dir = "~/projects/laravel.nvim", main = "laravel_tools", event = "VeryLazy", opts = {} }
```

Code style is enforced with [StyLua](https://github.com/JohnnyMorganz/StyLua) (`stylua.toml` is included).

Layout:

```text
lua/laravel_tools/
  init.lua       setup(opts) and defaults
  keymaps.lua    default keymaps
  commands.lua   artisan / composer / sail / tinker / tests
  routes.lua     route() navigation
  navigate.lua   view() / config() / env() navigation and folder pickers
  make.lua       make:* wizard
  livewire.lua   Livewire creator
  move.lua       PHP class moving
  lang.lua       translations and the floating input UI
  health.lua     :checkhealth
```

## Roadmap

- Translate user-facing messages (currently Portuguese) and make them overridable
- Support package views (`vendor::view`)
- Optional Pest/PHPUnit test runner for the current file or method

## License

[MIT](LICENSE)
