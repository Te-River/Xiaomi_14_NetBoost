# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost kernel modules - Xiaomi 14 (SM8650 / android14-6.1 GKI)
#
# Build targets:
#   make                        # against /lib/modules/$(uname -r)/build
#   make KDIR=/path/to/kernel   # against a prepared kernel tree
#   make KDIR=... ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-   # cross build
#
# For GKI android14-6.1, the recommended way is to build inside the DDK
# container (see scripts/build.sh) which carries the matched kernel headers
# and clang toolchain.

KDIR      ?= /lib/modules/$(shell uname -r)/build
PWD       := $(shell pwd)
KBUILD_VARS := $(if $(ARCH),ARCH=$(ARCH),) $(if $(CROSS_COMPILE),CROSS_COMPILE=$(CROSS_COMPILE),)

obj-m := netboost_core.o

ccflags-y := -I$(src)

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) $(KBUILD_VARS) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

distclean: clean
	rm -f Module.symvers modules.order

.PHONY: all modules clean distclean
