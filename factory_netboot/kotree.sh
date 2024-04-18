#!/bin/bash
# Copyright 2015 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Copies kernel modules (with correct dependency) into a staging folder.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

has() {
  local token="$1"
  shift
  local list=("$@")
  local item=""
  for item in "${list[@]}"; do
    if [[ "${token}" == "${item}" ]]; then
      return
    fi
  done
  false
}

find_module() {
  local module="$1"
  local module_path="$2"
  local cmd="$3"

  find "${module_path}" -regex ".*/${module}\.ko\(\.\(gz\|xz\)\)?" ${cmd}
}

idoko() {
  local sysroot="$1"
  local output="$2"
  shift
  shift

  local module_root_path="${sysroot}/lib/modules"
  local module_list=()
  local module_queue=("$@")
  local module=""
  local depend=""
  local module_depends=""
  local module_depend_path=""
  local module_install_path=""
  local dst_path=""

  # Parses module dependencies.
  local missing_module=false
  while [[ ${#module_queue[@]} -gt 0 ]]; do
    module="${module_queue[0]}"
    module_queue=("${module_queue[@]:1}")
    if has "${module}" "${module_list[@]}"; then
      continue
    else
      module_list+=("${module}")
    fi

    module_depends=($(modinfo -F depends "${module}" | tr ',' ' '))
    for depend in "${module_depends[@]}"; do
      module_depend_path=$(find_module "${depend}" "${module_root_path}")
      if [[ -z "${module_depend_path}" ]]; then
        missing_module=true
        echo "Can't find ${depend} in ${module_root_path}" >&2
        continue
      fi
      module_queue+=("${module_depend_path}")
    done
  done
  ${missing_module} && die "Some modules are missing, see messages above"

  # Copies modules.
  for module in "${module_list[@]}"; do
    module_install_path="${module#${sysroot}}"
    dst_path="${output}/${module_install_path}"
    mkdir -p "${dst_path%/*}"
    cp -p "${module}" "${dst_path}" ||
      die "Can't copy ${module} to ${dst_path}"
    echo "Copied: ${module_install_path}"
  done
}

main() {
  local kofile="$1"
  local sysroot="$2"
  local output="$3"
  local module_root_path="$2/lib/modules"
  local module_path=$(find_module "${kofile}" "${module_root_path}" \
    "-printf %h")
  [[ -n "${module_path}" ]] || die "Can't find ${kofile}"
  local module_list=()
  while read -d $'\0' -r module; do
    module_list+=("${module}")
  done < <(find_module ".*" "${module_path}" -print0)
  idoko "${sysroot}" "${output}" "${module_list[@]}"
  # Copy /lib/modules/*/modules.* for dependency list.
  local module_base_dir="$(realpath \
    --relative-to="${module_root_path}" "${module_path}")"
  module_base_dir="${module_base_dir%%/*}"
  cp -p "${module_root_path}/${module_base_dir}/"modules.* \
    "${output}/${module_root_path#${sysroot}}/${module_base_dir}"/.
}

main "$@"
