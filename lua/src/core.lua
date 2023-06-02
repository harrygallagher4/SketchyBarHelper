--
-- This script is a TOTAL MESS. While writing it I was flip-flopping between
-- a simple interface to `sketchybar --<command>` commands and a pretty lua
-- interface for configuring sketchybar. I ended up deciding to implement both
-- which you can sort of see with `sb.item()`. It creates an item, sets
-- properties, creates events, subscribes to events, and registers callbacks
-- all at the same time. That was sort of the lua equivalent of "batching"
-- commands which is a pattern I've seen in a lot of people's sketchybar
-- configs and seems to be the "official" way to configure sketchybar.
--
-- I was also torn about whether or not to put serious effort into optimizing
-- performance so some functions sacrifice readability in order to minimize
-- table lookups and function calls. I'm open to discussion about this. The way
-- I see it, if I were to write my entire sketchybar config in lua I would want
-- everything to be as performant as possible.
--
-- This script is also designed to either be loaded by the C helper or run
-- directly by luajit in which case it will just dump sketchybar commands.
--

--
-- set up the environment if we're not being run by the helper
--
local sb = sketchybar or {}
local command = sb.command or function(str) print("sketchybar " .. str) end
local helper_name = sb.helper_name or "git.felix.helper"

local inspect = require("inspect")
local ffi = require("ffi")
ffi.cdef("int access(const char* path, int flags);")
local C = ffi.C
local F_OK, X_OK, W_OK, R_OK = 0, 1, 2, 4
local fmt = string.format
local callbacks = {{}}

local __value__ = setmetatable({}, { __tostring__ = "<value>" })
local __drop__ = setmetatable({}, { __tostring__ = "<drop>" })

--
-- all sketchybar commands
--
-- [x] add item <name> <position>
-- [x] add space <name> <position>
-- [x] add bracket <name> <member name>...
-- [x] add alias <application name> <position>
-- [x] add slider <name> <position> <width>
-- [x] add graph <name> <position> <width (points)>
-- [x] add event [<NSDistributedNotificationName>]
-- [x] bar <setting>=<value>
-- [x] clone <parent> <name> [before|after]
-- [x] default <property>=<value>
-- [x] set <name> <property>=<value>
-- [x] reorder <name>...
-- [x] move <name> before|after <name>
-- [x] rename <old name> <new name>
-- [x] remove <name>
-- [x] push <name> <data point>...
-- [x] subscribe <name> <event>...
-- [x] trigger <event> [<varname>=<value> ...]
-- [ ] animate <linear|quadratic|tanh|sin|exp|circ>
--             <duration>
--             [--bar <property>=<value>...]
--             [--set <property>=<value>...]



--
-- Callback management
--

local function dispatch_calls(fns, ...)
  if fns == nil or #fns == 0 then return end
  for _, fn in ipairs(fns) do
    fn(...)
  end
end

local function nested_get(tbl, ...)
  local value = tbl
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    value = value[key]
    if value == nil then
      return nil
    end
  end
  return value
end

local function nested_get_ensure(tbl, ...)
  local value = tbl
  for i = 1, select("#", ...) do
    local arg = select(i, ...)
    local v = value[arg]
    if v == nil then
      v = {}
      value[arg] = v
    end
    value = v
  end
  return value
end

local function register_callback_global(fn)
  local global_callbacks = nested_get_ensure(callbacks, 1)
  table.insert(global_callbacks, fn)
end
local function register_callback_item(item, fn)
  local item_callbacks = nested_get_ensure(callbacks, item, 1)
  table.insert(item_callbacks, fn)
end
local function register_callback_item_event(item, event, fn)
  local item_event_callbacks = nested_get_ensure(callbacks, item, event)
  table.insert(item_event_callbacks, fn)
end

