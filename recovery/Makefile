# Copyright 2015 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Dependency list of binary programs.
BIN_DEPS = \
	/bin/busybox \
	/sbin/dmsetup \
	/sbin/frecon-lite \
	/usr/bin/eject \
	/usr/bin/pv \
	/usr/bin/futility \
	/usr/bin/crossystem \
	/usr/bin/tpmc \
	/usr/bin/cgpt \
	/usr/sbin/evwaitkey \
	/usr/sbin/flashrom \
	/usr/sbin/vpd

UNIBUILD ?= 1
ifeq ($(UNIBUILD),1)
BIN_DEPS += /usr/bin/crosid
endif

ifdef MINIOS_BIN_DEPS
BIN_DEPS += $(MINIOS_BIN_DEPS)
endif

# Override this value when including this Makefile.
RECOVERY_DIR ?= $(CURDIR)

# Extra dependency, should be set by builder configuration.
EXTRA_BIN_DEPS ?=

DATA_DEPS = \
	/usr/share/misc/chromeos-common.sh

ifdef MINIOS_DATA_DEPS
DATA_DEPS += $(MINIOS_DATA_DEPS)
endif

# Layout of directories to be created in initramfs.
RAMFS_LAYOUT_DIRS = \
	etc/screens \
	usr/share/misc \
	newroot \
	stateful \
	usb

ifdef MINIOS_RAMFS_LAYOUT_DIRS
RAMFS_LAYOUT_DIRS += $(MINIOS_RAMFS_LAYOUT_DIRS)
endif

INTERACTIVE_COMPLETE ?= true

# LOCALE_LIST can be overridden on the command line.  This feature
# is used in the ebuild to allow board-specific locale lists.
LOCALE_LIST =

# The region database installed by virtual/chromeos-regions, and will be used to
# generate the locales table.
CROS_REGIONS_DATABASE ?= $(SYSROOT)/usr/share/misc/cros-regions.json
LOCALES_TABLE ?= $(STAGE)/etc/locales.txt
CONFIG_FOLDER ?= $(STAGE)/etc/cros-initramfs

ifeq ($(LEGACY_UI),1)
UI = legacy_ui
ifeq ($(MINIOS),1)
UI = minios_ui
#$(error "Cannot build miniOS on legacy_ui")
endif
else
UI = menu_ui
ifeq ($(MINIOS),1)
UI = minios_ui
endif
endif

ifeq ($(LIBDIR),)
$(error "LIBDIR is undefined")
endif

include ../common/initramfs.mk

$(RAMFS_BIN): $(UI) stage_init
	$(RECOVERY_DIR)/make_locales "$(CROS_REGIONS_DATABASE)" >"$(LOCALES_TABLE)"
	ln -s busybox $(STAGE)/bin/env
	ln -s busybox $(STAGE)/bin/gzip
	ln -s busybox $(STAGE)/bin/sh
	ln -s futility "$(STAGE)/bin/dump_kernel_config"
	ln -s futility "$(STAGE)/bin/vbutil_kernel"
	sudo lddtree --verbose --copy-non-elfs --root=$(SYSROOT) \
		--copy-to-tree=$(STAGE) \
		$(DATA_DEPS)
	echo "INTERACTIVE_COMPLETE=$(INTERACTIVE_COMPLETE)" \
		>$(STAGE)/lib/completion_settings.sh
	mkdir -p "$(CONFIG_FOLDER)"
ifeq ($(UNIBUILD),1)
	SYSROOT="$(SYSROOT)" $(RECOVERY_DIR)/gen_recovery_config.sh $(CONFIG_FOLDER)
endif
ifeq ($(DETACHABLE),1)
	touch "$(CONFIG_FOLDER)/is_detachable"
endif
ifeq ($(OOBE_CONFIG),1)
	touch "$(CONFIG_FOLDER)/use_oobe_config"
endif
	$(call generate_write_gpt_sh,usb)
	$(call generate_ramfs)

