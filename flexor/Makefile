# Copyright 2023 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Dependency list of binary programs.
BIN_DEPS = \
	/bin/busybox \
	/usr/bin/cgpt \
	/usr/bin/crosid \
	/usr/bin/crossystem \
	/usr/bin/futility

# Extra dependency, should be set by builder configuration.
EXTRA_BIN_DEPS ?=

# Programs required by Flexor.
FLEXOR_BIN_DEPS = \
	/bin/mount \
	/bin/tail \
	/bin/tar \
	/bin/dd \
	/bin/udevadm \
	/build/initramfs/sbin/flexor \
	/usr/sbin/chromeos-install \
	/sbin/blockdev \
	/sbin/init \
	/sbin/poweroff \
	/sbin/losetup \
	/sbin/mkfs.ext4 \
	/sbin/reboot \
	/sbin/sfdisk

DATA_DEPS = \
	/usr/share/misc/chromeos-common.sh

RAMFS_BIN_DEPS = \
	$(BIN_DEPS) \
	$(FLEXOR_BIN_DEPS) \
	$(EXTRA_BIN_DEPS)

INTERACTIVE_COMPLETE ?= true

# Layout of directories to be created in initramfs.
RAMFS_LAYOUT_DIRS = \
	usr/share/misc \
	usr/share/syslinux \
	lib/modules

include ../common/initramfs.mk

$(RAMFS_BIN): stage_init flexor
	ln -s busybox $(STAGE)/bin/env
	ln -s busybox $(STAGE)/bin/gzip
	ln -s busybox $(STAGE)/bin/sh
	ln -s futility "$(STAGE)/bin/dump_kernel_config"
	ln -s futility "$(STAGE)/bin/vbutil_kernel"
	lddtree --verbose --copy-non-elfs --root=$(SYSROOT) \
		--copy-to-tree=$(STAGE) \
		$(DATA_DEPS)
	$(call generate_write_gpt_sh,usb)
	$(call generate_ramfs)

.PHONY: flexor
flexor: stage_init
	# KERNEL MODULES
	cp -av "$(SYSROOT)/lib/modules/"* "$(STAGE)/lib/modules"
	(cd "$(STAGE)/lib/modules/"*"/kernel" && \
		find -maxdepth 1 \
		! -name drivers \
		! -name fs \
		! -name crypto \
		! -name . -exec rm -rf {} +)
	(cd "$(STAGE)/lib/modules/"*"/kernel/drivers" && \
		find -maxdepth 1 \
		! -name soc \
		! -name . -exec rm -rf {} +)
	# Add policy files for SELinux.
	cp -av "$(SYSROOT)/$(LIBDIR)/libselinux"* "$(STAGE)/$(LIBDIR)/"
	cp -av "$(SYSROOT)/usr/$(LIBDIR)/libselinux"* "$(STAGE)/usr/$(LIBDIR)/"
	if [ -d "$(SYSROOT)/etc/selinux" ]; then \
		mkdir -p "$(STAGE)/etc/selinux"; \
		rsync -av "$(SYSROOT)/etc/selinux/"* "$(STAGE)/etc/selinux/"; \
	fi
	# CrOS-install dependencies.
	cp -av "$(SYSROOT)/usr/share/misc/shflags" "$(STAGE)/usr/share/misc"
	cp -av "$(SYSROOT)/usr/share/misc/lvm-utils.sh" "$(STAGE)/usr/share/misc"
	cp -av "$(SYSROOT)/usr/share/misc/chromeos-common.sh" \
		"$(STAGE)/usr/share/misc"
	cp -av "$(SYSROOT)/usr/share/syslinux/gptmbr.bin" \
		"$(STAGE)/usr/share/syslinux/" || true

.PHONY: check
check:
