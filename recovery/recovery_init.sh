# Copyright 2011 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This consists of functions sourced by the /init script and used
# exclusively for recovery images.  Note that this code uses the
# busybox shell (not bash, not dash).

# Include disk information.
. /usr/sbin/write_gpt.sh
# Include firmware rollback check functions.
. /lib/fw_rollback_check.sh

# Starting kernel rollback version.
KERNEL_VER_MIN=0x10001
# TPM NVRAM index where the rollback kernel version is stored.
KERNEL_VER_TPM_NV_SPACE=0x1008
# TPM NVRAM index for the lockbox.
LOCKBOX_TPM_NV_SPACE=0x20000004
# Where chromeos-install will store any related hardware diagnostics data.
LOG_HARDWARE_DIAGNOSTICS=hardware_diagnostics.log
# Minimum battery charge required for TPM firmware update.
MIN_BATTERY_CHARGE_PERCENT=10
# "E" key on the keyboard
EVWAITKEY_KEY=18
# Path of the file where the EVWAITKEY is written if it is pressed.
EVWAITKEY_FILE=/tmp/check_for_reload_key
# If disk wipe is requested, the result is stored here.
DISK_WIPE_RESULT=


# Installation Target.
#  DST_DEV_BASE: A device path for concatenate partition number.
#                Sample: /dev/mmcblk0p /dev/sda
#                Usage: "${DST_DEV_BASE}${PART_NUM}"
#  DST: A device path for the block device itself (similar to rootdev -d).
#                Sample: /dev/mmcblk0 /dev/sda
DST_DEV_BASE=
DST=


# Error codes used as return code by functions to indicate installation
# should be aborted for the corresponding reason.

# Indicates a failure validating the kernel.
ERR_INVALID_INSTALL_KERNEL=2

# The image failed validation on a device with block_devmode=1.
ERR_DEV_MODE_BLOCKED=3


# Check whether the device owner has configured the device to block
# developer mode.  Note that the check works regardless of whether the
# device is currently booted in developer mode or not.
#
# This check is used to enforce the block_devmode flag.  The regular boot
# path checks the flag in chromeos_startup, which resides in the root.
# Hence, only official kernels and roots that are guaranteed to perform the
# check can be allowed to be installed - otherwise developer mode blocking
# is easily circumvented by installing an unofficial kernel or root that
# doesn't perform the block_devmode check.
is_developer_mode_blocked() {
  # The device should refuse operation in developer mode if the device
  # owner has flipped the block_devmode flag to 1.  We still block
  # even if firmware write protection is disabled, because removing a
  # screw is simpler than hooking up a different disk or using a
  # dediprog to reprogram the flash directly.
  if crossystem 'block_devmode?1'; then
    return 0
  fi
  [ "$(vpd -i RW_VPD -g block_devmode)" = "1" ]
}

# Verifies the recovery root by reading all blocks of the dm-verity
# block device.  Return code indicates whether verification succeeded.
verify_recovery_root() {
  local usb_base=$(basename "$USB_DEV")
  local size=$(( 512 * $(cat /sys/block/$usb_base/size) ))

  # Ensure the verified rootfs is fully intact or fail with no USB_DEV.
  # REAL_USB_DEV is left intact.
  #
  # Correctness wins over speed for this.  Correctness also wins
  # over readability.  :-(
  #
  # High level summary:  The 'pv -n' command copies bytes from stdin
  # to stdout, and periodically prints *to stderr* the amount read
  # as a percentage of the size in the '-s' option.  The pipeline
  # redirects the stderr from 'pv' into stdin of 'progress_bar'.
  # This usage is covered in the pv(1) man page, which rightly warns
  # that "it may cause the programmer to overheat."
  (
    # The 'set -x' output goes to stderr, which would become input
    # to 'progress_bar', below.  Turn it off in a subshell so as not
    # to affect the main process.
    set +x
    (
      (
        # This 'dd' is the actual validation.  We must capture the
        # exit code in order to figure out whether it passed or not.
        dd if="$USB_DEV" bs=$((16 * 1024 * 1024)) 2>/dev/null
        echo $? >/tmp/verification_status
      ) | pv -n -s $size >/dev/null
    ) 2>&1 | ( set -x ; progress_bar ) >$LOG_DIR/progress.log 2>&1
  )
  if [ "$(cat /tmp/verification_status)" != "0" ]; then
    dlog "Included root filesystem could not be verified."
    return 1
  fi
  return 0
}

