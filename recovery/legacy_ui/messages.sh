# Copyright 2011 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This consists of functions sourced by the /init script and used
# exclusively for recovery images.  Note that this code uses the
# busybox shell (not bash, not dash).

SCREENS=/etc/screens
LANGDIR=

# Message screens are presented in one of three boxes:
# + The 'instructions' box is used for messages telling users
#   what they can or should do.  It's for messages like "here's how
#   to cancel", or "don't turn off your computer".
# + The 'progress' box is used for to inform users how things are
#   going.  It's for animations and messages that describe what
#   work is being done, or to show percentage completion of an
#   operation.
# + The 'devmode' box is for messages that should only occur in
#   developer mode, or on non-chrome hardware.
#
# The boxes are assigned locations on the screen, top to bottom in
# the order cited above.  The locations are selected so that the
# box ensemble is centered horizontally and vertically.

. $SCREENS/constants.sh
INSTRUCTION_BOX_TOP=-$MESSAGE_BOX_HEIGHT
INSTRUCTION_SECOND_TOP_BOX=$(( $INSTRUCTION_BOX_TOP + 30 ))
PROGRESS_BOX_TOP=0
DEVMODE_BOX_TOP=$MESSAGE_BOX_HEIGHT

# User visible message overlaid on the screen. Only use for debug features!
log() {
  echo "$@" | tee -a "${TTY_CONSOLE}" "${TTY_LOG}" >&2
}

# Like log() but with printf() semantics.
logf() {
  printf "$@" | tee -a "${TTY_CONSOLE}" "${TTY_LOG}" >&2
}

# Debug messages logged to VT1 and log file.
dlog() {
  echo "$@" > "${TTY_LOG}"
}

# Like dlog() but with printf() semantics.
dlogf() {
  printf "$@" > "${TTY_LOG}"
}

clear_console() {
  clear >"${TTY_CONSOLE}"
}

read_vpd_locale() {
  local region="$(vpd -g region)"
  local locale=""
  if [ -n "${region}" ]; then
    # Lookup correct value from locale list.
    sed -nre "s/^${region}\t(.*)$/\1/p" /etc/locales.txt
  else
    # Legacy devices that do not have 'region' and may have multiple locales.
    vpd -g initial_locale | sed 's/,.*//'
  fi
}

select_locale() {
  # The region (fetched via VPD) is only available on Chrome systems.
  is_nonchrome || LANGDIR="$(read_vpd_locale)"
  if [ -z "$LANGDIR" -o ! -d "$SCREENS/$LANGDIR" ]; then
    dlog "initial locale '$LANGDIR' not found"
    LANGDIR=en-US
  fi
  dlog "selected locale $LANGDIR"
}

# Encapsulate displaying of images into single function.
#
# Arg 1:  the path to the image file
# Arg 2:  a pair of numbers X,Y representing offset from center
showimage() {
  local image=$1
  local offset=$2
  shift
  shift

  printf "\033]image:file=%s;offset=%s;scale=%d\033\\" \
      "${image}" "${offset}" "${FRECON_SCALING_FACTOR}" > /run/frecon/vt0
}

# Present a message screen horizontally centered at a specified
# Y-coordinate.
#
# Arg 1:  the Y-coordinate.
# Arg 2:  a token identifying the message, which is used to form the
#   file name based on the current locale.  In case the localized version
#   of the message is unavailable, the en-US version is shown instead.
showbox() {
  local offset=0,$1
  shift
  local message_token=$1
  shift

  # Determine the filename of the message resource. Fall back to en-US if
  # the localized version of the message is not available.
  local message_file=$SCREENS/$LANGDIR/$message_token.png
  if [ ! -f $message_file ]; then
    message_file=$SCREENS/en-US/$message_token.png
  fi

  showimage "${message_file}" "${offset}"
}

# Display an icon next to text in the message box with the given
# Y-coordinate.  The settings of ICON_INSET_LEFT and ICON_INSET_TOP
# are used to determine placement of the icon within the box.
#
# Arg 1:  the Y-coordinate of the text box.
# Arg 2:  the path to image file
showicon() {
  local icon_left=$(( ICON_INSET_LEFT ))
  local icon_top=$(( $1 + ICON_INSET_TOP ))
  shift

  showimage "$1" "${icon_left},${icon_top}"
}

