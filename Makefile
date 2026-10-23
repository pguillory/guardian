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

nifs: priv/column.so priv/mmap.so priv/jq_worker

priv:
	mkdir -p priv

priv/column.so: priv src/column.c Makefile
	gcc -o priv/column.so src/column.c $(CFLAGS)

priv/mmap.so: priv src/mmap.c Makefile
	gcc -o priv/mmap.so src/mmap.c $(CFLAGS)

# The jq() query function's sandboxed worker: a separate executable, linked to the
# system libjq (Debian libjq-dev in the Dockerfile, Homebrew jq on macOS).
JQ_CFLAGS := -O2 -Wall -Wextra
ifeq ($(UNAME_SYS), Darwin)
	JQ_CFLAGS += -I /opt/homebrew/include -L /opt/homebrew/lib
endif

priv/jq_worker: priv src/jq_worker.c Makefile
	gcc -o priv/jq_worker src/jq_worker.c $(JQ_CFLAGS) -ljq

clean:
	rm -f priv/column.so priv/mmap.so priv/jq_worker