# Checks that we have a valid recovery root before handing it off to the
# installer.
validate_recovery_root() {
  # Allow test recovery roots that are unverified unless developer mode
  # is blocked by the device owner.
  if [ "$USB_DEV" != "/dev/dm-0" ] || is_unofficial_root; then
    is_developer_mode_blocked && return $ERR_DEV_MODE_BLOCKED
    return 0
  fi

  # Perform a full device mapper root validation to avoid any unexpected
  # failures during postinst.  It also allows us to detect if the root
  # is intentionally mismatched - such as during Chromium OS recovery
  # with a Chrome OS recovery kernel.
  verify_recovery_root && return 0

  # Verification failed. Only proceed in developer mode.
  is_developer_mode || return 1

  # If developer mode is blocked, don't allow an unverified root.
  is_developer_mode_blocked && return $ERR_DEV_MODE_BLOCKED

  # The root we just mounted looked like an official recovery image, but
  # it didn't pass validation.  Try to fall back to installing a
  # developer image.
  umount "${USB_MNT}"
  remove_dm_root
  USB_DEV=

  find_developer_root || return 1
  get_stateful_dev || return 1

  message developer_image

  return 0
}

get_dst() {
  load_base_vars
  DST="$(get_fixed_dst_drive)"
  if [ -z "${DST}" ]; then
    dlog "SSD for installation not specified"
    return 1
  fi
  if [ "${DST%[0-9]}" = "${DST}" ]; then
    # ex, sda => sda1, sdb1
    DST_DEV_BASE="${DST}"
  else
    # ex, mmcblk0 => mmcblk0p1
    DST_DEV_BASE="${DST}p"
  fi
  local src_dev_base="${REAL_USB_DEV%[0-9]*}"
  if [ "${src_dev_base}" = "${DST_DEV_BASE}" ]; then
    dlog "Cannot find SSD for installation."
    return 1
  fi
  SRC_DEV_BASE="${src_dev_base}"
}

# Checks whether a given key block is also a valid key block used to
# sign a kernel currently installed on the destination block device.
check_install_kernel_key_match() {
  dlogf "Searching the system disk for a matching kernel key . . ."
  if ! cgpt find -t kernel -M "$1" "$DST"; then
    dlog " failed."
    return 1
  fi
  dlog " found."

  dlogf "Validating matching signature(s) . . ."
  # If we found a keyblock, at the right offset, make sure it actually signed
  # the subsequent payload.
  local kdev=
  for kdev in $(cgpt find -t kernel -M "$1" "${DST}"); do
    dlogf " ."
    verify_kernel_signature "$kdev" "/tmp/kern.keyblock" || continue
    dlog " done."
    return 0
  done

  dlog " failed."
  return 1
}

clear_eventlog() {
  flashrom -E -i RW_ELOG
}

# Check EVWAITKEY is pressed and if it is, perfom full disk wipe.
check_disk_wipe_requested() {
  local evwaitkey_output=$(cat "${EVWAITKEY_FILE}")
  if [ "${evwaitkey_output}" = "${EVWAITKEY_KEY}" ]; then
    # If EVWAITKEY is pressed, perform full disk wipe.
    dlog "Key is pressed, disks will be physically wiped."
    message disk_wipe_start
    chroot "${USB_MNT}" /usr/sbin/wipe_disk
    DISK_WIPE_RESULT=$?
    clear_eventlog
    message disk_wipe_end
  fi
  rm "${EVWAITKEY_FILE}"
}

