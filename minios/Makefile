# Copyright 2020 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

export MINIOS = 1

# Override so initramfs.mk doesn't use recovery directory.
export SRCDIR = $(CURDIR)

# Override so recovery/Makefile uses files with relative path to miniOS.
export RECOVERY_DIR = ../recovery

# Override so recovery/Makefile creates extra directories.
export MINIOS_RAMFS_LAYOUT_DIRS = \
	run/dbus

# Extra dependencies miniOS requires.
export MINIOS_BIN_DEPS = \
	/bin/mount \
	/bin/tail \
	/bin/tar \
	/bin/udevadm \
	/build/initramfs/bin/minios \
	/build/initramfs/bin/minios_client \
	/build/initramfs/bin/root_partition_for_recovery \
	/build/initramfs/bin/stateful_partition_for_recovery \
	/sbin/blockdev \
	/sbin/chromeos_startup \
	/sbin/dhclient \
	/sbin/dhclient-script \
	/sbin/dhcpcd \
	/sbin/init \
	/sbin/initctl \
	/sbin/iptables \
	/sbin/ip6tables \
	/sbin/losetup \
	/sbin/minijail0 \
	/sbin/mkfs.ext4 \
	/sbin/modprobe \
	/sbin/net_poll_tool \
	/sbin/poweroff \
	/sbin/reboot \
	/sbin/shutdown \
	/sbin/static_node_tool \
	/sbin/start \
	/sbin/status \
	/sbin/stop \
	/sbin/udevd \
	/sbin/usermode-helper \
	/usr/bin/awk \
	/usr/bin/coreutils \
	/usr/bin/cros_region_data \
	/usr/bin/curl \
	/usr/bin/dbus-daemon \
	/usr/bin/dbus-monitor \
	/usr/bin/dbus-send \
	/usr/bin/dbus-uuidgen \
	/usr/bin/ionice \
	/usr/bin/jq \
	/usr/bin/logger \
	/usr/bin/metrics_client \
	/usr/bin/ntfs-3g \
	/usr/bin/od \
	/usr/bin/openssl \
	/usr/bin/rootdev \
	/usr/bin/rsync \
	/usr/bin/scp \
	/usr/bin/shill \
	/usr/bin/ssh-keygen \
	/usr/bin/strace \
	/usr/bin/systemd-tmpfiles \
	/usr/bin/update_engine_client \
	/usr/bin/uptime \
	/usr/bin/wpa_cli \
	/usr/bin/wpa_debug \
	/usr/bin/wpa_passphrase \
	/usr/sbin/bootstat \
	/usr/sbin/chromeos-install \
	/usr/sbin/crda \
	/usr/sbin/rfkill \
	/usr/sbin/rsyslogd \
	/usr/sbin/screenshot \
	/usr/sbin/sshd \
	/usr/sbin/syslog-cat \
	/usr/sbin/update-ca-certificates \
	/usr/sbin/update_engine \
	/usr/sbin/wpa_supplicant

ifeq ($(INCLUDE_NVME_CLI),1)
MINIOS_BIN_DEPS += \
	/usr/sbin/nvme
endif

export MINIOS_LVM_BIN_DEPS = \
	/sbin/lvm \
	/sbin/lvmdump \
	/sbin/pdata_tools

export MINIOS_LVM_SYMLINKS = \
	lvchange \
	lvcreate \
	lvdisplay \
	lvmsadc \
	lvmsar \
	lvremove \
	lvrename \
	lvresize \
	lvs \
	lvscan \
	ntfs-3g \
	pvchange \
	pvcreate \
	pvdisplay \
	pvmove \
	pvremove \
	pvresize \
	pvs \
	pvscan \
	vgchange \
	vgconvert \
	vgcreate \
	vgdisplay \
	vgextend \
	vgremove \
	vgrename \
	vgs \
	vgscan

export MINIOS_PDATA_TOOLS_SYMLINKS = \
	thin_check \
	thin_delta \
	thin_dump \
	thin_ls \
	thin_metadata_size \
	thin_repair \
	thin_restore \
	thin_rmap \
	thin_trim

export MINIOS_DATA_DEPS = \
	/usr/share/chromeos-ssh-config/keys/authorized_keys \
	/usr/share/chromeos-ssh-config/keys/id_rsa.pub

.PHONY: all
all:
	$(MAKE) -C $(RECOVERY_DIR) $(MAKECMDGOALS)

.PHONY: check
check:
