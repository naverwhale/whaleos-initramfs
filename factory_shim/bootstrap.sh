#!/bin/busybox sh
# Copyright 2015 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# To bootstrap the factory installer on rootfs. This file must be executed as
# PID=1 (exec).
# Note that this script uses the busybox shell (not bash, not dash).
set -x

. /usr/sbin/factory_tty.sh

# USB card partition and mount point.
USB_MNT=/usb
REAL_USB_DEV=

NEWROOT_MNT=/newroot

LOG_DEV=
LOG_DIR=/log
LOG_FILE=${LOG_DIR}/factory_initramfs.log

# Size of the root ramdisk.
TMPFS_SIZE=1024M

# Special file systems required in addition to the root file system.
BASE_MOUNTS="/sys /proc /dev"

# To be updated to keep logging after move_mounts.
TAIL_PID=

. /lib/dm_root_utils.sh

. /lib/fw_rollback_check.sh

# Print message on both main TTY and log file.
log() {
  echo "$@" | tee -a "${TTY}" "${LOG_FILE}" >&2
}

# Like log() but with printf() semantics.
logf() {
  printf "$@" | tee -a "${TTY}" "${LOG_FILE}" >&2
}

# For factory shim, debug messages are logged to the same place.
dlog() {
  log "$@"
}

dlogf() {
  logf "$@"
}

is_cros_debug() {
  grep -qw cros_debug /proc/cmdline 2>/dev/null
}

invoke_terminal() {
  local tty="$1"
  local title="$2"
  shift
  shift
  # Copied from factory_installer/factory_shim_service.sh.
  echo "${title}" >>${tty}
  setsid sh -c "exec script -afqc '$*' /dev/null <${tty} >>${tty} 2>&1 &"
}

enable_debug_console() {
  local tty="$1"
  if ! is_cros_debug; then
    log "To debug, add [cros_debug] to your kernel command line."
  elif [ "${tty}" = /dev/null ] || ! tty_is_valid "${tty}"; then
    # User probably can't see this, but we don't have better way.
    log "Please set a valid [console=XXX] in kernel command line."
  else
    log -e '\033[1;33m[cros_debug] enabled on '${tty}'.\033[m'
    invoke_terminal "${tty}" "[Bootstrap Debug Console]" "/bin/busybox sh"
  fi
}

on_error() {
  trap - EXIT
  log -e '\033[1;31m'
  log "ERROR: Factory installation aborted."
  save_log_files
  enable_debug_console "${TTY}"
  sleep 1d
  exit 1
}

is_good_rootfs_partition() {
  local root_dev="$1"

  local sector_count
  sector_count="$(cat "/sys/class/block/$(basename "${root_dev}")/size")"

  local sector_count_threshold=1

  [ "${sector_count}" -gt "${sector_count_threshold}" ]
}