# Get the kernel version by directly reading the TPM NVRAM spaces.
# Use this instead of `crossystem tpm_kernver` because the version returned by
# crossystem is advanced in recovery mode even though the version in the TPM is
# not (see b/266502803#comment25).
get_kernelver_from_tpmc () {
  set -- $(tpmc read $KERNEL_VER_TPM_NV_SPACE 9)
  # Struct reference: `struct vb2_secdata_kernel_v0/1` in
  # vboot_reference/firmware/2lib/include/2secdata_struct.h
  #
  # Example output:
  #
  # v0.* - kernel version is bytes 6-9
  # 1 4c 57 52 47 1 0 1 0
  #
  # v1.* - kernel version is bytes 5-8
  # 10 28 f2 a 1 0 1 0 34
  #
  # The full kernel version is stored as a 32-bit integer in little
  # endian format.
  local struct_version=$(printf "%d" "0x$1")
  if [ ${struct_version} -lt 16 ]; then
    shift 1
  fi
  printf "0x%x" "$(( $8 << 24 | $7 << 16 | $6 << 8 | $5 ))"
}

verify_kernel_signature() {
  local kern_dev="$1"
  local keyblock="$2"

  # Validates the signature and outputs a keyblock.
  if ! vbutil_kernel --verify "$kern_dev" --keyblock "$keyblock"; then
    return 1
  fi
  return 0
}

verify_kernel_version() {
  local kern_dev="$1"
  local minversion="$KERNEL_VER_MIN"

  # Get the currently set TPM NVRAM rollback versions.
  minversion=$(get_kernelver_from_tpmc)
  dlog "Rollback version stored in the TPM: $minversion"

  # Validate the signature and rollback versions.
  if ! vbutil_kernel --verify "$kern_dev" --minversion "$minversion"; then
    return 1
  fi
  return 0
}

verify_install_kernel() {
  # TODO(wad) check signatures from stateful on kern b using the
  #           root of trust instead of using a baked in cmdline.
  if [ "$REAL_KERN_B_HASH" != "$KERN_ARG_KERN_B_HASH" ]; then
    # Assertion: we have to be in developer mode; this was verified in the
    # course of the general init process.
    is_developer_mode || return 1

    # Only allow verified kernels when developer mode blocking is on.
    is_developer_mode_blocked && return $ERR_DEV_MODE_BLOCKED

    message developer_image

    # Extract the kernel so that vbutil_kernel will happily consume it.
    dlog "Checking the install kernel for a valid developer signature . . ."
    verify_kernel_signature "$KERN_B_CACHE" "/tmp/kern_b.keyblock" || return 1
    check_install_kernel_key_match /tmp/kern_b.keyblock || message key_change
    return 0
  fi

  # Looks like we have an official recovery image. Check for version rollback.
  dlog "Checking the install kernel for valid versions and signature . . ."
  if ! verify_kernel_version "$KERN_B_CACHE"; then
    # Rollback version check failure is fatal if we are not in developer mode.
    is_developer_mode || return $ERR_INVALID_INSTALL_KERNEL

    # Don't allow version downgrades when developer mode blocking is on.
    is_developer_mode_blocked && return $ERR_DEV_MODE_BLOCKED

    message warn_invalid_install_kernel
  fi

  return 0
}

setup_install_mounts() {
  mount -t tmpfs -o mode=1777 none "${USB_MNT}/tmp" || return 1
  mount -t tmpfs -o mode=0755 run "${USB_MNT}/run" || return 1
  mkdir -p -m 0755 "${USB_MNT}/run/lock" || return 1

  dlog "Re-binding $BASE_MOUNTS for $NEWROOT_MNT"
  for mnt in $BASE_MOUNTS; do
    # $mnt is a full path (leading '/'), so no '/' joiner
    mkdir -p "$NEWROOT_MNT$mnt"
    mount -n -o bind "$mnt" "$NEWROOT_MNT$mnt" || return 1
  done
  dlog "Done."
  return 0
}

cleanup_install_mounts() {
  dlog "Unmounting $BASE_MOUNTS in $NEWROOT_MNT"
  for mnt in $BASE_MOUNTS; do
    # $mnt is a full path (leading '/'), so no '/' joiner
    umount "$NEWROOT_MNT$mnt"
  done
  dlog "Done."
  umount "${USB_MNT}/run"
  umount "${USB_MNT}/tmp"
  return 0
}

