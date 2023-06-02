#include "parsing.h"

char* parse_kv_table(lua_State* state, char* prefix) {
  lua_pushnil(state);
  const char* key,* value;
  char* kv_pairs = NULL;
  char hex[16];

  while (lua_next(state, -2)) {
    uint32_t kv_pair_len = kv_pairs ? strlen(kv_pairs) : 0;
    if (lua_isnil(state, -2)) {
      if (kv_pairs) free(kv_pairs);
      return NULL;
    }

    key = lua_tostring(state, -2);

    if (lua_type(state, -1) == LUA_TTABLE) {
      if (prefix) {
        uint32_t new_prefix_len = (prefix ? strlen(prefix) : 0)
                                  + strlen(key)
                                  + 2;

        char new_prefix[new_prefix_len];
        snprintf(new_prefix, new_prefix_len, "%s.%s", prefix, key);
        value = parse_kv_table(state, new_prefix);
      } else {
        value = parse_kv_table(state, (char*)key);
      }

      if (!value) {
        if (kv_pairs) free(kv_pairs);
        return NULL;
      }

      uint32_t new_kv_pair_len = kv_pair_len
                                 + strlen(value)
                                 + 1;

      kv_pairs = realloc(kv_pairs, new_kv_pair_len);
      snprintf(kv_pairs + kv_pair_len, new_kv_pair_len, "%s", value);
      free((char*)value);
    }
    else {
      if (lua_type(state, -1) == LUA_TBOOLEAN) {
        value = lua_toboolean(state, -1) ? "on" : "off";
      } else {
        if ((strcmp(key, "color") == 0 || strcmp(key, "border_color") == 0)
            && lua_type(state, -1) == LUA_TNUMBER) {
          uint32_t number = lua_tonumber(state, -1);
          snprintf(hex, 16, "0x%x", number);
          value = hex;
        } else {
          value = lua_tostring(state, -1);
        }
      }

      uint32_t new_kv_pair_len = (prefix ? strlen(prefix) + 1 : 0)
                                  + kv_pair_len
                                  + strlen(value)
                                  + strlen(key)
                                  + 5;

      kv_pairs = realloc(kv_pairs, new_kv_pair_len);
      if (prefix) {
        snprintf(kv_pairs + kv_pair_len, new_kv_pair_len, " %s.%s='%s'",
                                                          prefix,
                                                          key,
                                                          value         );
      }
      else {
        snprintf(kv_pairs + kv_pair_len, new_kv_pair_len, " %s='%s'",
                                                          key,
                                                          value      );
      }
    }
    lua_pop(state, 1);
  }

  return kv_pairs;
}

void json_object_to_lua_table(lua_State* state, cJSON* json);

void json_array_to_lua_table(lua_State* state, cJSON* json) {
  int i = 1;
  cJSON* item;
  lua_newtable(state);
  cJSON_ArrayForEach(item, json) {
    switch (item->type) {
      case cJSON_Number:
        lua_pushnumber(state, item->valuedouble);
        break;
      case cJSON_String:
        lua_pushstring(state, item->valuestring);
        break;
      case cJSON_Array:
        json_array_to_lua_table(state, item);
        break;
      case cJSON_Object:
        json_object_to_lua_table(state, item);
        break;
      case cJSON_True:
        lua_pushboolean(state, true);
        break;
      case cJSON_False:
        lua_pushboolean(state, false);
        break;
      default:
        lua_pushnil(state);
        break;
    }
    
    lua_rawseti(state, -2, i);
    i++;
  }
}

void json_object_to_lua_table(lua_State* state, cJSON* json) {
  lua_newtable(state);
  cJSON* item;
  cJSON_ArrayForEach(item, json) {
    lua_pushstring(state, item->string);
    switch (item->type) {
      case cJSON_Number:
        lua_pushnumber(state, item->valuedouble);
        break;
      case cJSON_String:
        lua_pushstring(state, item->valuestring);
        break;
      case cJSON_Array:
        json_array_to_lua_table(state, item);
        break;
      case cJSON_Object:
        json_object_to_lua_table(state, item);
        break;
      case cJSON_True:
        lua_pushboolean(state, true);
        break;
      case cJSON_False:
        lua_pushboolean(state, false);
        break;
      default:
        lua_pushnil(state);
        break;
    }
    lua_settable(state, -3);
  }
}

bool json_to_lua_table(lua_State* state, const char* json_str) {
  cJSON* json = cJSON_Parse(json_str);
  if (!json) {
    return false;
  }

  if (cJSON_IsInvalid(json)) {
    cJSON_Delete(json);
    return false;
  }

  switch (json->type) {
    case cJSON_Array:
      json_array_to_lua_table(state, json);
      break;
    case cJSON_Object:
      json_object_to_lua_table(state, json);
      break;
    default:
      cJSON_Delete(json);
      return false;
      break;
  }
  cJSON_Delete(json);
  return true;
}

