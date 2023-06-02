CC=clang
CFLAGS=-std=c99 $(PKG_PATHS)
PKGS=luajit libcjson
PKG_PATHS=$(shell pkg-config --cflags --libs $(PKGS))
SOURCES=$(wildcard *.c) $(wildcard *.h)
BUILD=./build

LUA_SOURCES = $(wildcard lua/src/*.lua)
LUA_LIBNAMES = $(notdir $(basename $(LUA_SOURCES)))
LUA_EMBED_DIR = $(BUILD)/lua_embeds
LUA_EMBED_HEADERS = $(addprefix $(LUA_EMBED_DIR)/,$(LUA_LIBNAMES))
.INTERMEDIATE: $(LUA_EMBED_HEADERS)


ifeq ($(BUILD_TYPE),dev)
CFLAGS+=-D BUILD_DEV
.PHONY: sb_helper
endif


.PHONY: compile clean clean_lua lua_libcheck
compile: sb_helper

sb_helper: $(SOURCES) lua/libs.h
	$(CC) $(CFLAGS) helper.c parsing.c -o $@

$(LUA_EMBED_DIR):
	mkdir -p $(LUA_EMBED_DIR)

$(LUA_EMBED_DIR)/%: lua/src/%.lua
	xxd -C -i -n lua_lib_$(notdir $@) $^ > $@

lua/libs.h: $(LUA_EMBED_HEADERS) | $(LUA_EMBED_DIR)
	cat $(LUA_EMBED_HEADERS) > $@


lua_libcheck:
	@grep 'LUA_LIB' ./lua/libs.h

clean_lua:
	rm -rf ./lua/libs.h

clean: clean_lua
	rm -rf sb_helper