# During installation, we show a spinner animation beside the text
# in the "instruction" message box.  The animation moves at a
# constant speed that's currently not tied to any measure of
# progress; it's meant merely for keeping up appearances...
show_install_spinner() {
  # The termination logic here is a nuisance.  We'd like to stop the
  # animation as soon as we get SIGTERM, but we have to make sure
  # the final animation has stopped.  To keep things simple, we run
  # everything in the foreground and simply check for termination at
  # fixed intervals.
  TERMINATED=0
  trap 'TERMINATED=1' TERM

  while [ $TERMINATED -eq 0 ] ; do
    # just drawing 1 spinner image for each loop.
    for counter in 00 01 02 03 04 05 06 07 08 09 10 11; do
      showicon "${INSTRUCTION_BOX_TOP}" "${SCREENS}/spinner_"*"${counter}.png"
      sleep 0.115
    done
  done
}

# Display a message in the "instructions" box.
#
# Arg 1:  a token identifying the message, which is used to form the
#   file name based on the current locale.
instructions() {
  showbox $INSTRUCTION_BOX_TOP $1
}

# Display a message in the "progress" box.
#
# Arg 1:  a token identifying the message, which is used to form the
#   file name based on the current locale.
progress() {
  showbox $PROGRESS_BOX_TOP $1
}

# Display a message in the "devmode" box.
#
# Arg 1:  a token identifying the message, which is used to form the
#   file name based on the current locale.
dev_notice() {
  showbox $DEVMODE_BOX_TOP $1
}

# Handle display of a simple progress bar in the 'progress' box.
# stdin is a sequence of numbers indicating percent of progress.
# As each value is read, the progress bar is updated to reflect
# the percentage.
progress_bar() {
  local image_left=$(( PROGRESS_BAR_LEFT ))
  local image_top=$(( PROGRESS_BOX_TOP + PROGRESS_BAR_TOP ))

  showimage "${SCREENS}/progress_box.png" "${image_left},${image_top}"

  local incr_left=$(( PROGRESS_INCREMENT_LEFT ))
  local incr_top=$(( PROGRESS_BOX_TOP + PROGRESS_INCREMENT_TOP ))
  local leftmost=$incr_left
  local percent=""
  while read percent; do
    local rightmost=$(( incr_left + PROGRESS_INCREMENT * percent ))
    while [ $leftmost -lt $rightmost ]; do
      showimage "${SCREENS}/progress_increment.png" "${leftmost},${incr_top}"
      leftmost=$(( leftmost + PROGRESS_INCREMENT ))
    done
  done
}

# Enforce a delay on the user for security's sake.  A progress bar
# shows the time so that the impatient will not also be in the dark.
#
# Arg 1:  the wait time in seconds.
make_user_wait() {
  local seconds=$1

  # 100 updates because progress_bar wants percentages.
  local num_updates=100
  local ms_per_update=$(( (2 * 1000 * seconds / num_updates + 1) / 2 ))
  local delay_sec=$(( ms_per_update / 1000 ))
  local delay_ms=$(( ms_per_update % 1000 ))
  local delay=$(printf "%d.%03d" $delay_sec $delay_ms)

  for i in $(seq 1 $num_updates); do
    sleep $delay
    echo $i
  done | progress_bar "$2"
}

# Generic message to report an error.
message_on_error() {
  instructions error
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_warning.png
  progress empty
  dev_notice empty
}

# First message we display at start up.
#
# This message also appears when booting factory images.
message_startup() {
  local resolution="$(frecon-lite --print-resolution)"
  local x_res="${resolution% *}"

  if [ "${x_res}" -ge 1920 ]; then
    FRECON_SCALING_FACTOR=0
  else
    FRECON_SCALING_FACTOR=1
  fi

  frecon-lite --enable-vt1 --daemon --no-login --enable-gfx \
              --enable-vts --scale="${FRECON_SCALING_FACTOR}" \
              --clear "0x${BACKGROUND}" --pre-create-vts \
              "${SCREENS}/boot_message_light.png"
}

message_validate() {
  instructions cancel
  progress validating

  # N.B. is_nonchrome implies is_developer_mode, so we must test
  # is_nonchrome first.
  if is_nonchrome; then
    dev_notice non_chrome
  elif is_developer_mode; then
    dev_notice dev_switch
  else
    dev_notice empty
  fi
}

# Tell the user the system developer mode switch is on.
message_developer_image() {
  dev_notice unverified
}

# Tell the user that they must endure the 5 minute wait for a
# developer key change.
message_key_change() {
  progress wait
  dev_notice key_change
  make_user_wait 300
}