call_image_recovery_script() {
  dlog "Installing software; this will take some time."
  dlog "See the debug log on VT3 for the full output."

  # Prevent accidentally loading modules from the usb mount
  echo 1 >/proc/sys/kernel/modules_disabled

  chroot "${USB_MNT}" /usr/sbin/chromeos-recovery "$@"
  local install_status=$?
  if [  $install_status -ne 0 ]; then
    dlog "WARNING!!! Installation of software failed. Displaying hw diagnostics"
    local diagnostics_file="${USB_MNT}/tmp/$LOG_HARDWARE_DIAGNOSTICS"
    if [ -f "$diagnostics_file" ]; then
      cp "$diagnostics_file" "$LOG_DIR"
      dlog \
"============================ HARDWARE DIAGNOSTICS =========================="
      dlog $(cat "$diagnostics_file")
      dlog "See recovery log for more information."
      dlog \
"============================================================================"
      dlog
    else
      dlog "Missing hardware diagnostics."
    fi
  fi

  return $install_status
}

clobber_lockbox_space() {
  # Clobber the lockbox space, by defining a new space at the same index.
  # Protection flags and size of the new space don't matter, as it will get
  # recreated again by cryptohome.
  local ppwrite_permission=0x1
  local temporary_lockbox_size=1
  tpmc def $LOCKBOX_TPM_NV_SPACE $temporary_lockbox_size $ppwrite_permission
}

clear_tpm() {
  dlogf "Resetting security device . . ."
  # TODO(wad) should we fail on this?
  tpmc ppon || dlog "tpmc ppon error: $?"
  tpmc clear || dlog "tpmc clear error: $?"
  tpmc enable || dlog "tpmc enable error: $?"
  tpmc activate || dlog "tpmc activate error: $?"
  clobber_lockbox_space || dlog "error clobbering lockbox space: $?"
  tpmc pplock || dlog "tpmc pplock error: $?"
  dlog " done."
  return 0
}

verify_rw_vpd() {
  local tmpfile="$(mktemp ${TMPDIR:-/tmp}/rw_vpd.XXXXXX)"
  local rc=0

  dlog "Verifying RW_VPD"

  # First method: Check if RW VPD entries have been populated in sysfs by the
  # kernel. If so, assume everything is good. Otherwise fall back to using
  # flashrom and vpd utilities (slower).
  ls -1A "/sys/firmware/vpd/rw" | grep -q .
  if [ $? -eq 0 ]; then
    dlog "Found RW VPD in sysfs."
    return 0
  fi

  # Test if RW_VPD region exists on system by attempting to read it
  # using flashrom.
  flashrom -p internal -i RW_VPD:${tmpfile} -r
  if [ $? -ne 0 ]; then
    dlog "RW_VPD does not exist on this system, skipping."
    return 0
  else
    rm -f "${tmpfile}"
  fi

  # vpd utility exit codes defined in vpd/include/lib/lib_vpd.h:
  # 0:  VPD_OK
  # 9:  VPD_ERR_NOT_FOUND, meaning VPD was not found.
  # 10: VPD_ERR_OVERFLOW, meaning VPD is likely corrupt.
  # 11: VPD_ERR_INVALID, meaning VPD is corrupt.
  #
  # All others will be treated as generic failures.
  vpd -i RW_VPD -l
  rc=$?
  case $rc in
    0)
      dlog "Successfully read VPD from RW_VPD."
      return 0
      ;;
    9)
      dlog "VPD not found in RW_VPD."
      ;;
    10)
      dlog "Overflow detected in VPD. May be corrupted."
      ;;
    11)
      dlog "VPD found in RW_VPD, but is corrupted."
      ;;
    *)
      dlog "Unspecified error when reading VPD from RW_VPD: $rc"
      return 1
  esac

  # From here, erase the RW_VPD region and re-initialize. If erase fails then
  # try initializing anyway and hope it works well enough.
  dlog "Erasing RW_VPD region and re-initializing the VPD."

  flashrom -p internal -i RW_VPD -E
  if [ $? -ne 0 ]; then
    dlog "Failed to erase RW_VPD region, continuing anyway."
  fi

  vpd -i RW_VPD -O
  rc=$?
  if [ $rc -ne 0 ]; then
    dlog "Error re-formatting VPD region: $rc"
    return 1
  fi

  return 0
}

