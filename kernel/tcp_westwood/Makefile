# SPDX-License-Identifier: GPL-2.0-only
#
# TCP Westwood+ congestion control module (out-of-tree port of the
# upstream net/ipv4/tcp_westwood.c). The stock android14-6.1 kernel does
# not compile Westwood (no CONFIG_TCP_CONG_WESTWOOD in gki_defconfig or
# the Xiaomi shennong fragments), so the "weak signal" scenario needs it
# shipped as an LKM.
#
# Same two build modes as netboost_core:
#   A) DDK mode:   make KERNEL_SRC=... CLANG_DIR=...
#   B) classic:    make KDIR=... [ARCH=arm64 CROSS_COMPILE=...]

obj-m := tcp_westwood.o
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
	$(STRIP) -d $(CURDIR)/tcp_westwood.ko

clean:
	$(MAKE) $(MAKE_ARGS) clean

endif

distclean: clean
	rm -f Module.symvers modules.order

.PHONY: all modules strip clean distclean
