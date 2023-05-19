#include "sketchybar.h"
#include <stdio.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

lua_State *L;
static const char Callback = 'c';

void handler(env env) {
  uint32_t caret = 0;
  char* item = "";
  char* event = "";
  lua_newtable(L);

  // copied from `env_get_value_for_key`
  for(;;) {
    if (!env[caret]) break;
    char* key = &env[caret];
    int key_len = strlen(key);
    char* value = &env[caret + key_len + 1];
    int value_len = strlen(value);

    lua_pushlstring(L, key, strlen(key));
    lua_pushlstring(L, value, strlen(value));
    lua_settable(L, -3);

    if (strcmp(key, "NAME") == 0) {
      item = value;
    } else if (strcmp(key, "SENDER") == 0) {
      event = value;
    }
    caret += key_len + value_len + 2;
  }

  // Get `callback` from the `sketchybar` global, this way callback handling
  // can be overridden by users.
  //
  // However, it would be more performant to only do this table lookup once
  // when `core.lua` is loaded and then store the event callback in the lua
  // registry. Not sure which approach is best.
  //
  lua_getglobal(L, "sketchybar");
  lua_getfield(L, -1, "callback"); // push callback handler
  if (lua_isfunction(L, -1) == 1) {
    lua_pushlstring(L, item, strlen(item)); // push item name
    lua_pushlstring(L, event, strlen(event)); // push event name
    // push `env` table which is currently at position -5 on the stack
    lua_pushvalue(L, -5);
    // call the main event callback with 3 arguments from the stack
    int callback_success = lua_pcall(L, 3, 0, 0);
    if (callback_success != 0) {
      fprintf(stderr, "%s\n", lua_tostring(L, -1));
      fflush(stderr);
    }
  }
  lua_settop(L, 0); // clear stack
}

static int sketchybar_cmd(lua_State *L) {
  int n = lua_gettop(L);
  const char* message = lua_tostring(L, 1);
  char* result = sketchybar(message);
  lua_pushstring(L, result);
  return 1;
}

void setup_sketchybar(lua_State *L, char* helper_name) {
  lua_newtable(L);
  lua_pushstring(L, "command");
  lua_pushcfunction(L, *sketchybar_cmd);
  lua_settable(L, -3);
  lua_pushstring(L, "helper_name");
  lua_pushstring(L, helper_name);
  lua_settable(L, -3);
  lua_setglobal(L, "sketchybar");
}

int main (int argc, char** argv) {
  if (argc < 2) {
    printf("Usage: provider \"<bootstrap name>\"\n");
    exit(1);
  }

  L = luaL_newstate();
  if (!L) {
  } else {
    // Open standard libraries
    luaL_openlibs(L);
    setup_sketchybar(L, argv[1]);

    luaL_loadfile(L, "core.lua");
    int core_loaded = lua_pcall(L, 0, 0, 0);
    if (core_loaded != 0) {
      fprintf(stderr, "%s\n", lua_tostring(L, -1));
      fflush(stderr);
    }

    // Load config file
    // (eventually this should probably be handled by `core.lua`)
    luaL_loadfile(L, "config.lua"); // push `config.lua` body (as a function)

    // `pcall` the function on the top of the stack.
    // passes no arguments, collects no returns, and does no error handling
    int ret = lua_pcall(L, 0, 0, 0);
    if (ret != 0) {
      // `loadfile` pushes an error message if it failed
      fprintf(stderr, "%s\n", lua_tostring(L, -1));
      fflush(stderr);
    } else {
      lua_settop(L, 0); // clear stack
    }
  }

  event_server_begin(handler, argv[1]);

  lua_close(L);
  return 0;
}

