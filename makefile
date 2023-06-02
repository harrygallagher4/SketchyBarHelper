CC=clang
CFLAGS=-std=c99 $(PKG_PATHS)
PKGS=luajit libcjson
PKG_PATHS=$(shell pkg-config --cflags --libs $(PKGS))
SOURCES=$(wildcard *.c) $(wildcard *.h)

LUA_SOURCES = $(wildcard lua/src/*.lua)
LUA_EMBED_NAMES = $(notdir $(basename $(LUA_SOURCES)))


ifeq ($(BUILD_TYPE),dev)
CFLAGS+=-D BUILD_DEV
.PHONY: sb_helper
endif


.PHONY: compile clean clean_lua lua_libcheck
compile: sb_helper


sb_helper: $(SOURCES) lua/libs.h
	$(CC) $(CFLAGS) helper.c parsing.c -o $@

lua/libs.h: $(LUA_SOURCES)
	printf "" > $@
	for f in $(LUA_EMBED_NAMES); do xxd -C -i -n "lua_lib_$$f" "./lua/src/$$f.lua" >> $@; done


lua_libcheck:
	@grep 'LUA_LIB' ./lua/libs.h

clean_lua:
	rm -rf ./lua/libs.h

clean: clean_lua
	rm -rf sb_helper