-- Registers a callback for either:
-- - all events
-- - all events passed to a specific item
-- - a specific event passed to a specific item
--
-- Uses `register_callback_global`, `register_callback_item`, and
-- `register_callback_item_event` under the hood
--
-- ```
-- -- Register a callback that will receive all events on all items
-- sb.register_callback(
--   function(item, event, env) end
-- )
-- -- Register a callback that will receive all events on a specific item
-- sb.register_callback(
--   "item_name",
--   function(item, event, env) end
-- )
-- -- Register a callback that will receive a specific event on a specific item
-- sb.register_callback(
--   "item_name",
--   "front_app_switched",
--   function(item, event, env) end
-- )
-- ```
function sb.register_callback(...)
  local nargs = select("#", ...)
  if nargs == 1 then
    return register_callback_global(...)
  elseif nargs == 2 then
    return register_callback_item(...)
  elseif nargs == 3 then
    return register_callback_item_event(...)
  end
end


--
-- Functions for serializing lua tables into domain.key=value form
--
--
-- `key_aliases` are keys that need special handling *after* being serialized
--
-- `special_keys` are top-level keys that need special handling *before* the
-- config is serialized because many of the lua-specific config functions
-- combine multiple "stages" of a `sketchybar` command. For instance, `sb.item`
-- uses the `position` key which is passed to `sketchybar --add` while
-- non-special keys are all passed to `sketchybar --set`
--
-- *.padding.left => *.padding_left
-- *.padding.right => *.padding_right
-- *.highlight.color => *.highlight_color
-- *.border.color => *.border_color
-- *.border.width => *.border_width
local key_aliases = {
  ["position"] = __drop__,
  ["padding.left"] = "padding_left",
  ["padding.right"] = "padding_right",
  ["label.padding.left"] = "label.padding_left",
  ["label.padding.right"] = "label.padding_right",
  ["label.highlight.color"] = "label.highlight_color",
  ["icon.padding.left"] = "icon.padding_left",
  ["icon.padding.right"] = "icon.padding_right",
  ["icon.highlight.color"] = "icon.highlight_color",
  ["label.background.padding.left"] = "label.background.padding_left",
  ["label.background.padding.right"] = "label.background.padding_right",
  ["label.background.border.color"] = "label.background.border_color",
  ["label.background.border.width"] = "label.background.border_width",
  ["icon.background.padding.left"] = "icon.background.padding_left",
  ["icon.background.padding.right"] = "icon.background.padding_right",
  ["icon.background.border.color"] = "icon.background.border_color",
  ["icon.background.border.width"] = "icon.background.border_width"
}
local special_keys = {
  ["position"] = true,
  ["subscribe"] = true,
  ["events"] = true,
  ["members"] = true,
  ["width"] = true
}
local event_aliases = {
  ["mouse_entered"] = "mouse.entered",
  ["mouse_exited"] = "mouse.exited",
  ["mouse_clicked"] = "mouse.clicked",
  ["mouse_entered_global"] = "mouse.entered.global",
  ["mouse_exited_global"] = "mouse.exited.global",
}
local function event_name(name)
  local alias = event_aliases[name]
  return alias or name
end

local function table_not_empty(tbl)
  if type(tbl) ~= "table" then return false end
  for k in pairs(tbl) do
    return true
  end
  return false
end

-- the inspect library can properly quote strings that contain "" or ''
local sanitize_value = inspect

local function insert_kv(t, k, v)
  if k == nil then return end
  local alias = key_aliases[k] or k
  if alias ~= __drop__ then
    table.insert(t, alias .. "=" .. sanitize_value(v))
  end
end

local function serialize_keys(tbl, acc, s)
  if type(tbl) ~= "table" then
    insert_kv(acc, s, tbl)
  else
    local prefix = (s ~= nil) and (s .. ".") or ""
    for k, v in pairs(tbl) do
      if k == __value__ or k == 1 then
        insert_kv(acc, s, v)
      else
        serialize_keys(v, acc, prefix .. k)
      end
    end
  end
  return acc
end

local function preprocess_config(tbl)
  local specials = {}
  for k, v in pairs(tbl) do
    if special_keys[k] then
      specials[k] = v
      tbl[k] = nil
    end
  end
  return tbl, specials
end

