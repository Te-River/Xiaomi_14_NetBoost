# SPDX-License-Identifier: GPL-2.0-only
#
# BBRv3 congestion control backport module for NetBoost.
# Source: https://github.com/hrimfaxi/tcp_bbr_modules (GPL-2.0)
# Verified on mainline 5.4 ~ 6.6+ kernels (including GKI android14-6.1).
#
# Build targets:
#   make                        # against /lib/modules/$(uname -r)/build
#   make KDIR=/path/to/kernel   # against a prepared kernel tree
#   make KDIR=... ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-   # cross build
#
# The build first runs gen_kconfig.py, which test-compiles the probes in
# kapi_checklist against KDIR and writes kernel_config.h (HAVE_* macros).
# tcp_bbr3.c + bbr_compat.h adapt purely on those macros.

KDIR      ?= /lib/modules/$(shell uname -r)/build
PWD       := $(shell pwd)

# Compiler used for the probes; should match the one kbuild uses.
CC_PROBE  ?= $(CROSS_COMPILE)gcc
PROBE_J   ?= $(shell nproc 2>/dev/null || echo 4)
PROBE_ARCH := $(if $(ARCH),-a $(ARCH),)

obj-m := tcp_bbr3.o

ccflags-y := -I$(src)

KBUILD_VARS := $(if $(ARCH),ARCH=$(ARCH),) $(if $(CROSS_COMPILE),CROSS_COMPILE=$(CROSS_COMPILE),)

.PHONY: all modules probe clean distclean

all: modules

kernel_config.h: kapi_checklist gen_kconfig.py
	python3 gen_kconfig.py $(KDIR) $@ $(CC_PROBE) kapi_checklist -j $(PROBE_J) $(PROBE_ARCH)

probe: kernel_config.h

modules: kernel_config.h
	$(MAKE) -C $(KDIR) M=$(PWD) $(KBUILD_VARS) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

distclean: clean
	rm -f kernel_config.h

.PHONY: all modules probe clean distclean