recover_system() {
  local source=$(strip_partition "$REAL_USB_DEV")
  dlog "Beginning system recovery from $source"

  # If we're not running a developer script then we're either
  # installing a developer image or an official one. If we're
  # in normal recovery mode, then we require that the KERN-B
  # on the recovery image matches the hash on the command line.
  # In developer mode, we will just check the keys.
  verify_install_kernel || return $?

  # Only clear on full installs. Shim scripts can call tpmc if they
  # like.  Only bGlobalLock will be in place in advance.
  clear_tpm || return 1

  # Check if RW_VPD is valid and reinitialize if not. This is intended to
  # ensure certain functionality such as re-enrollment works. Refer to
  # crbug.com/660121 for details.
  verify_rw_vpd || dlog "Could not verify or re-format RW_VPD"

  local extra_flags=

  # TODO: Since our final UX design is not confirmed, disable "Enhanced Disk
  #       Wipe" on beta and stable channels.
  if is_dev_channel; then
    check_disk_wipe_requested
  fi

  # The progress bar is full, and it is the user's last chance to cancel. The
  # power button has to be held for a full 8 seconds to power off, so we allow
  # a short grace period in case the user started pressing the power button
  # late in the cycle.
  sleep 2

  message recovery_start

  call_image_recovery_script "$source" ${extra_flags} || return 1

  return 0
}

# Return the path to the node under /sys/block associated with
# the USB stick.  The existence of that path is used to test whether
# the user has removed the stick and we can reboot.
#
# For certain non-interactive test cases, the stateful partition on
# the USB stick may be flagged to request that we bypass the
# interactive removal of the USB stick.  If we detect that
# condition, we signal it by returning an empty string instead
# of a path.
get_usb_node_dir() {
  local usb_node_dir=/sys/block/$(strip_partition "${REAL_USB_DEV##*/}")
  if [ "$INTERACTIVE_COMPLETE" = false ]; then
    usb_node_dir=""
  elif mount -n -o sync,rw "${REAL_USB_DEV%[0-9]*}1" /tmp; then
    if [ -f /tmp/non_interactive ]; then
      usb_node_dir=""
    fi
    umount /tmp
  fi
  echo "$usb_node_dir"
}

get_usb_debugging_flag() {
  local decrypt=""
  if get_stateful_dev && mount -n -o sync,ro "${STATE_DEV}" /tmp; then
    if [ -f /tmp/decrypt_stateful ]; then
      decrypt=$(cat /tmp/decrypt_stateful)
    fi
    umount /tmp
  fi
  echo "$decrypt"
}