local function serialize_config(tbl, extra)
  local tail = extra ~= nil and (" " .. extra) or ""
  if table_not_empty(tbl) then
    local config, specials = preprocess_config(tbl)
    local args = serialize_keys(config, {})
    if #args == 0 and extra ~= nil then
      return string.sub(tail, 2), specials
    else
      return table.concat(args, " ") .. tail, specials
    end
  elseif type(tbl) == "string" then
    return tbl .. tail, {}
  end
end

-- this is not a direct wrapper of `sketchybar --set` so it needs to be renamed
local function set_s(name, config, extra)
  local base = "--set %s %s"
  local config_arg, specials = serialize_config(config, extra)
  if config_arg == nil then
    return nil, specials
  end
  return fmt(base, name, config_arg), specials
end

--
-- Process a "callback spec" into a standard form. The other functions accept
-- subscriptions in a very flexible form and this function does all of the
-- heavy lifting to make that work.
--
local function process_subs(tbl)
  local tbl_t = type(tbl)
  if tbl_t == "string" then
    return { events = tbl }
  elseif tbl_t == "table" then
    local subs = { events = {}, event_callbacks = {}, global_callbacks = {} }
    for k, v in pairs(tbl) do
      local k_t = type(k)
      local v_t = type(v)
      if k_t == "number" then
        if v_t == "string" then
          table.insert(subs.events, event_name(v))
        elseif v_t == "table" then
          for _, e in ipairs(v) do
            table.insert(subs.events, event_name(e))
          end
        elseif v_t == "function" then
          table.insert(subs.global_callbacks, v)
        end
      elseif k_t == "string" then
        table.insert(subs.events, event_name(k))
        if v_t == "table" then
          for _, f in ipairs(v) do
            table.insert(subs.event_callbacks, {event_name(k), f})
          end
        else
          table.insert(subs.event_callbacks, {event_name(k), v})
        end
      end
    end

    subs.events = table.concat(subs.events, " ")
    return subs
  end
end

local function process_events(tbl)
  local tbl_t = type(tbl)
  if tbl_t == "string" then
    return tbl
  elseif tbl_t == "table" then
    local events = {}
    for _, v in ipairs(tbl) do
      local v_t = type(v)
      if v_t == "string" then
        table.insert(events, v)
      elseif v_t == "table" then
        table.insert(events, table.concat(v, " "))
      end
    end
    return table.concat(events, " ")
  end
end

local function remove_s(name)
  return fmt("--remove %s", name)
end

local function add_item_s(name, position)
  return fmt("--add item %s %s", name, position)
end

local function add_batch_s(item_type, name, item_config)
  local config, specials = set_s(name, item_config, "mach_helper=\"" .. helper_name .. "\"")
  local position = specials.position or "left"
  local subscribe, events = specials.subscribe, specials.events
  local cmd = fmt("--add %s %s %s %s", item_type, name, position, config)

  -- Add events if the item requires them
  if events ~= nil then
    local event_args = process_events(events)
    cmd = cmd .. " --add event " .. event_args
  end

  -- Subscribe to events
  if subscribe ~= nil then
    local subs = process_subs(subscribe)
    cmd = cmd .. " --subscribe " .. name .. " " .. subs.events
    for _, f in ipairs(subs.global_callbacks) do
      register_callback_item(name, f)
    end
    for _, t in ipairs(subs.event_callbacks) do
      register_callback_item_event(name, t[1], t[2])
    end
  end

  return cmd
end

function sb.item(name, item_config)
  return command(add_batch_s("item", name, item_config))
end

function sb.space(name, item_config)
  return command(add_batch_s("space", name, item_config))
end

local function add_space_s(name, position)
  return fmt("--add space %s %s", name, position)
end

local function add_bracket_s(name, ...)
  local members = { ... }
  return fmt("--add bracket %s %s", name, table.concat(members, " "))
end

local function add_alias_s(app_name, position)
  return fmt("--add alias %s %s", app_name, position)
end

local function add_slider_s(name, position, width)
  return fmt("--add slider %s %s %s", name, position, width)
end

