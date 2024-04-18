#!/bin/bash
# Copyright 2016 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

SCRIPT_ROOT="$(dirname "$(readlink -f "$0")")/../../../scripts"
. "${SCRIPT_ROOT}/common.sh" || exit 1
. "${BUILD_LIBRARY_DIR}/disk_layout_util.sh" || exit 1

CROS_LOG_PREFIX=${SCRIPT_NAME}

DEFINE_string board "${DEFAULT_BOARD}" \
  "The board to build an image for."
DEFINE_string sysroot "" "The sysroot to build against."

FLAGS_HELP="USAGE: test [targets]

Build all the initramfs's, the kernels, and the root disks.
Create a qemu script for developers to then boot the result.
"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

assert_inside_chroot
switch_to_strict_mode

# Usage: m <make flags>
# A shortcut for the `make` function with the right job count.
m() {
  make -j${NUM_JOBS} "$@"
}

# Usage: build_cpios
# Generate all the initramfs rootfs's for all the requested targets.
build_cpios() {
  local target cpio output

  for target in "${TARGETS[@]}"; do
    output="${OUTPUT_DIR}/${target}"
    cpio="${output}/ramfs.cpio"
    if [[ ! -f ${cpio} ]]; then
      info "${target}: Building cpio: ${cpio}"
      m -C "${SCRIPT_LOCATION}/.." \
        SUBDIRS="${target}" \
        OUTPUT_DIR="${output}" \
        RAMFS_BIN="${cpio}" \
        STAGE="${output}/rootfs" \
        BOARD="${BOARD}" \
        SYSROOT="${SYSROOT}"
    fi
  done
}

# Usage: setconfig <y|n|"some string"|int> <config> [more config symbols]
# Env: The $config file is updated.
# Set all the configs to the specified value.  Omit the "CONFIG_" prefix.
setconfig() {
  local value=$1 cfg
  shift
  if [[ "${value}" != [ymn] ]]; then
    value="\"${value}\""
  fi

  while [[ $# -gt 0 ]]; do
    cfg="CONFIG_$1"
    case ${value} in
    n)
      sed -i \
        -e "/^${cfg}=/s:.*:# ${cfg} is not set:" \
        "${config}"
      ;;
    *)
      sed -i \
        -e "/^# ${cfg} is not set/s:.*:${cfg}=${value}:" \
        -e "/^${cfg}=/s:.*:${cfg}=${value}:" \
        "${config}"
      if ! grep -q "^${cfg}=" "${config}"; then
        echo "${cfg}=${value}" >>"${config}"
      fi
      ;;
    esac
    shift
  done
}

# Usage: defconfig <kernel source> <output dir> <output config file>
# Generate the kernel config for this board.
defconfig() {
  local ksrc="$1"
  local output="$2"
  local config="$3"

  # CHOST isn't entirely correct as we mung it for some targets in
  # the cros-kernel.eclass.
  pushd "${ksrc}" >/dev/null
  ./chromeos/scripts/prepareconfig "${CHROMEOS_KERNEL_SPLITCONFIG}" "${config}"
  popd >/dev/null
  setconfig "${CHOST}-" CROSS_COMPILE

  local options=(
    # Turn on the serial port for qemu console.
    SERIAL_8250{,_CONSOLE,_PCI}

    # Turn on i2cdev support for factory probing.
    I2C_CHARDEV

    # Turn on kexec support for the loader kernel.
    KEXEC

    # Turn on fat support.
    NLS_CODEPAGE_437
    NLS_ISO8859_1
    FAT_FS
    VFAT_FS

    # Turn on tpm support.
    TCG_TPM
    TCG_TIS

    # Turn on console support.
    FRAMEBUFFER_CONSOLE
    VT
    VT_CONSOLE
  )
  setconfig y "${options[@]}"

  # Turn on the initramfs.
  setconfig "${output}/../ramfs.cpio" INITRAMFS_SOURCE
  setconfig y INITRAMFS_COMPRESSION_XZ

  # Pass in a default command line for debugging.
#  setconfig y CMDLINE_BOOL
#  setconfig "console=ttyS0 panic=3" CMDLINE

  yes "" 2>/dev/null | "${output}"/make oldconfig >/dev/null
}

# Usage: find_latest_kver <dir of kernel sources>
# Given the common kernel source root, return the latest version.
find_latest_kver() {
  local kroot="$1"
  find "${kroot}" -maxdepth 1 -type d -name 'v*' -printf '%P\n' | \
    sort -V | tail -1
}

# Usage: build_kernels
# Build all the kernels for all the requested targets.
build_kernels() {
  local target config output

  local kroot="${SRC_ROOT}/third_party/kernel"
  local kver=$(find_latest_kver "${kroot}")
  local ksrc="${kroot}/${kver}"

  for target in "${TARGETS[@]}"; do
    output="${OUTPUT_DIR}/${target}/kernel"
    mkdir -p "${output}/usr"

    # Create a helper script for local building and for devs.
    cat <<EOF >"${output}/make"
#!/bin/sh
SYSROOT="${SYSROOT}" \
exec make -j${NUM_JOBS} -C "${ksrc}" O="${output}" "\$@"
EOF
    chmod a+rx "${output}/make"
    cp "${SCRIPT_LOCATION}"/qemu "${OUTPUT_DIR}/${target}/qemu"

    # Build the kernel .config file.
    config="${output}/.config"
    if [[ ! -f ${config} ]]; then
      info "${target}: Generating kernel config: ${config}"
      defconfig "${ksrc}" "${output}" "${config}"
    fi

    # Actually compile the kernel.
    if [[ ! -f ${output}/arch/x86/boot/bzImage ]]; then
      info "${target}: Building kernel"
      "${output}"/make bzImage
    fi
  done
}

# Usage: mkimage <output file> <disk layout>
# Generate a GPT disk image that is partitioned and formatted.
mkimage() {
  local img="$1"
  local layout="$2"

  get_disk_layout_path
  build_gpt_image "${img}" "${layout}"
}

# Usage: build_images
# Build all the disk images for all the requested targets.
build_images() {
  local target img

  for target in "${TARGETS[@]}"; do
    for img in "" "_usb"; do
      img="${OUTPUT_DIR}/${target}/chromiumos_image${img}.bin"
      if [[ ! -f ${img} ]]; then
        info "${target}: Generating disk image: ${img}"
        mkimage "${img}" "usb"
      fi
    done
  done
}

# Process/check all the cli options and export all the relevant variables for
# use later on in the script.
check_opts() {
  if [[ -z "${FLAGS_board}" && -z "${FLAGS_sysroot}" ]]; then
    die_notrace "--board or --sysroot required."
  fi

  BOARD="${FLAGS_board}"
  BOARD_ROOT="${FLAGS_sysroot:-/build/${BOARD}}"
  # Needed by the toolchain.
  export SYSROOT="${BOARD_ROOT}"

  OUTPUT_DIR="${DEFAULT_BUILD_ROOT}/initramfs"

  local board_vars=(
    CHOST
    CHROMEOS_KERNEL_ARCH
    CHROMEOS_KERNEL_SPLITCONFIG
  )
  eval $(portageq-${BOARD} envvar -v "${board_vars[@]}")

  TARGETS=( "$@" )
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    local d
    for d in "${SCRIPT_LOCATION}"/../*/; do
      if [[ -f ${d}/Makefile && -f ${d}/init ]]; then
        TARGETS+=( "$(basename "${d%/}")" )
      fi
    done
  fi
}

main() {
  check_opts "$@"

  build_cpios
  build_kernels
  build_images
}
main "$@"
