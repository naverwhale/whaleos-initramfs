#!/bin/bash
#
# Copyright 2022 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Generate a minimal set of config data for use in initramfs

set -e

usage() {
    cat << EOF
Usage:
$0 CONFIG_DIR
EOF
}

config_dir="$1"

if [[ -z "${config_dir}" ]]; then
  printf "ERROR: config dir not specified" >&2
  usage >&2
  exit 1
fi

# Create unibulid indicator
touch "${config_dir}/unibuild"

# Create detachable_ui config
pairs="$(cros_config_host get-key-value-pairs \
    /firmware image-name /firmware detachable-ui)"
while read -r name && read -r detachable_ui; do
  image_config_dir="${config_dir}/${name}"
  mkdir -p "${image_config_dir}"

  if [[ "${detachable_ui}" == "True" ]]; then
    touch "${config_dir}/${name}/detachable_ui"
  fi
done <<< "${pairs}"