local function add_graph_s(name, position, width)
  return fmt("--add graph %s %s %s", name, position, width)
end

local function add_event_s(name, ns_notification)
  if ns_notification == nil then
    return fmt("--add event %s", name)
  else
    return fmt("--add event %s %s", name, ns_notification)
  end
end

local function bar_s(config)
  local config_arg = serialize_config(config)
  if config_arg == nil then return end
  return fmt("--bar %s", config_arg)
end

local function clone_s(parent, name, position)
  if position ~= nil then
    fmt("--clone %s %s %s", parent, name, position)
  else
    fmt("--clone %s %s", parent, name)
  end
end

local function defaults_s(config)
  local config_arg = serialize_config(config)
  if config_arg == nil then return end
  return fmt("--default %s", config_arg)
end

local function reorder_s(...)
  local args = { ... }
  return fmt("--reorder", table.concat(args, " "))
end

local function rename_s(name, new_name)
  return fmt("--rename %s %s", name, new_name)
end

local function push_s(name, ...)
  local points = { ... }
  return fmt("--push %s %s", name, table.concat(points, " "))
end

local function trigger_s(event, env)
  local env_arg = serialize_config(env)
  if env_arg == nil then
    return fmt("--trigger %s", event)
  else
    return fmt("--trigger %s %s", event, table.concat(env_arg, " "))
  end
end


--
-- Actual sketchybar commands
--

function sb.set(name, config)
  local cmd, specials = set_s(name, config)
  return command(cmd)
end

function sb.remove(name)
  return command(remove_s(name))
end

function sb.add_item(name, position)
  return command(add_item_s(name, position))
end

function sb.add_space(name, position)
  return command(add_space_s(name, position))
end

function sb.add_bracket(name, ...)
  return command(add_bracket_s(name, ...))
end

function sb.add_alias(app_name, position)
  return command(add_alias_s(app_name, position))
end

function sb.add_slider(name, position, width)
  return command(add_slider_s(name, position, width))
end

function sb.add_graph(name, position, width)
  return command(add_graph_s(name, position, width))
end

function sb.add_event(name, ns_notification)
  return command(add_event_s(name, ns_notification))
end

function sb.bar(config)
  return command(bar_s(config))
end

function sb.clone(parent, name, position)
  return command(clone_s(parent, name, position))
end

function sb.defaults(config)
  return command(defaults_s(config))
end

function sb.reorder(...)
  return command(reorder_s(...))
end

function sb.move(name, position, subject)
  return command(move_s(name, position, subject))
end

function sb.rename(name, new_name)
  return command(rename_s(name, new_name))
end

function sb.push(name, ...)
  return command(push_s(name, ...))
end

function sb.trigger(event, env)
  return command(trigger_s(event, env))
end

function sb.update()
  return command("--update")
end



-- Main callback handler. This is called by the C helper and should probably
-- not be called directly.
function sb.callback(item, event, env)
  dispatch_calls(callbacks[1], item, event, env)
  dispatch_calls(nested_get(callbacks, item, 1), item, event, env)
  dispatch_calls(nested_get(callbacks, item, event), item, event, env)
end

--
-- `sketchybar --subscribe` in the standard way.
--
-- A single callback is registered for the item and handles all events.
-- If you need more granular or broad callback handling you should use
-- the other `subscribe_*` functions or `register_callback_*` functions.
--
-- ```
-- sb.subscribe(
--   "item_name",
--   { "front_app_switched", "mouse.clicked" },
--   function(item, event, env)
--     -- ...
--   end
-- )
-- ```
function sb.subscribe(item, events, callback)
  local base = "--subscribe %s %s"
  local event_arg = (type(events) == "table" and table.concat(events, " ")) or events
  command(fmt(base, item, event_arg))
  if callback ~= nil then
    register_callback_item(item, callback)
  end
end

