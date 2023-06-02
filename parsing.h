#include <lua.h>
#include <lauxlib.h>
#include <lualib.h> 
#include <unistd.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include "cJSON.h"

char* parse_kv_table(lua_State* state, char* prefix);
bool json_to_lua_table(lua_State* state, const char* json_str);