.PHONY: legacy_ui
legacy_ui: stage_init
	cp "$(SYSROOT)/usr/share/chromeos-assets/images/boot_message_light.png" \
		legacy_ui/assets/*.png "$(STAGE)/etc/screens"
	legacy_ui/make_images localized_text "$(STAGE)/etc/screens" \
		$(LOCALE_LIST)
	cp *.sh legacy_ui/*.sh "$(STAGE)/lib"

.PHONY: menu_ui
menu_ui: stage_init
	$(RECOVERY_DIR)/menu_ui/make_images $(UI) \
		$(RECOVERY_DIR)/localized_text \
		"$(STAGE)/etc/screens" $(LOCALE_LIST)
	cp $(RECOVERY_DIR)/*.sh $(RECOVERY_DIR)/menu_ui/*.sh "$(STAGE)/lib"
	if [ "$(UNIBUILD)" -eq 1 ]; then \
		mkdir -p $(STAGE)/usr/share/chromeos-config;\
		cp $(SYSROOT)/usr/share/chromeos-config/identity.bin \
			"$(STAGE)/usr/share/chromeos-config/"; \
	fi

.PHONY: minios_ui
minios_ui: minios_lvm menu_ui minios stage_init

.PHONY: minios_lvm
minios_lvm: stage_init
	lddtree --verbose --copy-non-elfs --root="$(SYSROOT)" \
		--copy-to-tree="$(STAGE)" --bindir=/bin \
		$(MINIOS_LVM_BIN_DEPS)
	for lvm_symlink in $(MINIOS_LVM_SYMLINKS); do \
		ln -s lvm "$(STAGE)/bin/$$lvm_symlink"; \
	done
	for pdata_tools_symlink in $(MINIOS_PDATA_TOOLS_SYMLINKS); do \
		ln -s pdata_tools "$(STAGE)/bin/$$pdata_tools_symlink"; \
	done
	mkdir -p "$(STAGE)/etc/lvm/"
	cp -av "$(SYSROOT)/etc/lvm/lvm.conf" "$(STAGE)/etc/lvm/"

# TODO(b/177025106): Improve the build process to be more generic.
.PHONY: minios
minios: stage_init
	# FIRMWARE
	mkdir -p "$(STAGE)/lib/firmware"
	find "$(SYSROOT)/lib/firmware/" \
		\( -iname "rt*" \
		-o -iname "iwl*" \
		-o -iname "ath*" \
		-o -iname "regulatory*" \) \
		-exec cp -r "{}" "$(STAGE)/lib/firmware" \;
	if [ -d "$(SYSROOT)/lib/firmware/mediatek" ]; then \
		mkdir -p "$(STAGE)/lib/firmware/mediatek"; \
		cp -av "$(SYSROOT)/lib/firmware/mediatek/WIFI"* \
			"$(STAGE)/lib/firmware/mediatek"; \
	fi
	# KERNEL MODULES
	mkdir -p "$(STAGE)/lib/modules"
	cp -av "$(SYSROOT)/lib/modules/"* "$(STAGE)/lib/modules"
	(cd "$(STAGE)/lib/modules/"*"/kernel" && \
		find -maxdepth 1 \
		! -name drivers \
		! -name net \
		! -name fs \
		! -name crypto \
		! -name . -exec rm -rf {} +)
	(cd "$(STAGE)/lib/modules/"*"/kernel/drivers" && \
		find -maxdepth 1 \
		! -name net \
		! -name soc \
		! -name . -exec rm -rf {} +)
	(cd "$(STAGE)/lib/modules/"*"/kernel/fs" && \
		find -maxdepth 1 \
		! -name fat \
		! -name nls \
		! -name . -exec rm -rf {} +)
	# MISC.
	# use busybox as the default shell for all users
	sed "s|/bin/bash|/bin/sh|" \
		"$(SYSROOT)/etc/passwd" > "$(STAGE)/etc/passwd"
	cp "$(SYSROOT)/etc/group" \
		"$(SYSROOT)/etc/nsswitch.conf" "$(STAGE)/etc"
	mkdir -p "$(STAGE)/usr/share/X11/xkb"
	cp -r "$(SYSROOT)/usr/share/X11/xkb"* "$(STAGE)/usr/share/X11"
	# MISSING SHARED LIBS
	mkdir -p "$(STAGE)/$(LIBDIR)"
	cp -av "$(SYSROOT)/$(LIBDIR)/libnss"* "$(STAGE)/$(LIBDIR)/"
	cp -av "$(SYSROOT)/$(LIBDIR)/libminijail"* "$(STAGE)/$(LIBDIR)/"
	# DBUS
	mkdir -p "$(STAGE)/etc/dbus-1"
	cp -av "$(SYSROOT)/etc/dbus-1/"* \
		"$(STAGE)/etc/dbus-1/"
	cp -av "$(SYSROOT)/build/initramfs/etc/dbus-1/"* \
		"$(STAGE)/etc/dbus-1/"
	mkdir -p "$(STAGE)/usr/share/dbus-1"
	cp -av "$(SYSROOT)/usr/share/dbus-1/"* \
		"$(STAGE)/usr/share/dbus-1/"
	# SHILL
	mkdir -p "$(STAGE)/usr/share/cros/init"
	cp -av "$(SYSROOT)/usr/share/cros/init/shill-pre-start.sh" \
		"$(SYSROOT)/usr/share/cros/init/shill.sh" \
		"$(SYSROOT)/usr/share/cros/init/shill-event.sh" \
		"$(STAGE)/usr/share/cros/init/"
	mkdir -p "$(STAGE)/usr/include/chromeos/dbus"
	cp -ab "$(SYSROOT)/usr/include/chromeos/dbus/shill" \
		"$(STAGE)/usr/include/chromeos/dbus/"
	mkdir -p "$(STAGE)/usr/share/shill"
	cp -av "$(SYSROOT)/usr/share/shill/"* \
		"$(STAGE)/usr/share/shill/"
	mkdir -p "$(STAGE)/usr/$(LIBDIR)/shill"
	cp -av "$(SYSROOT)/usr/$(LIBDIR)/shill/"* \
		"$(STAGE)/usr/$(LIBDIR)/shill/"
	# Add json mapping from region to xkb layout.
	cp -av "$(CROS_REGIONS_DATABASE)" "$(STAGE)/usr/share/misc/cros-regions.json"
	# Copy the /etc/lsb-release file, during non-build_image flows this file might
	# be missing.
	mkdir -p "$(STAGE)/etc"
	cp -av "$(SYSROOT)/build/initramfs/etc/lsb-release" "$(STAGE)/etc/" | true
	# Add conf files for upstart to pickup.
	mkdir -p "$(STAGE)/etc/init"
	cp -av "$(SYSROOT)/build/initramfs/etc/init/"* \
		"$(SYSROOT)/etc/init/dbus.conf" \
		"$(SYSROOT)/etc/init/nebraska.conf" \
		"$(SYSROOT)/etc/init/iptables.conf" \
		"$(SYSROOT)/etc/init/ip6tables.conf" \
		"$(SYSROOT)/etc/init/network-services.conf" \
		"$(SYSROOT)/etc/init/pre-shutdown.conf" \
		"$(SYSROOT)/etc/init/reboot.conf" \
		"$(SYSROOT)/etc/init/shill.conf" \
		"$(SYSROOT)/etc/init/wpasupplicant.conf" \
		"$(STAGE)/etc/init/"
	mkdir -p "$(STAGE)/usr/lib/tmpfiles.d"
	cp -av "$(SYSROOT)/usr/lib/tmpfiles.d/"* \
		"$(STAGE)/usr/lib/tmpfiles.d/"
	# D-Bus and logging dependencies for upstart.
	mkdir -p "$(STAGE)/var/lib/metrics"
	mkdir -p "$(STAGE)/usr/$(LIBDIR)/rsyslog"
	cp -av "$(SYSROOT)/usr/$(LIBDIR)/rsyslog/"* "$(STAGE)/usr/$(LIBDIR)/rsyslog"
	cp -av "$(SYSROOT)/etc/rsyslog.chromeos" "$(STAGE)/etc"
	mkdir -p "$(STAGE)/usr/lib/systemd"
	cp -av "$(SYSROOT)/usr/lib/systemd/"* "$(STAGE)/usr/lib/systemd"
	# Add policy files for init.
	cp -av "$(SYSROOT)/$(LIBDIR)/libselinux"* "$(STAGE)/$(LIBDIR)/"
	cp -av "$(SYSROOT)/usr/$(LIBDIR)/libselinux"* "$(STAGE)/usr/$(LIBDIR)/"
	if [ -d "$(SYSROOT)/etc/selinux" ]; then \
		mkdir -p "$(STAGE)/etc/selinux"; \
		rsync -av "$(SYSROOT)/etc/selinux/"* "$(STAGE)/etc/selinux/"; \
	fi
	# Add marker file to indicate we are running from MiniOs.
	touch "$(STAGE)/etc/minios"
	# CrOS-install dependencies.
	cp -av "$(SYSROOT)/usr/share/misc/shflags" "$(STAGE)/usr/share/misc"
	cp -av "$(SYSROOT)/usr/share/misc/lvm-utils.sh" "$(STAGE)/usr/share/misc"
	cp -av "$(SYSROOT)/usr/share/misc/chromeos-common.sh" \
		"$(STAGE)/usr/share/misc"
	mkdir -p "$(STAGE)/usr/share/syslinux"
	cp -av "$(SYSROOT)/usr/share/syslinux/gptmbr.bin" \
		"$(STAGE)/usr/share/syslinux/" || true
	# Update engine dependencies.
	mkdir -p "$(STAGE)/usr/share/update_engine"
	cp -av "$(SYSROOT)/build/initramfs/update-payload-key.pub.pem" \
		"$(STAGE)/usr/share/update_engine"
	cp -av "$(SYSROOT)/usr/share/chromeos-ca-certificates" "$(STAGE)/usr/share"

	# Udev trigger loading modules + saving networking modules for preloading.
	cp -av "$(SYSROOT)/lib/udev" "$(STAGE)/lib/"
	cp -av "$(SYSROOT)/etc/init/failsafe.conf" \
		"$(SYSROOT)/etc/init/failsafe-delay.conf" \
		"$(SYSROOT)/etc/init/preload-network.conf" \
		"$(SYSROOT)/etc/init/udev.conf" \
		"$(SYSROOT)/etc/init/udev-boot.conf" \
		"$(SYSROOT)/etc/init/udev-trigger.conf" \
		"$(SYSROOT)/etc/init/udev-trigger-early.conf" \
		"$(STAGE)/etc/init/"
	# Connecting to wifi.
	# TODO(b/169261043): Cleanup and organize these dependencies.
	#   Look into target-initramfs as the final solution.
	sudo cp -av "$(SYSROOT)/usr/$(LIBDIR)/libgio"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libgobject"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libgmodule"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libffi"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libgthread"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libz"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libssl"* \
		"$(SYSROOT)/usr/$(LIBDIR)/engine"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libchaps"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libp11"* \
		"$(SYSROOT)/usr/$(LIBDIR)/xtables"* \
		"$(STAGE)/usr/$(LIBDIR)/"
	mkdir -p "$(STAGE)/etc/ssl"
	sudo cp -av "$(SYSROOT)/etc/ssl/"* \
		"$(STAGE)/etc/ssl/"
	mkdir -p "$(STAGE)/etc/ssh"
	sudo cp -av "$(SYSROOT)/build/initramfs/etc/ssh/"* \
		"$(STAGE)/etc/ssh/"
	mkdir -p "$(STAGE)/root/.ssh"
	sudo cp -av "$(SYSROOT)/root/.ssh/"* \
		"$(STAGE)/root/.ssh"
	mkdir -p "$(STAGE)/usr/share/policy"
	sudo cp -av "$(SYSROOT)/usr/share/policy/wpa_supplicant.bpf" \
		"$(STAGE)/usr/share/policy/"
	# DHCPCD related files.
	cp -av "$(SYSROOT)/$(LIBDIR)/dhcpcd"* "$(STAGE)/$(LIBDIR)/"
	cp -av "$(SYSROOT)/etc/dhcpcd.conf" \
		"$(STAGE)/etc/"
	# TODO(b/316191866): Remove manual linking and run dns-proxy and
	#   patchpaneld in minios.
	ln -s  "/run/shill/resolv.conf" "$(STAGE)/etc/resolv.conf"
	# Screenshot util dependencies.
# Don't use screenshot for WhaleOS,
# becase of image size
#	mkdir -p "$(STAGE)/usr/$(LIBDIR)/dri"
#	cp -av "$(SYSROOT)/usr/$(LIBDIR)/dri/"* \
		"$(STAGE)/usr/$(LIBDIR)/dri/" || true
#	cp -av "$(SYSROOT)/usr/$(LIBDIR)/libminigbm"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libglapi"* \
		"$(SYSROOT)/usr/$(LIBDIR)/libEGL"* \
		"$(STAGE)/usr/$(LIBDIR)/" || true
#	mkdir -p "$(STAGE)/usr/share/glvnd"
#	cp -av "$(SYSROOT)/usr/share/glvnd/"* \
		"$(STAGE)/usr/share/glvnd/" || true
	# Mount helpers.
	ln -s "/usr/bin/ntfs-3g" "$(STAGE)/sbin/mount.ntfs-3g"
	ln -s "/usr/bin/ntfs-3g" "$(STAGE)/sbin/mount.ntfs"