# Announce that recovery is about to start. Start the moving box animation that
# will persist until recovery is complete.
message_recovery_start() {
  instructions recovering
  progress empty
  show_install_spinner >$LOG_DIR/spinner.log 2>&1 &
  SPINNER_PID=$!
}

# Announce that enhanced disk wipe is started.
message_disk_wipe_start() {
  instructions disk_wipe_started
  progress empty
  show_install_spinner >$LOG_DIR/spinner.log 2>&1 &
  DISK_WIPE_SPINNER_PID=$!
}

# Kill the spinner for disk wipe.
message_disk_wipe_end() {
  kill $DISK_WIPE_SPINNER_PID
  wait $DISK_WIPE_SPINNER_PID
}

# Kill the spinner animation and announce that recovery is
# complete.  Note that waiting for termination of the animation
# is necessary to guarantee that subsequent messages don't get
# overwritten.
message_recovery_complete() {
  kill $SPINNER_PID
  wait $SPINNER_PID
  instructions complete
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_check.png
  progress empty
}

# The same as message_recovery_complete, but with a different message notifying
# the user that their computer will automatically restart.
message_recovery_complete_noninteractive() {
  kill $SPINNER_PID
  wait $SPINNER_PID
  instructions complete_noninteractive
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_check.png
  progress wait
  make_user_wait 10
}

# Kill the spinner animation and announce that recovery is
# complete and enhanced disk wipe is successful.
message_recovery_complete_wipe_successful() {
  kill $SPINNER_PID
  wait $SPINNER_PID
  instructions recovery_complete_wipe_success
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_check.png
  showicon $INSTRUCTION_SECOND_TOP_BOX  $SCREENS/icon_check.png
  progress empty
}


# Kill the spinner animation and announce that recovery is
# complete and enhanced disk wipe is failed.
message_recovery_complete_wipe_fail() {
  kill $SPINNER_PID
  wait $SPINNER_PID
  instructions recovery_complete_wipe_fail
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_warning.png
  showicon $INSTRUCTION_SECOND_TOP_BOX $SCREENS/icon_check.png
  progress empty
}


# Kill the spinner animation and inform user that an error occured
# during recovery but enhanced disk wipe is successful.
message_recovery_error_wipe_fail() {
  kill $SPINNER_PID
  wait $SPINNER_PID
  instructions recovery_error_wipe_fail
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_warning.png
  showicon $INSTRUCTION_SECOND_TOP_BOX $SCREENS/icon_warning.png
  progress empty
  dev_notice empty
}

# Kill the spinner animation and inform user that an error occured
# during both recovery and enhanced disk wipe.
message_recovery_error_wipe_success() {
  kill $SPINNER_PID
  wait $SPINNER_PID
  instructions recovery_error_wipe_success
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_check.png
  showicon $INSTRUCTION_SECOND_TOP_BOX $SCREENS/icon_warning.png
  progress empty
  dev_notice empty
}

# Warn the user that the current image, although valid for
# unverified boot, won't boot if verification is re-enabled.
message_warn_invalid_install_kernel() {
  dev_notice dev_invalid_kernel
}

# Tell the user that the image on the recovery media can't be
# installed, either because it failed verification, or because
# the version is out of date.
#
# This is an error condition equivalent to on_error, below.
message_invalid_install_kernel() {
  instructions invalid_kernel
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_warning.png
  signal_fatal_error
}

# Tell the user that installation can't continue because the device
# owner has engaged developer mode blocking, and the image to be
# installed is not an official image.
#
# This is an error condition equivalent to on_error, below.
message_block_developer_mode() {
  instructions block_dev_mode
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_warning.png
  progress empty
  dev_notice empty
  signal_fatal_error
}

# Tell the user that the security module is hosed and point them to
# online resources for further information.
#
# This is an error condition equivalent to on_error, below.
message_security_module_failure() {
  instructions security_module_failure
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_warning.png
  progress empty
  dev_notice empty
  signal_fatal_error
}

# Tell the user that we're installing a firmware update.
message_update_firmware() {
  instructions update_firmware
  showicon empty
  progress empty
}

# Tell the user that the battery is too low to install a firmware
# update and that they need to charge the device.
message_update_firmware_low_battery() {
  instructions update_firmware_low_battery
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_warning.png
  progress empty
}

# Tell the user that the battery is too low to install a firmware
# update and that we're waiting for the battery to charge.
message_update_firmware_low_battery_charging() {
  instructions update_firmware_low_battery_charging
  showicon $INSTRUCTION_BOX_TOP $SCREENS/icon_warning.png
  progress empty
}
