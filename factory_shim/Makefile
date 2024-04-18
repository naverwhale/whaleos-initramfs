# Copyright 2015 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Dependency list of binary programs.
BIN_DEPS = \
	/bin/busybox \
	/bin/sh \
	/sbin/dmsetup \
	/sbin/frecon-lite \
	/usr/bin/cgpt \
	/usr/bin/crossystem \
	/usr/bin/pv \
	/usr/sbin/factory_tty.sh

# Extra dependency, should be set by builder configuration.
EXTRA_BIN_DEPS ?=

# Layout of directories to be created in initramfs.
RAMFS_LAYOUT_DIRS = \
	usr/share/misc

include ../common/initramfs.mk

$(RAMFS_BIN): stage_init
	cp bootstrap.sh $(STAGE)/bin
	$(call generate_ramfs)
