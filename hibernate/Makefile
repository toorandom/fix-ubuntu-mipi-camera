# SPDX-License-Identifier: GPL-2.0
# Out-of-tree IPU6/IVSC hibernate overlay (see README.md)
KERNELRELEASE ?= $(shell uname -r)
KERNEL_SRC ?= /lib/modules/$(KERNELRELEASE)/build

MODDIRS := ipu-bridge src ov02c10

.PHONY: all clean

all:
	for d in $(MODDIRS); do \
	    $(MAKE) -C $(KERNEL_SRC) M=$(CURDIR)/$$d modules || exit 1; \
	done

clean:
	for d in $(MODDIRS); do \
	    $(MAKE) -C $(KERNEL_SRC) M=$(CURDIR)/$$d clean || exit 1; \
	done