maybe_get_debugging_logs() {
  local state=$(get_usb_debugging_flag)
  if [ -z "$state" ]; then
    return 0
  fi
  log "Stateful recovery requested."

  dlog "Attempting to find the destination stateful . . ."
  get_dst || return 0

  log "Please wait (this may take up to 2 and a half minutes). . ."
  sleep 150  # Five minutes in half.
  if ! mount -n -o sync,rw "${DST_DEV_BASE}1" "${STATEFUL_MNT}"; then
    log "Unable to perform stateful recovery."
    dlog "mount failed for ${DST_DEV_BASE}1"
    sleep 1d
    reboot -f
  fi

  local flagfile="${STATEFUL_MNT}/decrypt_stateful"
  local decrypted_dir="${STATEFUL_MNT}/decrypted"
  local tarball_dir="/tmp/recovery"
  local tarball="${tarball_dir}/extracted.tgz"
  # Check if the files exist already or if recovery needs to be requested.
  if [ -f "$flagfile" ] && [ ! -d "$decrypted_dir" ]; then
    log "Prior recovery request incomplete. Starting over . . ."
  fi
  if [ -f "$flagfile" ] && [ -d "$decrypted_dir" ]; then
    log "Prior recovery request exists. Attempting to extract files."
    if ! mount -n -o sync,rw "${STATE_DEV}" /tmp 2>"${TTY_LOG}"; then
      log "Failed to mount recovery stateful partition."
      on_error
    fi
    mkdir -p "$tarball_dir" || on_error
    log "Copying files . . ."
    # Due to the tty redirection that this script runs under, without the
    # explicit stdin and stdout redirects, tar will fail with "Broken pipe".
    if ! tar -czf "${tarball}" -C "${STATEFUL_MNT}" \
         --exclude './decrypt_stateful' \
         --exclude './encrypted*' \
         --exclude './home/.shadow/*/*' \
         --exclude './dev_image' \
         . >"${TTY_LOG}" 2>"${TTY_LOG}" </dev/null ; then
      log "Extraction failed. See debug log for more details."
      # Remove the request file, to prevent being stuck in a error loop,
      # Otherwise, rebooting the device will request recovery again.
      rm -f "${flagfile}"
      crossystem recovery_request=1
      umount /tmp
      umount "${STATEFUL_MNT}"
      on_error
    fi
    log "Removing the request file and old data . . ."
    rm -f "${flagfile}"
    rm -rf "${decrypted_dir}"
    umount /tmp
    umount "${STATEFUL_MNT}"
    log "Operation complete, you can now remove your recovery media."
    log "The requested data can be found in the /recovery folder."
    sleep 1d
    reboot -f
  fi

  log "Stateful recovery requires authentication."
  log "Your username and salted password will be temporarily written to the"
  log "device for the duration of this recovery process. Once finished,"
  log "please be sure to change your password as a precautionary measure."

  local username
  read -p Username: username <"${TTY_CONSOLE}" 2>"${TTY_CONSOLE}"

  if [ -n "${username}" ]; then
    local password
    read -p Password: -s password <"${TTY_CONSOLE}" 2>"${TTY_CONSOLE}"
    # Force a newline for sane output after silent input.
    echo "" >"${TTY_CONSOLE}"

    local saltfile="${STATEFUL_MNT}"/home/.shadow/salt
    if [ ! -f "${saltfile}" ]; then
      log "Target has no system salt file. Giving up."
      sleep 1d
      reboot -f
    fi

    local salt=$(hexdump -v -e '/1 "%02x"' <"$saltfile")
    local passkey=$(printf '%s' "${salt}${password}" | sha256sum | cut -c-32)

    log "Installing v2 request file . . ."
    cat > "${flagfile}" <<EOM
2
$username
$passkey
EOM
  else
    log "Installing v1 request file . . ."
    printf "1" > "${flagfile}"
  fi
  umount "${STATEFUL_MNT}"

  log "Stateful recovery initiation completed."
  log "In 60 seconds, the system will reboot to the local OS."
  log "Once the files are prepared, it will return back to recovery mode."
  log "Please use this same recovery media."
  sleep 60
  reboot -f  # Back to the system!
  return 1
}

# Shows the appropriate error screen for the specified error code and
# stops further action, i.e. doesn't return.
handle_error() {
  case "$1" in
    $ERR_DEV_MODE_BLOCKED)
      message block_developer_mode
      ;;
    $ERR_INVALID_INSTALL_KERNEL)
      message invalid_install_kernel
      ;;
    *)
      # Show the generic error screen by default.
      on_error
      ;;
  esac
}

wait_for_battery_to_charge() {
  while true; do
    local power_status="$(chroot "${USB_MNT}" /usr/bin/dump_power_status)"

    # Recheck whether charge level is sufficient.
    local battery_charge=$(echo "${power_status}" |
                           grep "^battery_display_percent " |
                           cut -d ' ' -f 2)
    if [ "${battery_charge%%.*}" -ge "${MIN_BATTERY_CHARGE_PERCENT}" ]; then
      break
    fi

    # Display the appropriate low battery message.
    if echo "${power_status}" | grep -Fqx "line_power_connected 1"; then
      message update_firmware_low_battery_charging
    else
      message update_firmware_low_battery
    fi

    sleep 1
  done
}