-- `sketchybar --subscribe` to events with a callback for each event
--
-- ```
-- sb.subcribe_events(
--   "item_name",
--   {
--     front_app_switched = function(item, event, env) end,
--     ["mouse.clicked"] = function(item, event, env) end
--   }
-- )
-- ```
function sb.subscribe_events(item, event_callbacks)
  local events = {}
  for event, fn in pairs(event_callbacks) do
    register_callback_item_event(item, event, fn)
    table.insert(events, event)
  end
  command(fmt("--subscribe %s %s", item, table.concat(events, " ")))
end


function sb.query(query)
  local response = command("--query " .. query)
  return sb.json_parse(response)
end

function sb.reset()
  local bar = sb.query("bar")
  if bar == nil then return end
  local items = bar.items
  if items == nil or #items == 0 then return end
  local remove_all = nil
  for _, item in ipairs(items) do
    if remove_all == nil then
      remove_all = "--remove " .. item
    else
      remove_all = remove_all .. " --remove " .. item
    end
  end
  sb.command(remove_all)
end

function sb.event_names()
  local events = sb.query("events")
  if events == nil or not type(events) == "table" then return end
  local names = {}
  for name, _ in pairs(events) do
    table.insert(names, name)
  end
  return names
end



--
-- General utility functions
--

function sb.shell(command, trim)
  local fd = io.popen(command)
  local result = fd:read("*a")
  fd:close()
  if trim ~= false and string.sub(result, -1) == "\n" then
    return string.sub(result, 1, -2)
  end
  return result
end


--
-- Yabai functions
--

local function resolve_yabai_binary()
  local bin_path = sb.shell("which yabai")
  if bin_path ~= "" and (C.access(bin_path, X_OK) == 0) then
    return bin_path
  end
end

local function yabai_command_standard(command)
  local result = sb.shell("yabai -m " .. command)
  if result ~= nil then
    return sb.json_parse(result)
  end
end

function sb.yabai_command()
  print("yabai command handler has not been set up")
end

local function resolve_yabai_socket()
  local user = os.getenv("USER")
  local socket_path = string.format("/tmp/yabai_%s.socket", user)
  if (C.access(socket_path, bit.bor(W_OK, R_OK)) == 0) then
    return socket_path
  end
end

function sb.setup_yabai()
  local socket = resolve_yabai_socket()
  if socket ~= nil then
    sb.yabai_communication_mode = "socket"
    sb.yabai_set_socket_path(socket)
    sb.yabai_command = sb.yabai_query
    return "socket"
  end

  local binary = resolve_yabai_binary()
  if binary ~= nil then
    sb.yabai_communication_mode = "binary"
    sb.yabai_command = yabai_command_standard
    return "binary"
  end
end


-- function test__process_subs()
--   local _subscribe_0 = "mouse.clicked"
--   local _subscribe_1 = { "mouse.clicked", "front_app_switched" }
--   local _subscribe_2 = { "mouse.clicked", function() end }
--   local _subscribe_3 = { {"mouse.clicked", "front_app_switched"}, function() end }
--   local _subscribe_4 = { ["mouse.clicked"] = function() end, ["front_app_switched"] = function() end }
--   local _subscribe_5 = { function() end, ["mouse.clicked"] = function() end }
--   local _subscribe_6 = { ["mouse.clicked"] = { function() end, function() end }, ["front_app_switched"] = function() end }

--   print(inspect(process_subs(_subscribe_0)))
--   print(inspect(process_subs(_subscribe_1)))
--   print(inspect(process_subs(_subscribe_2)))
--   print(inspect(process_subs(_subscribe_3)))
--   print(inspect(process_subs(_subscribe_4)))
--   print(inspect(process_subs(_subscribe_5)))
--   print(inspect(process_subs(_subscribe_6)))
-- end
-- test__process_subs()


-- function test__add_item()
--   sb.add_item("sample", {
--     position = "left",
--     label = {
--       "lua item",
--       padding = {
--         left = 8,
--         right = 0
--       }
--     }
--   })

--   sb.add_item("item", "sample")
-- end
-- test__add_item()