# Look for a device with our GPT ID.
wait_for_gpt_root() {
  [ -z "$KERN_ARG_KERN_GUID" ] && return 1
  log -n "Looking for rootfs using kern_guid [${KERN_ARG_KERN_GUID}]... "
  local try kern_dev kern_num
  local root_dev root_num
  for try in $(seq 20); do
    log -n ". "
    # crbug.com/463414: when the cgpt supports MTD (cgpt.bin), redirecting its
    # output will get duplicated data.
    kern_dev="$(cgpt find -1 -u $KERN_ARG_KERN_GUID 2>/dev/null | uniq)"
    kern_num=${kern_dev##[/a-z]*[/a-z]}
    # The order of offset to try matters.  We have to try +1 before trying -1.
    # The disk layout should look like:
    #   partition 1: stateful partition
    #   partition 2: KERN-A  # This is paired with ROOT-A.
    #   partition 3: ROOT-A
    #   partition 4: KERN-B  # This is also paired with ROOT-A.
    #   partition 5: ROOT-B  # This is empty.
    # The order trying +1 before trying -1 works for both KERN-A and KERN-B.
    for offset in 1 -1; do
      root_num=$(( kern_num + ${offset} ))
      root_dev="${kern_dev%${kern_num}}${root_num}"
      if [ -b "${root_dev}" ] && is_good_rootfs_partition "${root_dev}"; then
        USB_DEV="${root_dev}"
        log "Found ${USB_DEV}"
        return 0
      fi
    done
    sleep 1
  done
  log "Failed waiting for device with correct kern_guid."
  return 1
}

# Attempt to find the root defined in the signed factory shim
# kernel we're booted into to. Exports REAL_USB_DEV if there
# is a root partition that may be used - on succes or failure.
find_official_root() {
  log -n "Checking for an official root... "

  # Check for a kernel selected root device or one in a well known location.
  wait_for_gpt_root || return 1

  # Now see if it has a Chrome OS rootfs partition.
  cgpt find -t rootfs "$(strip_partition "$USB_DEV")" || return 1
  REAL_USB_DEV="$USB_DEV"

  # USB_DEV points to the rootfs partition of removable media. And its value
  # can be one of /dev/sda3 (arm), /dev/sdb3 (x86, arm) and /dev/mmcblk1p3
  # (arm). Get stateful partition by replacing partition number with "1".
  LOG_DEV="${USB_DEV%%[0-9]*}"1  # Default to stateful.

  mount_rootfs
}

mount_rootfs() {
  log -n "Mounting rootfs... "
  local usb_dev
  local kernel_command_line="$(cat /proc/cmdline)"

  if is_cros_debug; then
    log "is_cros_debug, use ${USB_DEV} as rootfs"
    usb_dev="${USB_DEV}"
  else
    # Always try to setup dm root when cros_debug is not set.
    setup_dm_root "${kernel_command_line}" "${USB_DEV}" || return 1
    usb_dev="${DM_DEV}"
  fi

  for try in $(seq 20); do
    log -n ". "
    if mount -n -o ro "$usb_dev" "$USB_MNT"; then
      log "OK."
      return 0
    fi
    sleep 1
  done
  log "Failed to mount $usb_dev!"
  return 1
}

unmount_usb() {
  log "Unmounting ${USB_MNT}..."
  umount -n "${USB_MNT}"
  log ""
  log "$REAL_USB_DEV can now be safely removed."
  log ""
}

strip_partition() {
  local dev="${1%%[0-9]*}"
  # handle mmcblk0p case as well
  echo "${dev%p*}"
}

# Saves log files stored in LOG_DIR in addition to demsg to the device specified
# (/ of stateful mount if none specified).
save_log_files() {
  # The recovery stateful is usually too small for ext3.
  # TODO(wad) We could also just write the data raw if needed.
  #           Should this also try to save
  local log_dev="${1:-$LOG_DEV}"
  [ -z "$log_dev" ] && return 0

  log "Dumping dmesg to $LOG_DIR"
  dmesg >"$LOG_DIR"/dmesg

  local err=0
  local save_mnt=/save_mnt
  local save_dir_name="factory_shim_logs"
  local save_dir="${save_mnt}/${save_dir_name}"

  log "Saving log files from: $LOG_DIR -> $log_dev $(basename ${save_dir})"
  mkdir -p "${save_mnt}"
  mount -n -o sync,rw "${log_dev}" "${save_mnt}" || err=$?
  [ ${err} -ne 0 ] || rm -rf "${save_dir}" || err=$?
  [ ${err} -ne 0 ] || cp -r "${LOG_DIR}" "${save_dir}" || err=$?
  # Attempt umount, even if there was an error to avoid leaking the mount.
  umount -n "${save_mnt}" || err=1

  if [ ${err} -eq 0 ] ; then
    log "Successfully saved the log file."
    log ""
    log "Please remove the USB media, insert into a Linux machine,"
    log "mount the first partition, and find the logs in directory:"
    log "  ${save_dir_name}"
  else
    log "Failures seen trying to save log file."
  fi
}

stop_log_file() {
  # Drop logging
  exec >"${TTY}" 2>&1
  [ -n "$TAIL_PID" ] && kill $TAIL_PID
}

# Extract and export kernel arguments
export_args() {
  # We trust our kernel command line explicitly.
  local arg=
  local key=
  local val=
  local acceptable_set='[A-Za-z0-9]_'
  log "Exporting kernel arguments..."
  for arg in "$@"; do
    key=$(echo "${arg%%=*}" | tr 'a-z' 'A-Z' | \
                   tr -dc "$acceptable_set" '_')
    val="${arg#*=}"
    export "KERN_ARG_$key"="$val"
    log -n " KERN_ARG_$key=$val,"
  done
  log ""
}

mount_tmpfs() {
  log "Mounting tmpfs..."
  mount -n -t tmpfs tmpfs "$NEWROOT_MNT" -o "size=$TMPFS_SIZE"
}

copy_contents() {
  log "Copying contents of USB device to tmpfs... "
  tar -cf - -C "${USB_MNT}" . | pv -f 2>"${TTY}" | tar -xf - -C "${NEWROOT_MNT}"
}

patch_new_root() {
  # Create an early debug terminal if available.
  if is_cros_debug && [ -n "${DEBUG_TTY}" ]; then
    log "Adding debug console service..."
    file="${NEWROOT_MNT}/etc/init/debug_console.conf"
    echo "# Generated by factory shim.
      start on startup
      console output
      respawn
      pre-start exec printf '\n[Debug Console]\n' >${DEBUG_TTY}
      exec script -afqc '/bin/bash' /dev/null" >"${file}"
    if [ "${DEBUG_TTY}" != /dev/console ]; then
      rm -f /dev/console
      ln -s "${DEBUG_TTY}" /dev/console
    fi
  fi

  local bootstrap="${NEWROOT_MNT}/usr/sbin/factory_bootstrap.sh"
  local flag="/tmp/bootstrap.failed"
  if [ -x "${bootstrap}" ]; then
    rm -f "${flag}"
    log "Running ${bootstrap}..."
    # Return code of "a|b" is will be b instead of a, so we have to touch a flag
    # file to check results.
    ("${bootstrap}" "${NEWROOT_MNT}" "${REAL_USB_DEV}" || touch "${flag}") \
      | tee -a "${TTY}" "${LOG_FILE}"
    if [ -e "${flag}" ]; then
      return 1
    fi
  fi
}

move_mounts() {
  log "Moving $BASE_MOUNTS to $NEWROOT_MNT"
  for mnt in $BASE_MOUNTS; do
    # $mnt is a full path (leading '/'), so no '/' joiner
    mkdir -p "$NEWROOT_MNT$mnt"
    mount -n -o move "$mnt" "$NEWROOT_MNT$mnt"
  done

  # Adjust /dev files.
  TTY="${NEWROOT_MNT}${TTY}"
  LOG_TTY="${NEWROOT_MNT}${LOG_TTY}"
  [ -z "${LOG_DEV}" ] || LOG_DEV="${NEWROOT_MNT}${LOG_DEV}"

  # Make a copy of bootstrap log into new root.
  mkdir -p "${NEWROOT_MNT}${LOG_DIR}"
  cp -f "${LOG_FILE}" "${NEWROOT_MNT}${LOG_FILE}"
  log "Done."
}

use_new_root() {
  move_mounts

  # Chroot into newroot, erase the contents of the old /, and exec real init.
  log "About to switch root... Check VT2/3/4 if you stuck for a long time."
  stop_log_file

  # If you have problem getting console after switch_root, try to debug by:
  #  1. Try a simple shell.
  #     exec <"${TTY}" >"${TTY}" 2>&1
  #     exec switch_root "${NEWROOT_MNT}" /bin/sh
  #  2. Try to invoke factory installer directly
  #     exec switch_root "${NEWROOT_MNT}" /usr/sbin/factory_shim_service.sh

  # -v prints upstart info in kmsg (available in INFO_TTY).
  exec switch_root "${NEWROOT_MNT}" /sbin/init -v --default-console output
}

main() {
  # Setup environment.
  tty_init
  if [ -z "${LOG_TTY}" ]; then
    LOG_TTY=/dev/null
  fi

  mkdir -p "${USB_MNT}" "${LOG_DIR}" "${NEWROOT_MNT}"

  exec >"${LOG_FILE}" 2>&1
  log "...:::||| Bootstrapping ChromeOS Factory Shim |||:::..."
  log "TTY: ${TTY}, LOG: ${LOG_TTY}, INFO: ${INFO_TTY}, DEBUG: ${DEBUG_TTY}"

  # Send all verbose output to debug TTY.
  (tail -f "${LOG_FILE}" >"${LOG_TTY}") &
  TAIL_PID="$!"

  # Export the kernel command line as a parsed blob prepending KERN_ARG_ to each
  # argument.
  export_args $(cat /proc/cmdline | sed -e 's/"[^"]*"/DROPPED/g')

  if [ -n "${INFO_TTY}" -a -e /dev/kmsg ]; then
    log "Kernel messages available in ${INFO_TTY}."
    cat /dev/kmsg >>"${INFO_TTY}" &
  fi

  # DEBUG_TTY may be not available, but we don't have better choices on headless
  # devices.
  enable_debug_console "${DEBUG_TTY}"

  # Verify FW version.
  verify_fw_version

  find_official_root

  log "Bootstrapping factory shim."
  # Copy rootfs contents to tmpfs, then unmount USB device.
  mount_tmpfs
  copy_contents

  # Apply all patches for bootstrap into new rootfs.
  patch_new_root

  # USB device is unmounted, we can remove it now.
  unmount_usb
  remove_dm_root

  # Kill all running terminals. Comment this line if you need to keep debug
  # console open for debugging.
  killall less script || true

  # Switch to the new root.
  use_new_root

  # Should never reach here.
  return 1
}

trap on_error EXIT
set -e
main "$@"