tpm_firmware_update_applicable() {
  # Only allow the firmware updater to run from an official root. We don't want
  # arbitrary code to run with TPM physical presence asserted! If we're running
  # an unofficial root, return success so it looks like we don't have an update.
  if is_unofficial_root; then
    return 1
  fi

  # Images for boards that we don't ship TPM firmware updates for don't carry
  # the updater. Nothing to do in that case.
  if ! [ -x "${USB_MNT}/usr/sbin/tpm-firmware-updater" ]; then
    return 1
  fi

  # The TPM is in failed selftest mode after a failed previous TPM firmware
  # update. Devices in this condition don't boot in normal mode, and recovery is
  # the supported way to fix this via a TPM firmware update retry.
  if [ -n "${TPM_FAILED_SELFTEST}" ]; then
    return 0
  fi

  # Attempt a TPM firmware update when the VPD key tpm_firmware_update_params
  # contains mode:recovery. This is mainly useful for testing behavior of the
  # firmware updater in recovery mode without having to put a device into failed
  # selftest mode.
  local vpd_params="$(vpd -i RW_VPD -g tpm_firmware_update_params)"
  if echo ",${vpd_params}," | grep -qF ',mode:recovery,'; then
    return 0
  fi

  # Current default is not to attempt updating, even if an update is available.
  return 1
}

cold_reset() {
  # Issue cold reset via Chromium EC if ectool is available.
  if [ -x "${USB_MNT}/usr/sbin/ectool" ]; then
    chroot "${USB_MNT}" /usr/sbin/ectool reboot_ec cold
  fi
}

# Checks whether the root includes a TPM firmware update and installs it if
# applicable. Note that this must happen before locking TPM physical presence,
# because this is the only way to recover from a failed previous firmware
# update.
update_tpm_firmware() {
  if ! tpm_firmware_update_applicable; then
    return 0
  fi

  while true; do
    (
      set +e
      # TODO(mnissler): Reading the VPD from flash requires CAP_SYS_ADMIN and
      # CAP_SYS_RAWIO. Figure out whether there's a way around that.
      TPM_FIRMWARE_UPDATE_MIN_BATTERY="${MIN_BATTERY_CHARGE_PERCENT}" \
      chroot "${USB_MNT}" \
        /sbin/minijail0 -c 0x220000 --ambient -e -l -n -p -r -v --uts -- \
        /bin/sh -x /usr/sbin/tpm-firmware-updater
      echo $? > /tmp/tpm-firmware-updater.status
    ) 2>>"${LOG_DIR}/tpm-firmware-updater.log" | (
      # The dummy read is so we only show the update_firmware message to the
      # user in case the update actually takes place.
      if read progress; then
        message update_firmware
        progress_bar
      fi
    )

    local EXIT_CODE_SUCCESS=0
    local EXIT_CODE_ERROR=1
    local EXIT_CODE_NO_UPDATE=3
    local EXIT_CODE_UPDATE_FAILED=4
    local EXIT_CODE_LOW_BATTERY=5
    local EXIT_CODE_NOT_UPDATABLE=6
    local EXIT_CODE_SUCCESS_COLD_REBOOT=8
    local EXIT_CODE_BAD_RETRY=9

    local status="$(cat /tmp/tpm-firmware-updater.status)"
    case "${status}" in
      ${EXIT_CODE_SUCCESS}|${EXIT_CODE_SUCCESS_COLD_REBOOT})
        # We need to reboot to get the TPM back into operational state.
        save_log_files
        [ "${status}" = "${EXIT_CODE_SUCCESS_COLD_REBOOT}" ] && cold_reset
        reboot -f
        exit 0
        ;;
      ${EXIT_CODE_NO_UPDATE}|${EXIT_CODE_BAD_RETRY})
        # Let the recovery process continue.
        return 0
        ;;
      ${EXIT_CODE_UPDATE_FAILED})
        # Fail and let the caller handle the error.
        return 1
        ;;
      ${EXIT_CODE_LOW_BATTERY})
        wait_for_battery_to_charge
        ;;
      ${EXIT_CODE_NOT_UPDATABLE})
        # No physical presence? This can only happen if we're not booted in
        # recovery mode.
        dlog "Attempted TPM firmware update, but no physical presence."
        return 0
        ;;
      ${EXIT_CODE_ERROR}|*)
        return 1
        ;;
    esac
  done

  # Never reached.
  return 0
}

