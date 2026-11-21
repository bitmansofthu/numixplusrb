# scripts/device/Makefile
#
# Builds the on-device `timeout` helper (hard-float ARM, static). The rest of
# scripts/device/ is shell that runs as-is on the SC Live 4.
#
#   make CROSS=arm-linux-gnueabihf-

CROSS ?= arm-linux-gnueabihf-
CC    := $(CROSS)gcc

.PHONY: all clean
all: timeout poweroff-hook.so

timeout: timeout.c
	$(CC) -O2 -static -Wall -Wextra -o $@ $<

# LD_PRELOADed into /usr/bin/az01-pwrbtn: runs /data/rbp-shutdown.sh before
# the daemon's real poweroff syscall. Hard-float, like the stock daemon.
poweroff-hook.so: poweroff-hook.c
	$(CC) -O2 -fPIC -shared -Wall -Wextra -o $@ $<

clean:
	rm -f timeout poweroff-hook.so
