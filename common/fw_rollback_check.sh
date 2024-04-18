# Copyright 2023 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Minimum (default) version in firmware space,
FW_VER_MIN=0x10001
# TPM NVRAM index where the rollback firmware version is stored.
FW_VER_TPM_NV_SPACE=0x1007
# Recovery version is the top nibble of the firmware version. Lock out the
# image if the version is greater than this.
REC_VER_MAX=0

# Get the firmware version by directly reading the TPM NVRAM spaces.
# Needed when crossystem doesn't work (e.g. Mario systems).
_get_fwver_from_tpmc() {
  if [ $# -ne 0 ]; then
    dlog "ERROR: _get_fwver_from_tpmc() doesn't take any args"
    return
  fi
  # Example output:
  #
  # 2 3 3 0 1 0
  #
  # The first 2 bytes of the output are internal version and flags and
  # can be ignored. The full firmware version is stored as a 32-bit
  # integer in little endian format.
  local out
  if ! out=$(tpmc read ${FW_VER_TPM_NV_SPACE} 6); then
    dlog "ERROR: tpmc read failed"
    echo "${FW_VER_MIN}"
    return
  fi
  set -- ${out}
  if [ $# != 6 ]; then
    # The TPM is uninitialized or corrupt.  Return a default version.  Don't
    # lock out the image because we might be what's supposed to fix it.
    echo "${FW_VER_MIN}"
    return
  fi

  echo "$(( 0x$6 << 24 | 0x$5 << 16 | 0x$4 << 8 | 0x$3 ))"
}

verify_fw_version() {
  local fwver recver
  fwver=$(crossystem tpm_fwver || _get_fwver_from_tpmc)
  : $(( recver = fwver >> 28 ))
  dlog "FW version from TPM: ${fwver}"
  dlog "Recovery version from top nibble: ${recver}"

  if [ ${recver} -gt ${REC_VER_MAX} ]; then
    local formatted_fwver="$(printf "0x%x" "${fwver}")"
    dlog "Recovery script locked out due to firmware version" \
      "${formatted_fwver}"
    return 1
  fi
  return 0
}
