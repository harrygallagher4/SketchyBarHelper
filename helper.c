#include <stdio.h>
#include <ctype.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <cJSON.h>
#include "sketchybar.h"
#include "parsing.h"
#include "./lua/libs.h"


#define MACH_HELPER "git.lua.sketchybar"
#define YABAI_RECV_BUFFER 1024

lua_State *Lg;
char* yabai_socket_path = NULL;



int yabai_json_parse(lua_State *Ls) {
  const char* json = lua_tostring(Ls, 1);
  json_to_lua_table(Ls, json);
  return 1;
}

struct sockaddr_un unix_socket(char* socket_path) {
  struct sockaddr_un address;
  memset(&address, 0, sizeof(struct sockaddr_un));
  address.sun_family = AF_UNIX;
  strncpy(address.sun_path, socket_path, sizeof(address.sun_path) - 1);
  return address;
}

int yabai_set_socket_path(lua_State *Ls) {
  const char* path = lua_tostring(Ls, 1);
  yabai_socket_path = malloc(strlen(path) + 1);
  strcpy(yabai_socket_path, path);
  return 0;
}

char generate_message(const char* command, char** message_buf) {
  int command_len = strlen(command);
  *message_buf = malloc(command_len * 2);
  char* mbuf = *message_buf;
  char message_len = 0;
  mbuf[message_len++] = '\0';
  mbuf[message_len++] = '\0';
  mbuf[message_len++] = '\0';
  mbuf[message_len++] = '\0';

  for (int i = 0; i < command_len; i++) {
    char c = command[i];
    if (c == ' ') mbuf[message_len++] = '\0';
    else if (c == 0) break;
    else mbuf[message_len++] = c;
  }

  mbuf[message_len++] = '\0';
  mbuf[message_len++] = '\0';
  mbuf[0] = message_len - 4;

  return message_len;
}

int recv_all(int fd, char **message) {
  *message = malloc(1);
  *message[0] = '\0';

  char buffer[YABAI_RECV_BUFFER];
  int bytes_total = 0;
  while(1) {
    int bytes = recv(fd, (void*)buffer, YABAI_RECV_BUFFER, 0);
    if (bytes == -1) return -1; // error
    if (bytes == 0) break; // no data

    bytes_total += bytes;
    *message = realloc(*message, strlen(*message) + 1 + YABAI_RECV_BUFFER);
    strncat(*message, buffer, bytes);

    if (bytes < YABAI_RECV_BUFFER) break; // done
  }
  return bytes_total;
}

int yabai_query(lua_State *Ls) {
  if (yabai_socket_path == NULL) return -1;

  const char *command = lua_tostring(Ls, 1);
  char *send_message = NULL, *recv_message = NULL;
  char send_len = generate_message(command, &send_message);
  struct sockaddr_un address = unix_socket(yabai_socket_path);

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);

  if (fd == -1) {
    fprintf(stderr, "Could not open socket [%d]\n", errno);
    return -1;
  }
  if (connect(fd, (struct sockaddr *) &address, sizeof(struct sockaddr_un) - 1) == -1) {
    fprintf(stderr, "Could not open connection [%d]\n", errno);
    return -1;
  }
  if (send(fd, send_message, send_len, 0) == -1) {
    fprintf(stderr, "Could not send message [%d]\n", errno);
    return -1;
  }
  if (recv_all(fd, &recv_message) == -1) {
    fprintf(stderr, "Could not receive data over socket [%d]\n", errno);
    return -1;
  }

  close(fd);

  int returns = 0;
  if (strlen(recv_message) == 0) {
    lua_pushinteger(Ls, 0);
    returns = 1;
  } else if (json_to_lua_table(Ls, recv_message)) {
    returns = 1;
  }else {
    fprintf(stderr, "JSON error\n");
    fprintf(stderr, "Command: %s\n", command);
    fprintf(stderr, "%s\n", recv_message);
  };
  free(send_message);
  free(recv_message);
  return returns;
}

void handler(env env) {
  if (!Lg) { return; }

  uint32_t caret = 0;
  char* item = "";
  char* event = "";
  lua_newtable(Lg);
  for(;;) {
    if (!env[caret]) break;
    char* key = &env[caret];
    int key_len = strlen(key);
    char* value = &env[caret + key_len + 1];
    int value_len = strlen(value);

    // keys are upper-case because sketchybar was designed with shell scripting
    // in mind. lower-case is more conventional for lua.
    for(int i = 0; i < key_len; i++) { key[i] = tolower(key[i]); }

    lua_pushlstring(Lg, key, strlen(key));
    lua_pushlstring(Lg, value, strlen(value));
    lua_settable(Lg, -3);

    if (strcmp(key, "name") == 0) {
      item = value;
    } else if (strcmp(key, "sender") == 0) {
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
  lua_getglobal(Lg, "sketchybar");
  lua_getfield(Lg, -1, "callback");
  if (lua_isfunction(Lg, -1) == 1) {
    lua_pushlstring(Lg, item, strlen(item));
    lua_pushlstring(Lg, event, strlen(event));
    lua_pushvalue(Lg, -5);
    int callback_success = lua_pcall(Lg, 3, 0, 0);
    if (callback_success != 0) {
      fprintf(stderr, "Callback error:\n");
      fprintf(stderr, "%s\n", lua_tostring(Lg, -1));
      fflush(stderr);
    }
  }
  lua_settop(Lg, 0);
}

static int sketchybar_cmd(lua_State *L) {
  const char* message = lua_tostring(L, 1);
  char* result = sketchybar((char*)message);
  lua_pushstring(L, result);
  return 1;
}

int luaL_load_sketchybar(lua_State *L) {
  lua_newtable(L);

  lua_pushliteral(L, "command");
  lua_pushcfunction(L, *sketchybar_cmd);
  lua_settable(L, -3);

  lua_pushliteral(L, "helper_name");
  lua_pushliteral(L, MACH_HELPER);
  lua_settable(L, -3);

  lua_pushliteral(L, "yabai_query");
  lua_pushcfunction(L, *yabai_query);
  lua_settable(L, -3);

  lua_pushliteral(L, "yabai_set_socket_path");
  lua_pushcfunction(L, *yabai_set_socket_path);
  lua_settable(L, -3);

  lua_pushliteral(L, "json_parse");
  lua_pushcfunction(L, *yabai_json_parse);
  lua_settable(L, -3);

  lua_setglobal(L, "sketchybar");


  lua_getglobal(L, "package");
  lua_pushliteral(L, "preload");
  lua_gettable(L, -2);
  lua_pushliteral(L, "inspect");
  luaL_loadbuffer(L, (char *) LUA_LIB_INSPECT, LUA_LIB_INSPECT_LEN, "inspect.lua");
  lua_settable(L, -3);
  lua_settop(L, 0);


#ifdef BUILD_DEV
  luaL_loadfile(L, "./lua/src/core.lua");
#else
  luaL_loadbuffer(L, (char *) LUA_LIB_CORE, LUA_LIB_CORE_LEN, "core.lua");
#endif
  int loaded = lua_pcall(L, 0, 0, 0);
  if (loaded != 0) {
    fprintf(stderr, "Failed to load SketchyBar core!\n");
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return loaded;
  } else {
    lua_settop(L, 0);
  }

  return 0;
}

int main (int argc, char** argv) {
  event_server_init(handler, MACH_HELPER);

  Lg = luaL_newstate();
  if (!Lg) return 1;
  luaL_openlibs(Lg);
  luaL_load_sketchybar(Lg);

  event_server_run(handler);

  lua_close(Lg);
  return 0;
}

