#!/bin/sh
#
# Copyright 2015 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Default settings and implementations. Variables and settings defined in this
# file can be overridden by board_recovery.sh.

# Console and log output: /dev/null for default
TTY_CONSOLE=/dev/null
TTY_LOG=/dev/null
TTY_DEBUG=/dev/null
# Initialize on the fist message.
FIRST_MESSAGE_RECEIVED=

# Wrapper to provide a hook for every message we print.
message() {
  # Currently defined messages (see message.sh for details):
  #  - startup
  #  - on_error
  #  - key_change
  #  - developer_image
  #  - disk_wipe_start
  #  - disk_wipe_end
  #  - key_change
  #  - recovery_start
  #  - recovery_complete
  #  - recovery_complete_noninteractive
  #  - recovery_complete_wipe_fail
  #  - recovery_complete_wipe_successful
  #  - recovery_error_wipe_fail
  #  - recovery_error_wipe_success
  #  - warn_invalid_install_kernel
  #  - invalid_install_kernel
  #  - block_developer_mode
  #
  # By default, calls to the functions defined in message.sh.
  if [ -z "${FIRST_MESSAGE_RECEIVED}" ]; then
    FIRST_MESSAGE_RECEIVED=1
    if ! message_startup; then
      echo "Failed to start frecon (Headless board?)"
      echo "Consider adding custom UI with board-recovery.sh."
      return
    fi
    # Redirect TTYs to virtual terminals
    # when message_startup was successful
    TTY_CONSOLE=/run/frecon/vt0
    TTY_LOG=/run/frecon/vt1
    TTY_DEBUG=/run/frecon/vt2

    # Send all verbose output to debug tty.
    (tail -f -n +1 "${LOG_FILE}" > "${TTY_DEBUG}") &
    message_"$1" &
    return
  fi
  message_"$1"
}
