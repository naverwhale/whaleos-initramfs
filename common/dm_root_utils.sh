# Copyright 2023 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Name of the dm device. A shared variable for this script.
DM_NAME=
# /dev path of the dm device (e.g. /dev/dm-0).
DM_DEV=

_is_old_style_verity_argv() {
  # TODO(ellyjones): remove by 2011-08-31. Part of crosbug.com/15772.
  # "0 1740800 verity %U+1 %U+1 1740800 0 sha1 $hash"
  local depth="$(echo "$1" | cut -f7 -d' ')"
  if [ "${depth}" = "0" ]; then
    return 0
  fi
  return 1
}

# Usage: check_if_dm_root [kernel_command_line]
# Check if the given kernel command line contains a dm argument.
# Args:
#  kernel_command_line: the kernel command line to check.
# Returns:
#  Returns none zero value if no dm arguments found.
check_if_dm_root() {
  local kernel_command_line="$1"
  echo "${kernel_command_line}" | grep -q 'root=/dev/dm-' || return 1
  return 0
}

# The current implementation assumes that the DM device name in the kernel
# command line is "vroot". And the implementation calls `dmsetup` with "vroot"
# as device name as well.

# _parse_dm_table is passed the dm argment from the kernel command
# line from the image and builds a table for dmsetup that has just
# the information needed to bring up verity so the image can be
# verified before it is installed. This is only done if verity was
# setup in image. The boot cache is ignored.
#
# BNF for device mapper (dm) argument syntax:
# In the future, the <num> field will be mandatory.
# TODO(taysom:defect 32847)
#
# <device>        ::= [<num>] <device-mapper>+
# <device-mapper> ::= <head> "," <target>+
# <head>          ::= <name> <uuid> <mode> [<num>]
# <target>        ::= <start> <length> <type> <options> ","
# <mode>          ::= "ro" | "rw"
# <uuid>          ::= xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx | "none"
# <type>          ::= "verity" | "bootcache" | ...
#
# Specific case of arguments for boot cache and verity:
# $1   2          Num of devices
# $2   vboot      Name of boot cache device
# $3   none       uuid
# $4   ro         Read-only device
# $5   1,0        Num entries and start (one argument because no space)
# $6   1768000    End of device presented to layer above
# $7   bootcache  Device mapper code to use for device
# $8   5e560a5b-15f5-924a-85c8-84c67b07ee99+1    uuid of underlying device
# $9   1768000    Start of boot cache data
# $10  cf20e4499efb35b8a3dedbf3e84a6a55750003e5  Salt for verity
# $11  512        Max sectors requested that will be cached
# $12  20000      Max trace events that will be kept
# $13  100000,    Max pages that will be cached
# $14  vroot      Name of verity device
# $15  none       uuid
# $16  ro         Read-only device
# $17  1,0        Num entries and start (Treated as a single argument)
# $18  1740800    End of device presented to layer above
# $19  verity payload=254:0
# $20  hashtree=254:0
# $21  hashstart=1740800
# $22  alg=sha1
# $23  root_hexdigest=cf20e4499efb35b8a3dedbf3e84a6a55750003e5
# $24  salt=20ba9113fe2c46f38393bbe630126f87378ff01bdcbf87384929bfe43f9e56ce
_parse_dm_table() {
  case $1 in
    2)  # Both bootcache and verity in the new dm-init format
      local uuid="$8"
      local vroot="${*##*vroot}"
      local table="${vroot##*,}"
      local first="${table%%payload*}"
      local last="${table##*hashstart}"
      local table="${first}payload=${uuid} hashtree=${uuid} hashstart${last}"
      ;;
    1|vroot) # Just verity in both old and new dm-init format
      local vroot="${*##*vroot}"
      local table="${vroot##*,}"
      ;;
    *) dlog "Unexpected argument to _parse_dm_table:$1"
      local table=
      ;;
  esac
  # We override the reboot-to-recovery error behavior so that we can fail
  # gracefully on invalid rootfs.
  if _is_old_style_verity_argv "${table}"; then
    local eio=eio
  else
    local eio='error_behavior=eio'
  fi
  echo "${table} ${eio}"
}

# Usage: setup_dm_root [kernel_command_line] [root_dev]
# Set up dm root according to a given kernel command line.
# Args:
#  kernel_command_line: the kernel command line that contains the dm argument.
#  root_dev: the root device.
# Outputs:
#  This function outputs by setting global variables. It sets both `DM_NAME`
#  and `DM_DEV`.
# Returns:
#  Returns 1 if anything goes wrong.
setup_dm_root() {
  local kernel_command_line="$1"
  local root_dev="$2"

  dlog -n "Extracting the device mapper configuration..."

  # export_args can't handle dm="..." at present.
  #
  # Substitute root_dev for the payload and hashtree. E.g.
  # Before:
  # payload=PARTUUID=%U/PARTNROFF=1 hashtree=PARTUUID=%U/PARTNROFF=1
  # After:
  # payload=/dev/sda3 hashtree=/dev/sda3
  #
  # Note: the `;t;d` is so that we return an empty string if the substitution
  # fails (which we then check for below). However this also means we need
  # separate sed calls instead of a single call with multiple -e arguments.
  local dm_arg="$(echo "${kernel_command_line}" |
      sed -e 's/.*dm="\([^"]*\)".*/\1/g;t;d' |
      sed -e "s|payload=[^\" ]*|payload=${root_dev}|g;t;d" |
      sed -e "s|hashtree=[^\" ]*|hashtree=${root_dev}|g;t;d")"

  # Make sure we have valid dm args string.
  if [ -z "${dm_arg}" ]; then
    dlog "Failed to extract dm arguments from kernel command line"
    return 1
  fi

  DM_NAME=vroot
  local dm_table="$(_parse_dm_table ${dm_arg})"

  if ! dmsetup create -r "${DM_NAME}" --table "${dm_table}"; then
    dlog "Failed to configure device mapper root"
    return 1
  fi
  local dm_dev="/dev/dm-0"
  if [ ! -b "${dm_dev}" ]; then
    local major=$(dmsetup info -c -o major --noheadings "${DM_NAME}")
    local minor=$(dmsetup info -c -o minor --noheadings "${DM_NAME}")
    mknod -m 0600 "${dm_dev}" b "${major}" "${minor}"
  fi
  dlog "Created device mapper root ${DM_NAME}."
  DM_DEV="${dm_dev}"
}

# Remove the DM device created by setup_dm_root.
remove_dm_root() {
  if [ -n "${DM_NAME}" ]; then
    dmsetup remove "${DM_NAME}"
  fi
}