# Terminate with an error message.  We don't want to do anything
# else (like start a shell) because it would be trivially easy to
# get here (just unplug the USB drive after the kernel starts but
# before the USB drives are probed by the kernel) and starting a
# shell here would be a BIG security hole.
# Also if enhanced disk wipe is executed, report its result to user.
on_error() {
  if [ -n "${DISK_WIPE_RESULT}" ]; then
    if [ "${DISK_WIPE_RESULT}" -eq 0 ]; then
      message recovery_error_wipe_success
    else
      message recovery_error_wipe_fail
    fi
  else
    message on_error
  fi
  signal_fatal_error
}

# Called after displaying some fatal error message.  This method will sync
# disks, and never return.  In the future, if the boot media is an Android
# phone, it will also tell the app that progress has halted.
signal_fatal_error() {
  save_log_files
  sleep 1d
  exit 1
}

# Check if the current channel is whitelisted for wipe disk. Since our final UX
# design is not confirmed, disable "Enhanced Disk Wipe" on beta and stable
# channels.
is_dev_channel() {
  local channel=$(sed -n 's/^CHROMEOS_RELEASE_TRACK=//p' \
     "${USB_MNT}/etc/lsb-release")
  test "${channel}" = "dev-channel" -o "${channel}" = "testimage-channel" \
    -o "${channel}" = "canary-channel"
}

recovery_install() {
  NEWROOT_MNT="${USB_MNT}"

  # Always lock the TPM.  If a NVRAM reset is ever needed, we can change it.
  lock_tpm || on_error

  # Check if we're really doing debugging log extraction.
  maybe_get_debugging_logs || return 1

  # Since our final UX design is not confirmed, disable "Enhanced Disk Wipe" on
  # beta and stable channels.
  if is_dev_channel; then
    # Listen for EVWAITKEY_KEY
    evwaitkey --include_usb --keys "${EVWAITKEY_KEY}" > "${EVWAITKEY_FILE}" &
  fi

  # Check if we have a verified recovery root.
  validate_recovery_root || handle_error $?

  setup_install_mounts || on_error

  # Install a TPM firmware update included in the rootfs if applicable.
  update_tpm_firmware || message security_module_failure

  # Do not install the system image if the TPM is in failed selftest mode. The
  # installer is not prepared to handle this state and installing a fresh system
  # image will not fix things anyways, so err on the safe side and abort.
  [ -z "${TPM_FAILED_SELFTEST}" ] || message security_module_failure

  get_dst || on_error

  recover_system || handle_error $?

  # No error check here:  Clean up doesn't need to be successful.
  cleanup_install_mounts

  # Save the recovery log to the target on success and the USB.
  save_log_files "${DST_DEV_BASE}"1 ext4
  save_log_files "${SRC_DEV_BASE}"12 vfat
  save_log_files "${SRC_DEV_BASE}"1 ext4

  # This assignment depends on the stateful partition on the USB
  # stick, so we must do it before unmount_usb and the
  # "recovery_complete" message, because the user could remove the
  # USB stick from that moment forward.
  local usb_node_dir=$(get_usb_node_dir)

  unmount_usb

  if [ -n "$usb_node_dir" ]; then
    # Default (interactive) case.
    if [ -z "$DISK_WIPE_RESULT" ]; then
      message recovery_complete
    elif [ "$DISK_WIPE_RESULT" -eq 0 ]; then
      message recovery_complete_wipe_successful
    else
      message_recovery_complete_wipe_fail
    fi
    # Wait until the user removes the USB stick.
    while [ -d "$usb_node_dir" ]; do
      sleep 1
    done
  else
    message recovery_complete_noninteractive
  fi

  reboot -f
  exit 0
}
