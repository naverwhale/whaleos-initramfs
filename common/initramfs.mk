# Copyright 2015 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Disable implicit rules.
.SUFFIXES:

# How to compress the cpio archive.
RAMFS_COMPRESS ?= xz -9 -T0 --check=crc32

# Staging and build toolchain.
SRCDIR ?= $(CURDIR)
NAME ?= $(notdir $(SRCDIR))
OUTPUT_DIR ?= $(SRCDIR)
RAMFS_BIN ?= $(OUTPUT_DIR)/$(NAME)_ramfs.cpio
STAGE ?= $(OUTPUT_DIR)/stage_$(NAME)
DEFAULT_SYSROOT := $(if $(BOARD),/build/$(BOARD),/)
SYSROOT ?= $(DEFAULT_SYSROOT)
BOARD ?= unknown
BUILD_LIBRARY_DIR ?= /mnt/host/source/src/scripts/build_library

# These are common paths we want to install files into.
RAMFS_LAYOUT_DIRS += bin etc lib root
RAMFS_BIN_DEPS ?= $(BIN_DEPS) $(EXTRA_BIN_DEPS)
GEN_INIT_CPIO = $(OUTPUT_DIR)/gen_init_cpio

# Settings for the build system.
BUILD_CC ?= gcc
BUILD_CFLAGS ?= -O1 -pipe
BUILD_CPPFLAGS ?=
BUILD_LDFLAGS ?=

.PHONY: all
all: $(RAMFS_BIN)

.PHONY: check
check:

.PHONY: clean
clean:
	rm -rf $(RAMFS_BIN) $(RAMFS_BIN).contents $(STAGE) $(GEN_INIT_CPIO)

$(RAMFS_BIN): $(GEN_INIT_CPIO)

$(GEN_INIT_CPIO): ../common/gen_init_cpio.c
	$(BUILD_CC) $(BUILD_CFLAGS) $(BUILD_CPPFLAGS) $(BUILD_LDFLAGS) $< -o $@

.PHONY: stage_init
stage_init: $(LOCAL_BIN_DEPS)
	rm -rf "$(STAGE)"
	mkdir -p "$(STAGE)"
	../common/process-layout \
		make \
		../common/fs-layout.txt "$(STAGE)"
	(cd $(STAGE); mkdir -p $(RAMFS_LAYOUT_DIRS))

	lddtree --verbose --copy-non-elfs --root="$(SYSROOT)" \
		--copy-to-tree="$(STAGE)" --bindir=/bin \
		$(RAMFS_BIN_DEPS)
ifneq ($(LOCAL_BIN_DEPS),)
	(cd $(OUTPUT_DIR); \
	 lddtree --verbose --copy-non-elfs --root="$(SYSROOT)" \
		--copy-to-tree="$(STAGE)" --bindir=/bin \
		$(notdir $(LOCAL_BIN_DEPS)) \
	)
endif
	cp $(SRCDIR)/init "$(STAGE)/init"
	cp \
		../common/init.sh \
		../common/dm_root_utils.sh \
		../common/fw_rollback_check.sh \
		"$(STAGE)/lib/"

# Generate /bin/write_gpt.sh.
# Args:
# 	$(1); image_type: The layout name used to look up partition info in disk
# 					  layout.
define generate_write_gpt_sh
	(BOARD=$(BOARD) BUILD_LIBRARY_DIR=$(BUILD_LIBRARY_DIR) bash -c \
	 ". $(BUILD_LIBRARY_DIR)/disk_layout_util.sh; \
	 write_partition_script $(1) $(STAGE)/bin/write_gpt.sh")
endef

define generate_initramfs
	../common/gen_initramfs_list.sh -u squash -g squash $(1) > $(2).contents
	../common/process-layout \
		filter \
		../common/fs-layout.txt $(2).contents
	$(GEN_INIT_CPIO) $(2).contents \
		$(if $(RAMFS_COMPRESS),| $(RAMFS_COMPRESS)) > $(2)
endef
define generate_ramfs
	$(call generate_initramfs,$(STAGE),$(RAMFS_BIN))
endef
