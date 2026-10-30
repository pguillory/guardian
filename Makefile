.PHONY: nifs console clean

ERL_PATH = $(shell elixir -e 'IO.puts [:code.root_dir, "/erts-", :erlang.system_info :version]')
CFLAGS := -fPIC -I $(ERL_PATH)/include -O3

UNAME_SYS := $(shell uname -s)
ifeq ($(UNAME_SYS), Darwin)
	CFLAGS += -bundle -bundle_loader $(ERL_PATH)/bin/beam.smp
else ifeq ($(UNAME_SYS), FreeBSD)
	CFLAGS += -shared
else ifeq ($(UNAME_SYS), Linux)
	CFLAGS += -shared
endif

# Column sizes, counts, and offsets are 64-bit. Clang can reject narrowing
# conversions and signed/unsigned comparisons so they cannot creep back in.
ifneq ($(findstring clang,$(shell gcc --version 2>/dev/null)),)
	CFLAGS += -Werror=shorten-64-to-32 -Werror=sign-compare
endif

console: nifs
	iex --erl "-kernel shell_history enabled" -S mix

# nifs is phony; the empty recipe keeps make from printing "Nothing to be done" on
# every up-to-date compile. Its prerequisites still rebuild as usual.
nifs: priv/column.so priv/mmap.so
	@:

priv:
	mkdir -p priv

priv/column.so: priv src/column.c Makefile
	gcc -o priv/column.so src/column.c $(CFLAGS)

priv/mmap.so: priv src/mmap.c Makefile
	gcc -o priv/mmap.so src/mmap.c $(CFLAGS)

clean:
	rm -f priv/column.so priv/mmap.so
