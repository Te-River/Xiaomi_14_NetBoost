# SPDX-License-Identifier: GPL-2.0-only
#
# BBRv3 congestion control backport module for NetBoost.
# Source: https://github.com/hrimfaxi/tcp_bbr_modules (GPL-2.0)
# Verified on mainline 5.4 ~ 6.6+ kernels (including GKI android14-6.1).
#
# Two build modes:
#
#  A) DDK mode (recommended, matches the GKI clang toolchain):
#     Pass KERNEL_SRC (+ optional CLANG_DIR). The kapi probe then also uses
#     clang (gen_kconfig.py auto-enables LLVM=1 for clang compilers).
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
# The build first runs gen_kconfig.py, which test-compiles the probes in
# kapi_checklist against the kernel tree and writes kernel_config.h
# (HAVE_* macros). tcp_bbr3.c + bbr_compat.h adapt purely on those macros.

obj-m := tcp_bbr3.o
ccflags-y := -I$(src)

PROBE_J ?= $(shell nproc 2>/dev/null || echo 4)

ifeq ($(KERNEL_SRC),)

# ------------------------------------------------------------------ #
#  B) classic mode                                                   #
# ------------------------------------------------------------------ #
KDIR ?= /lib/modules/$(shell uname -r)/build
CC_PROBE ?= $(CROSS_COMPILE)gcc
PROBE_ARCH := $(if $(ARCH),-a $(ARCH),)
KBUILD_VARS := $(if $(ARCH),ARCH=$(ARCH),) $(if $(CROSS_COMPILE),CROSS_COMPILE=$(CROSS_COMPILE),)

kernel_config.h: kapi_checklist gen_kconfig.py
	python3 gen_kconfig.py $(KDIR) $@ $(CC_PROBE) kapi_checklist -j $(PROBE_J) $(PROBE_ARCH)

all: modules

modules: kernel_config.h
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

CC_PROBE := $(CLANG_DIR)/clang
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

kernel_config.h: kapi_checklist gen_kconfig.py
	PATH="$(CLANG_DIR):$(PATH)" \
		python3 gen_kconfig.py $(KERNEL_SRC) $@ $(CC_PROBE) kapi_checklist -j $(PROBE_J) -a arm64

all: modules

modules: kernel_config.h
	$(MAKE) $(MAKE_ARGS) modules

strip: modules
	$(STRIP) -d $(CURDIR)/tcp_bbr3.ko

clean:
	$(MAKE) $(MAKE_ARGS) clean

endif

distclean: clean
	rm -f kernel_config.h Module.symvers modules.order

.PHONY: all modules strip probe clean distclean