-- function test__item()
--   print(inspect(item_s("sample", {
--     subscribe = {
--       "other_event",
--       function() end,
--       ["mouse.clicked"] = function()
--         print("cilck")
--       end,
--       ["front_app_switched"] = { function() end, function() end}
--     },
--     label = { padding = { right = 0, left = 8 }, y_offset = 0 },
--     icon = { display = "no" },
--     script = "yabai.sh"
--   })))

--   sb.callback("sample", "mouse.clicked", {})
-- end
-- test__item()

-- callbacks[1] = function(item, event, env)
--   print("global callback (1)")
-- end
-- callbacks["sample"] = {
--   function(item, event, env)
--     print("[sample] global callback (2)")
--   end,
--   test_event = function(item, event, env)
--     print("[sample] <test_event> callback (3)")
--   end
-- }

-- sb.callback("sample", "test_event", { info = "info str" })

-- callbacks[1] = {
--   function(item, event, env)
--     print("global callback (multi) (4)")
--   end
-- }
-- callbacks["sample"] = {
--   {
--     function(item, event, env)
--       print("[sample] global callback (multi) (5)")
--     end
--   },
--   test_event = {
--     function(item, event, env)
--       print("[sample] <test_event> callback (multi) (6)")
--     end
--   }
-- }

-- sb.callback("sample", "test_event", { info = "info str" })

-- print(serialize_config(config))
-- for _, s in ipairs(serialize_keys(config, {}, nil)) do
--   print(s)
-- end
-- print(sanitize_value('"test"'))

-- local function test__register_callback()
--   sb.register_callback(function(item, event, env)
--     print("global callback")
--   end)
--   sb.register_callback("sample", function(item, event, env)
--     print("item gobal callback")
--   end)
--   sb.register_callback("sample", "window_action", function(item, event, env)
--     print("[sample] <window_action> callback")
--   end)

--   print(inspect(callbacks))

--   sb.register_callback(function(item, event, env)
--     print("global callback 2")
--   end)
--   sb.register_callback("sample", function(item, event, env)
--     print("item gobal callback 2")
--   end)
--   sb.register_callback("sample", "window_action", function(item, event, env)
--     print("[sample] <window_action> callback 2")
--   end)

--   print(inspect(callbacks))

--   sb.callback("sample", "window_action", { action = "moved" })
-- end
-- test__register_callback()


local function optional_concat(head, tail)
  return head and (head .. (tail or ""))
end

local function path_exists(path)
  return path and C.access(path, F_OK) == 0
end

local function first_extant(...)
  for i = 1, select("#", ...) do
    local arg = select(i, ...)
    if path_exists(arg) then
      return arg
    end
  end
end

local function first_nonnil(...)
  for i = 1, select("#", ...) do
    local arg = select(i, ...)
    if arg ~= nil then
      return arg
    end
  end
end

local function resolve_config_dir()
  return first_nonnil(
    os.getenv("CONFIG_DIR"),
    optional_concat(os.getenv("XDG_CONFIG_HOME"), "/sketchybar"),
    optional_concat(os.getenv("HOME"), "/.config/sketchybar")
  )
end

local function load_user_config()
  local config_dir = resolve_config_dir()
  if not path_exists(config_dir) then return end

  local lua_dir = config_dir .. "/lua"
  local lua_lib_dir = first_extant(config_dir .. "/lib/lua", config_dir .. "/lua/lib")
  local init_file = first_extant(config_dir .. "/init.lua", lua_dir .. "/init.lua")

  if path_exists(lua_dir) then
    local file_search = lua_dir .. "/?.lua"
    local init_search = lua_dir .. "/?/init.lua"
    package.path = package.path .. ";" .. file_search .. ";" .. init_search
  end

  if lua_lib_dir ~= nil then
    local lib_search = lua_lib_dir .. "/?.so"
    package.cpath = package.cpath .. ";" .. lib_search
  end

  if init_file ~= nil then
    local user_config = assert(loadfile(init_file))
    local status, err = pcall(user_config)
    if not status then
      print("Error loading user config")
      print(err)
    end
  end
end


package.loaded["sketchybar"] = sb
load_user_config()

return sb

