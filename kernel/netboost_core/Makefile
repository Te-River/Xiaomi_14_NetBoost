# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost core module Makefile.
#
# Two build modes:
#
#  A) DDK mode (recommended, matches the GKI clang toolchain):
#     Pass KERNEL_SRC (+ optional CLANG_DIR) as make variables or env vars.
#     Inside the ghcr.io/ylarod/ddk-min image these are set automatically by
#     scripts/build-in-ddk.sh.
#
#         make KERNEL_SRC=/opt/ddk/kdir/android14-6.1 \
#              CLANG_DIR=/opt/ddk/clang/clang-r123456b/bin
#
#  B) Classic mode: build against a prepared kernel tree with the default
#     (usually gcc) toolchain.
#
#         make KDIR=/lib/modules/$(uname -r)/build
#         make KDIR=... ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
#
# For GKI android14-6.1 the recommended entry point is scripts/build.sh
# (spawns the DDK container) or GitHub Actions.

obj-m := netboost_core.o
ccflags-y := -I$(src)

ifeq ($(KERNEL_SRC),)

# ------------------------------------------------------------------ #
#  B) classic mode                                                   #
# ------------------------------------------------------------------ #
KDIR ?= /lib/modules/$(shell uname -r)/build
KBUILD_VARS := $(if $(ARCH),ARCH=$(ARCH),) $(if $(CROSS_COMPILE),CROSS_COMPILE=$(CROSS_COMPILE),)

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(KBUILD_VARS) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(KBUILD_VARS) clean

else

# ------------------------------------------------------------------ #
#  A) DDK mode (clang / LLVM=1, mirrors the GKI kernel build)        #
# ------------------------------------------------------------------ #
CLANG_DIR ?= $(shell ls -d /opt/ddk/clang/clang-r*/bin 2>/dev/null | sort -V | tail -1)
ifeq ($(CLANG_DIR),)
$(error DDK mode needs CLANG_DIR (e.g. /opt/ddk/clang/clang-r*/bin))
endif

CC      := $(CLANG_DIR)/clang
LD      := $(CLANG_DIR)/ld.lld
AR      := $(CLANG_DIR)/llvm-ar
NM      := $(CLANG_DIR)/llvm-nm
OBJCOPY := $(CLANG_DIR)/llvm-objcopy
OBJDUMP := $(CLANG_DIR)/llvm-objdump
STRIP   := $(CLANG_DIR)/llvm-strip

MAKE_ARGS := -C $(KERNEL_SRC) M=$(CURDIR) \
	ARCH=arm64 LLVM=1 LLVM_IAS=1 \
	CROSS_COMPILE=aarch64-linux-gnu- \
	CC=$(CC) LD=$(LD) AR=$(AR) NM=$(NM) \
	OBJCOPY=$(OBJCOPY) OBJDUMP=$(OBJDUMP) STRIP=$(STRIP)

all: modules

modules:
	$(MAKE) $(MAKE_ARGS) modules

strip: modules
	$(STRIP) -d $(CURDIR)/netboost_core.ko

clean:
	$(MAKE) $(MAKE_ARGS) clean

endif

distclean: clean
	rm -f Module.symvers modules.order

.PHONY: all modules strip clean distclean
