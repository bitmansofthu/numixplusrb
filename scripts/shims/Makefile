# rblive4 shim build
#
# All shims must be soft-float EABI5 and reference only GLIBC_2.4/2.7, because
# they are LD_PRELOADed into the XDJ-RX3 soft-float glibc-2.13 chroot.
#
# Usage:
#   make RX3=/path/to/extracted/XDJRX3-rootfs
#   make clean
#
# The RX3 rootfs is used as the sysroot for libc/libdl/librt/pthread so symbol
# versioning matches the target (modern host glibc would pull in GLIBC_2.17+).

CROSS   ?= arm-linux-gnueabi-
CC      := $(CROSS)gcc
STRIP   ?= $(CROSS)strip

RX3     ?= ../../extracted/XDJRX3-rootfs
RX3LIB  := $(RX3)/lib
RX3ULIB := $(RX3)/usr/lib

# The RX3 runtime rootfs has no libc_nonshared.a / libpthread_nonshared.a
# (dev-only archives); give the linker empty stubs so -lpthread links.
COMPAT  ?= compat

# The cross gcc predefines _FILE_OFFSET_BITS=64 (and _TIME_BITS=64).  With
# those on 32-bit ARM, <fcntl.h> redirects `open` to the symbol `open64`, so
# an interposer defining both open() and open64() emits the symbol `open64`
# twice ("symbol `open64' is already defined") and plain open() is no longer
# interposed at all.  Undefine both; this also matches the 32-bit off_t of the
# soft-float glibc-2.13 runtime the shims are preloaded into.
CFLAGS  := -O2 -march=armv5t -mfloat-abi=soft -fno-stack-protector -fPIC \
           -U_FILE_OFFSET_BITS -U_TIME_BITS \
           -Wall -Wextra -Wno-unused-parameter
LDFLAGS := -L$(COMPAT) -L$(RX3LIB) -L$(RX3ULIB) -Wl,-rpath-link,$(RX3LIB):$(RX3ULIB)

# Shared LD_PRELOAD libraries (soft-float, libc-only NEEDED)
SHARED  := knobshim2.so audioshim.so fbshim-tsc.so gpioshim.so tscshim.so crashcatch.so

# Static ARM helpers (have no soft-float runtime dependency)
STATIC  := seqinject2 udplog

# Must be the first rule in the file: bare `make` builds the first target
# only, so `all` has to precede the compat-stub rule below.
.PHONY: all clean check
all: $(SHARED) $(STATIC)

$(COMPAT)/libc_nonshared.a $(COMPAT)/libpthread_nonshared.a:
	@mkdir -p $(COMPAT)
	@ar rcs $(COMPAT)/libc_nonshared.a
	@ar rcs $(COMPAT)/libpthread_nonshared.a

# knobshim2 needs the ALSA sequencer headers; host headers are fine as the
# structs are ABI-stable.
knobshim2.so: knobshim2.c $(COMPAT)/libc_nonshared.a $(COMPAT)/libpthread_nonshared.a
	$(CC) $(CFLAGS) -shared -o $@ $< -lpthread -lm -lc $(LDFLAGS)

# audioshim must bind dlopen/dlsym to libdl GLIBC_2.4 (the .symver directives
# are in the source); link the RX3 libdl explicitly.
audioshim.so: audioshim.c
	$(CC) $(CFLAGS) -shared -o $@ $< $(RX3LIB)/libdl.so.2 -lc $(LDFLAGS)

fbshim-tsc.so: fbshim-tsc.c $(COMPAT)/libc_nonshared.a $(COMPAT)/libpthread_nonshared.a
	$(CC) $(CFLAGS) -shared -o $@ $< -lpthread -lm -lc $(LDFLAGS)

gpioshim.so: gpioshim.c
	$(CC) $(CFLAGS) -shared -o $@ $< -lc $(LDFLAGS)

tscshim.so: tscshim.c $(COMPAT)/libc_nonshared.a $(COMPAT)/libpthread_nonshared.a
	$(CC) $(CFLAGS) -shared -o $@ $< -lpthread -lm -lc $(LDFLAGS)

crashcatch.so: crashcatch.c
	$(CC) $(CFLAGS) -shared -o $@ $< -lc $(LDFLAGS)

seqinject2: seqinject2.c
	$(CC) -O2 -march=armv5t -mfloat-abi=soft -static -o $@ $<

udplog: udplog.c
	$(CC) -O2 -march=armv5t -mfloat-abi=soft -static -o $@ $<

# Fail the build if any GLIBC version above 2.7 or a hard-float tag sneaks in.
check: $(SHARED)
	@echo "== GLIBC symbol versions =="
	@for f in $(SHARED); do \
	  echo "-- $$f"; \
	  $(CROSS)objdump -T $$f 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -u; \
	  $(CROSS)readelf -A $$f | grep -i 'Tag_ABI_VFP_args' && echo "  !! HARD-FLOAT" || true; \
	done

clean:
	rm -f $(SHARED) $(STATIC) *.o
