#!/bin/sh
# Copyright 2020 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This consists of functions sourced by the /init script and used
# exclusively for recovery images.  Note that this code uses the
# busybox shell (not bash, not dash).

SCREENS=/etc/screens
LOCALES_TXT=/etc/locales.txt
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

# Common color codes
MENU_UI_BLACK="0x202124"
MENU_UI_GREY="0x3F4042"
MENU_UI_BLUE="0x8AB4F8"
MENU_UI_BTN_FRAME="0x9AA0A6"
MENU_UI_DROPDOWN_BG="0x2D2E30"
MENU_UI_DROPDOWN_FRAME="0x435066"
BACKGROUND="${MENU_UI_BLACK}"
ADV_BTN_BACKGROUND="0x2B2F37"

# Initialized in message_startup()
FRECON_SCALING_FACTOR=
CANVAS_SIZE=

BUTTON_HEIGHT=32
BUTTON_MARGIN=8 # 8 pixels between buttons

# Default width of screens/{lang}/*.png, used in most messages except buttons
DEFAULT_MESSAGE_WIDTH=720

MONOSPACE_GLYPH_HEIGHT=20
MONOSPACE_GLYPH_WIDTH=10

# Available options and chosen one.
NAME_LIST=
NAME=

RECOVERY_PROGRESS_BAR_PID=

# User visible message overlaid on the screen. Only use for debug features!
log() {
  echo "$@" | tee -a "${TTY_CONSOLE}" "${TTY_LOG}" >&2
}

# Like log() but with printf() semantics.
logf() {
  # shellcheck disable=SC2059
  printf "$@" | tee -a "${TTY_CONSOLE}" "${TTY_LOG}" >&2
}

# Debug messages logged to VT1 and log file.
dlog() {
  echo "$@" > "${TTY_LOG}"
}

# Like dlog() but with printf() semantics.
dlogf() {
  # shellcheck disable=SC2059
  printf "$@" > "${TTY_LOG}"
}

clear_console() {
  clear >"${TTY_CONSOLE}"
}

vpd_get_value() {
  local file="/sys/firmware/vpd/ro/$1"

  if [ -e "${file}" ]; then
    cat "${file}"
  else
    vpd -g "$1"
  fi
}

read_vpd_locale() {
  local region

  region="$(vpd_get_value region)"
  if [ -n "${region}" ]; then
    # Lookup correct value from locale list.
    sed -nre "s/^${region}\t(.*)$/\1/p" "${LOCALES_TXT}"
  else
    # Legacy devices that do not have 'region' and may have multiple locales.
    vpd -g initial_locale | sed 's/,.*//'
  fi
}

read_truncated_hwid() {
  crossystem hwid | cut -f 1 -d ' '
}

select_locale() {
  local override_locale="$1"

  if [ -n "${override_locale}" ]; then
    LANGDIR="${override_locale}"
  else
    # The region (fetched via VPD) is only available on Chrome systems.
    is_nonchrome || LANGDIR="$(read_vpd_locale)"
    if [ -z "${LANGDIR}" ] || [ ! -d "${SCREENS}/${LANGDIR}" ]; then
      dlog "initial locale '${LANGDIR}' not found"
      LANGDIR=en-US
    fi
  fi

  . "${SCREENS}/${LANGDIR}/constants.sh"
  dlog "selected locale ${LANGDIR}"
}

rtl() {
  [ "${LANGDIR}" = ar ] || [ "${LANGDIR}" = fa ] || [ "${LANGDIR}" = he ]
}

# Draws text in the center of the screen.
#
# Arg 1:  The string to draw
showtext() {
  local text="$1"
  local text_start_h="$2"
  local glyph_offset_h="$2"
  local glyph_offset_v="$3"
  local color="$4"
  local glyph_dir="${SCREENS}/glyphs/${color}"

  for char in $(printf "%s" "${text}" | hexdump -v -e '/1 "%i "'); do
    local glyph_image="${glyph_dir}/${char}.png"

    if [ "${char}" -eq 10 ]; then
      glyph_offset_v="$(( glyph_offset_v + MONOSPACE_GLYPH_HEIGHT ))"
      glyph_offset_h="${text_start_h}"
    else
      if rtl; then
        # cancel the negation in showimage()
        showimage "${glyph_image}" "$(( -glyph_offset_h ))" "${glyph_offset_v}"
      else
        showimage "${glyph_image}" "${glyph_offset_h}" "${glyph_offset_v}"
      fi

      glyph_offset_h="$(( glyph_offset_h + MONOSPACE_GLYPH_WIDTH ))"
    fi
  done
}

# Encapsulate displaying of images into single function.
#
# Arg 1:  the path to the image file
# Arg 2:  a pair of numbers X,Y representing offset from center
showimage() {
  local image="$1"
  local x="$2"
  local y="$3"

  if rtl; then
    x="$(( -x ))"
  fi

  printf "\033]image:file=%s;offset=%s;scale=%d\033\\" \
    "${image}" "${x},${y}" "${FRECON_SCALING_FACTOR}" \
    > "${TTY_CONSOLE}"
}

# Draw a single color box on the specified position
# Y-coordinate.
#
# Arg 1:  X,Y coordinate
# Arg 2:  W,H size
# Arg 3:  color
showbox() {
  local offset_x="$1"
  local offset_y="$2"
  local size_x="$3"
  local size_y="$4"
  local color="$5"

  if [ "${size_x}" -lt 1 ]; then
    size_x=1
  fi
  if [ "${size_y}" -lt 1 ]; then
    size_y=1
  fi
  if rtl; then
    offset_x="$(( -offset_x ))"
  fi

  printf \
    "\033]box:color=%s;size=%s;offset=%s;scale=%d\033\\" \
    "${color}" "${size_x},${size_y}" "${offset_x},${offset_y}" \
    "${FRECON_SCALING_FACTOR}" \
    > "${TTY_CONSOLE}"
}

showmessage() {
  local message_token="$1"
  local offset_x="$2"
  local offset_y="$3"

  # Determine the filename of the message resource. Fall back to en-US if
  # the localized version of the message is not available.
  local message_file="${SCREENS}/${LANGDIR}/${message_token}.png"
  if [ ! -f "${message_file}" ]; then
    message_file="${SCREENS}/en-US/${message_token}.png"
  fi

  showimage "${message_file}" "${offset_x}" "${offset_y}"
}

# Display a message in the "instructions" box.
#
# Arg 1:  a token identifying the message, which is used to form the
#   file name based on the current locale.
instructions() {
  local x="$(( -CANVAS_SIZE / 2 + DEFAULT_MESSAGE_WIDTH / 2 ))"
  local y="$(( -CANVAS_SIZE / 2 + 283 ))"

  showmessage "$1" "${x}" "${y}"
}

instructions_with_title() {
  local message_token=$1

  local title_x="$(( -CANVAS_SIZE / 2 + DEFAULT_MESSAGE_WIDTH / 2 ))"

  local title_height desc_height
  eval "title_height=\${TITLE_${message_token}_HEIGHT}"
  eval "desc_height=\${DESC_${message_token}_HEIGHT}"
  local title_y="$(( -CANVAS_SIZE / 2 + 220 + title_height / 2 ))"
  local desc_y="$(( title_y + title_height / 2 + 16 + desc_height / 2 ))"

  showmessage "title_${message_token}" "${title_x}" "${title_y}"
  showmessage "desc_${message_token}" "${title_x}" "${desc_y}"
}

# Ensure that val is in the range [min, max]
#
# Arg 1:  val
# Arg 2:  min
# Arg 3:  max
clamp() {
  local val=$1
  local min=$2
  local max=$3

  if [ "${val}" -lt "${min}" ]; then
    val="${min}"
  fi
  if [ "${val}" -gt "${max}" ]; then
    val="${max}"
  fi

  echo "${val}"
}

# Incrementally draw progress bar in the 'progress' box.
#
# Arg 1, 2: the interval to add, in range [0, 1000]
# Arg 3: color (use MENU_UI_GREY for background, MENU_UI_BLUE for foreground)
show_progress_bar() {
  local range_left
  local range_right
  range_left="$(clamp "$1" 0 1000)"
  range_right="$(clamp "$2" 0 1000)"
  local color=$3

  local progress_height=4
  local full_width="${CANVAS_SIZE}"

  local progress_length="$(( range_right - range_left ))"
  if [ "${progress_length}" -le 0 ]; then
    return 0
  fi

  # mid point and size of the filled area
  local offset_x="$(( (range_left + range_right) * full_width / 2000
                      - full_width / 2 ))"
  # add one extra pixel to prevent rounding error
  local size_x="$(( progress_length * full_width / 1000 + 1 ))"

  showbox "${offset_x}" 0 "${size_x}" "${progress_height}" "${color}"
}

# Read progress from stdin and display in progress bar
#
# This is the public interface for other scripts like recovery_init.sh
progress_bar() {
  local percent=""

  show_progress_bar 0 1000 "${MENU_UI_GREY}"
  while read -r percent; do
    show_progress_bar 0 "$(( percent * 10 ))" "${MENU_UI_BLUE}"
  done
}

clear_main_area() {
  # clear everything above footer
  local footer_height=142
  showbox \
    0 "$(( -footer_height / 2 ))" \
    "$(( CANVAS_SIZE + 100 ))" "$(( CANVAS_SIZE - footer_height ))" \
    "${BACKGROUND}"
}

clear_screen() {
  # clear all
  showbox 0 0 "$(( CANVAS_SIZE + 100 ))" "${CANVAS_SIZE}" "${BACKGROUND}"
}

# Enforce a delay on the user for security's sake.  A progress bar
# shows the time so that the impatient will not also be in the dark.
#
# Arg 1:  the wait time in seconds.
make_user_wait() {
  local seconds=$1

  # 100 updates because progress_bar wants percentages.
  local num_updates=100
  local ms_per_update="$(( (2 * 1000 * seconds / num_updates + 1) / 2 ))"
  local delay_sec="$(( ms_per_update / 1000 ))"
  local delay_ms="$(( ms_per_update % 1000 ))"
  local delay
  delay=$(printf "%d.%03d" "${delay_sec}" "${delay_ms}")

  show_progress_bar 0 1000 "${MENU_UI_GREY}"
  for i in $(seq 1 "${num_updates}"); do
    sleep "${delay}"
    show_progress_bar 0 "$(( i * 10 ))" "${MENU_UI_BLUE}"
  done
}

show_indeterminate_progress_bar() {
  local size=400
  local step=5
  local left="$(( -size ))"

  set +x
  show_progress_bar 0 1000 "${MENU_UI_GREY}"

  while true; do
    local right="$(( left + size ))"

    show_progress_bar "${right}" "$(( right + step ))" "${MENU_UI_BLUE}"
    show_progress_bar "${left}" "$(( left + step ))" "${MENU_UI_GREY}"

    left="$(( left + step ))"
    if [ "${left}" -ge 1000 ]; then
      left="$(( -size ))"
    fi

    sleep 0.01s
  done
}

is_detachable() {
  if [ -f /etc/cros-initramfs/unibuild ] ; then
    model=$(crosid | \
            awk -F"=" '$1=="FIRMWARE_MANIFEST_KEY" {print $2}' | \
            tr -d "'")
    if [ -z "${model}" ]; then
      return 1
    fi

    [ -f "/etc/cros-initramfs/${model}/detachable_ui" ]
  else
    [ -f /etc/cros-initramfs/is_detachable ]
  fi
}

wait_menu_input() {
  local KEY_UP=103
  local KEY_DOWN=108
  local KEY_ENTER=28

  local KEY_VOLDOWN=114
  local KEY_VOLUP=115
  local KEY_POWER=116

  local all_keys

  if is_detachable; then
    all_keys="${KEY_VOLDOWN}:${KEY_VOLUP}:${KEY_POWER}"
  else
    all_keys="${KEY_DOWN}:${KEY_UP}:${KEY_ENTER}"
  fi

  local key
  while true; do
    if evwaitkey --check --keys "${all_keys}" --include_usb; then
      key="$(evwaitkey --keys "${all_keys}" --include_usb)"
      break
    fi

    # Sleep 1 second and probe again if no valid device found.
    sleep 1s
  done

  case "${key}" in
    "${KEY_UP}"|"${KEY_VOLUP}")
      echo 'up'
      ;;
    "${KEY_DOWN}"|"${KEY_VOLDOWN}")
      echo 'down'
      ;;
    "${KEY_POWER}"|"${KEY_ENTER}")
      echo 'enter'
      ;;
    *)
      echo "${key}"
      ;;
  esac
}

kill_progress_bar() {
  if [ ! -z "${RECOVERY_PROGRESS_BAR_PID}" ]; then
    kill "${RECOVERY_PROGRESS_BAR_PID}"
    wait "${RECOVERY_PROGRESS_BAR_PID}"
    RECOVERY_PROGRESS_BAR_PID=""
  fi
}

showbutton() {
  local message_token="$1"
  local offset_y="$2"
  local focused="$3"
  local inner_width="$4"
  local btn_padding=32 # left and right padding
  local left_padding_x="$(( -CANVAS_SIZE / 2 + btn_padding / 2 ))"
  local offset_x="$(( left_padding_x + btn_padding / 2 + inner_width / 2 ))"
  local right_padding_x="$(( offset_x + btn_padding / 2 + inner_width / 2 ))"

  # clear previous state
  showbox "${offset_x}" "${offset_y}" "$(( btn_padding * 2 + inner_width ))" \
    "${BUTTON_HEIGHT}" "${BACKGROUND}"

  if rtl; then
    # swap left and right border
    local temp="${left_padding_x}"
    left_padding_x="${right_padding_x}"
    right_padding_x="${temp}"
  fi

  if [ "${focused}" -ne 0 ]; then
    showimage "${SCREENS}/btn_bg_left_focused.png" \
      "${left_padding_x}" "${offset_y}"
    showimage "${SCREENS}/btn_bg_right_focused.png" \
      "${right_padding_x}" "${offset_y}"
    showbox "${offset_x}" "${offset_y}" "${inner_width}" "${BUTTON_HEIGHT}" \
      "${MENU_UI_BLUE}"

    showmessage "${message_token}_focused" "${offset_x}" "${offset_y}"
  else
    showimage "${SCREENS}/btn_bg_left.png" \
      "${left_padding_x}" "${offset_y}"
    showimage "${SCREENS}/btn_bg_right.png" \
      "${right_padding_x}" "${offset_y}"

    showmessage "${message_token}" "${offset_x}" "${offset_y}"

    # drow top/down border on top of the message
    showbox "${offset_x}" "$(( offset_y - BUTTON_HEIGHT / 2 + 1 ))" \
      "${inner_width}" 1 "${MENU_UI_BTN_FRAME}"
    showbox "${offset_x}" "$(( offset_y + BUTTON_HEIGHT / 2  ))" \
      "${inner_width}" 1 "${MENU_UI_BTN_FRAME}"
  fi
}

showadvoption() {
  local icon_token=$1
  local message_token=$2
  local offset_y=$3
  # text width + 16px and 12px spacing + 20px icon * 2
  local inner_width="$(( ADV_OPTION_BTN_WIDTH + 68 ))"
  local left_padding=16
  local right_padding=12
  local left_padding_x="$(( -CANVAS_SIZE / 2 - left_padding / 2 ))"
  local right_padding_x="$(( -CANVAS_SIZE / 2 + inner_width +
      right_padding / 2 ))"

  # clear previous state
  showbox "$(( -CANVAS_SIZE / 2 + inner_width / 2 ))" "${offset_y}" \
    "$(( inner_width + 40 ))" "${BUTTON_HEIGHT}" \
    "${BACKGROUND}"

  eval "local msg_width=\${BUTTON_${message_token}_WIDTH}"
  local icon_x="$(( -CANVAS_SIZE / 2 + 10 ))"
  local msg_x="$(( icon_x + 26 + msg_width / 2 ))"
  local arrow_x="$(( msg_x + msg_width / 2 + 22 ))"

  local focused
  if [ "$4" -ne 0 ]; then
    focused=_focused
  fi

  local arrow_dir=right
  if rtl; then
    # swap left and right border
    local temp="${left_padding_x}"
    left_padding_x="${right_padding_x}"
    right_padding_x="${temp}"

    arrow_dir=left
  fi

  if [ -n "${focused}" ]; then
    showimage "${SCREENS}/adv_btn_bg_left.png" \
      "${left_padding_x}" "${offset_y}"
    showimage "${SCREENS}/adv_btn_bg_right.png" \
      "${right_padding_x}" "${offset_y}"
    showbox "$(( -CANVAS_SIZE / 2 + inner_width / 2 ))" "${offset_y}" \
      "$(( inner_width + 2 ))" "${BUTTON_HEIGHT}" "${MENU_UI_BLUE}"
    showbox "$(( -CANVAS_SIZE / 2 + inner_width / 2 ))" "${offset_y}" \
      "$(( inner_width + 2 ))" "$(( BUTTON_HEIGHT - 4 ))" \
      "${ADV_BTN_BACKGROUND}"
  fi

  showimage "${SCREENS}/${icon_token}${focused}.png" "${icon_x}" "${offset_y}"
  showmessage "${message_token}${focused}" "${msg_x}" "${offset_y}"
  showimage "${SCREENS}/ic_drop${arrow_dir}-blue${focused}.png" \
    "${arrow_x}" "${offset_y}"
}

on_error_onselect() {
  local selected_index=$1

  case "${selected_index}" in
    0)
      message language_menu
      ;;
    1)
      reboot -f
      ;;
    2)
      poweroff -f
      ;;
    3)
      message recovery_debug_options
      ;;
  esac

  return 0
}

on_error_onchange() {
  local selected_index=$1
  # 40px below description.
  local btn_y="$(( -CANVAS_SIZE / 2 + 220 + TITLE_recovery_failed_HEIGHT +
    DESC_recovery_failed_HEIGHT + 40 + BUTTON_HEIGHT / 2 ))"
  local adv_y="$(( CANVAS_SIZE / 2 - 222 ))"
  local adv_btn_height=32
  local adv_btn_padding=8

  echo "message_on_error, index: ${selected_index}"
  message_base_screen
  instructions_with_title recovery_failed
  show_stepper_error

  show_language_menu "$(( selected_index == 0 ))"
  showbutton btn_try_again "${btn_y}" "$(( selected_index == 1 ))" \
    "${ON_ERROR_BTN_WIDTH}"
  showadvoption power btn_power_off "${adv_y}" "$(( selected_index == 2 ))"
  adv_y="$(( adv_y + adv_btn_height + adv_btn_padding ))"
  showadvoption settings btn_debug_options "${adv_y}" \
    "$(( selected_index == 3 ))"
}

# Generic message to report an error.
message_on_error() {
  kill_progress_bar
  message_base_screen
  menu_event_loop 4 1 on_error_onchange on_error_onselect
}

menu_event_loop() {
  local menu_count=$1
  local selected_index=$2
  local onchange=$3
  local onselect=$4

  while true; do
    local action

    ${onchange} "${selected_index}"

    case "$(wait_menu_input)" in
      up)
        if [ "${selected_index}" -gt 0 ]; then
          selected_index="$(( selected_index - 1 ))";
        fi
        ;;
      down)
        if [ "${selected_index}" -lt "$(( menu_count - 1 ))" ]; then
          selected_index="$(( selected_index + 1 ))";
        fi
        echo down
        ;;
      enter)
        "${onselect}" "${selected_index}"

        local exit=$?
        if [ "${exit}" -ne 0 ]; then
          return 0
        fi
        ;;
      *)
        echo "unknown key: ${action}"
        ;;
    esac
  done
}

recovery_debug_options_onselect() {
  local selected_index=$1

  case "${selected_index}" in
    0)
      message language_menu
      ;;
    1)
      # TODO: error page not implemented, save_log_files does not return errors
      save_log_files
      echo 'copy log'
      ;;
    2)
      # In the error handling flow we should not assume external USB drive is
      # accessible, thus we use the original log file instead of the copy in
      # LOG_DIR here.
      message_view_log title_recovery_log /var/log/recovery.log
      ;;
    3)
      # Dump dmesg in /tmp for the same reason above.
      local tmpfile
      tmpfile="$(mktemp)"
      dmesg > "${tmpfile}"
      message_view_log title_message_log "${tmpfile}"
      rm "${tmpfile}"
      ;;
    4)
      clear_screen
      return 1
      ;;
  esac

  return 0
}

recovery_debug_options_onchange() {
  local selected_index=$1
  local text_x="$(( -CANVAS_SIZE / 2 + DEFAULT_MESSAGE_WIDTH / 2 ))"
  local title_y="$(( -CANVAS_SIZE / 2 + 220 + 18 ))"

  echo "message_debug_options, index: ${selected_index}"

  message_base_screen
  showmessage title_debug_options "${text_x}" "${title_y}"

  show_language_menu "$(( selected_index == 0 ))"

  local btn_y="$(( title_y + 18 + 40 ))" # padding 40
  local btn_y_step="$(( BUTTON_HEIGHT + BUTTON_MARGIN ))"
  showmessage tip_copy_logs "${text_x}" "${btn_y}"
  btn_y=$(( btn_y + btn_y_step ))
  showbutton btn_copy_logs "${btn_y}" "$(( selected_index == 1 ))" \
    "${DEBUG_OPTIONS_BTN_WIDTH}"

  btn_y=$(( btn_y + btn_y_step * 2 ))
  showmessage tip_view_logs "${text_x}" "${btn_y}"
  btn_y=$(( btn_y + btn_y_step ))
  showbutton btn_recovery_log "${btn_y}" "$(( selected_index == 2 ))" \
    "${DEBUG_OPTIONS_BTN_WIDTH}"
  btn_y=$(( btn_y + btn_y_step ))
  showbutton btn_message_log "${btn_y}" "$(( selected_index == 3 ))" \
    "${DEBUG_OPTIONS_BTN_WIDTH}"
  btn_y=$(( btn_y + btn_y_step ))
  showbutton btn_back "${btn_y}" "$(( selected_index == 4 ))" \
    "${DEBUG_OPTIONS_BTN_WIDTH}"
}

message_recovery_debug_options() {
  menu_event_loop 5 1 recovery_debug_options_onchange \
    recovery_debug_options_onselect
}

# variables shared between log related functions
LOG_LINES_PER_PAGE=13
LOG_CHAR_PER_LINE=79
LOG_AREA_Y=196  # y-coord of the upper edge of the log area, 16px below title
LOG_AREA_WIDTH="$(( MONOSPACE_GLYPH_WIDTH * LOG_CHAR_PER_LINE ))"
LOG_AREA_HEIGHT="$(( MONOSPACE_GLYPH_HEIGHT * LOG_LINES_PER_PAGE ))"

log_path=
log_line_pos=1
log_num_lines=

update_log_area() {
  showimage "${SCREENS}/log_area_border.png" \
    "$(( -CANVAS_SIZE / 2 + (LOG_AREA_WIDTH + 10) / 2 ))" \
    "$(( -CANVAS_SIZE / 2 + LOG_AREA_Y + LOG_AREA_HEIGHT / 2 ))"

  local txt
  txt=$(sed "${log_line_pos},+$(( LOG_LINES_PER_PAGE - 1 )) !d" "${log_path}" \
    | cut -c "1-${LOG_CHAR_PER_LINE}")
  showtext "${txt}" "$(( -CANVAS_SIZE / 2 + MONOSPACE_GLYPH_WIDTH ))" \
    "$(( -CANVAS_SIZE / 2 + LOG_AREA_Y + MONOSPACE_GLYPH_HEIGHT / 2 ))" \
    'white'
}

view_log_onselect() {
  local selected_index=$1

  case "${selected_index}" in
    0)
      log_line_pos="$(( log_line_pos - LOG_LINES_PER_PAGE ))"
      if [ "${log_line_pos}" -lt 1 ]; then
        log_line_pos=1
      fi
      update_log_area
      ;;
    1)
      log_line_pos="$(( log_line_pos + LOG_LINES_PER_PAGE ))"
      if [ "${log_line_pos}" -gt "${log_num_lines}" ]; then
        log_line_pos="${log_num_lines}"
      fi
      update_log_area
      ;;
    2)
      clear_main_area
      return 1
      ;;
  esac
  return 0
}

view_log_onchange() {
  local selected_index=$1
  local btn_y="$(( -CANVAS_SIZE / 2 + LOG_AREA_Y + LOG_AREA_HEIGHT +
                   16 + BUTTON_HEIGHT / 2 ))"
  local adv_y="$(( CANVAS_SIZE / 2 - 182 ))"

  showbutton btn_page_up "${btn_y}" "$(( selected_index == 0 ))" \
    "${VIEW_LOG_BTN_WIDTH}"
  btn_y="$(( btn_y + BUTTON_HEIGHT + BUTTON_MARGIN ))"
  showbutton btn_page_down "${btn_y}" "$(( selected_index == 1 ))" \
    "${VIEW_LOG_BTN_WIDTH}"
  btn_y="$(( btn_y + BUTTON_HEIGHT + BUTTON_MARGIN ))"
  showbutton btn_back "${btn_y}" "$(( selected_index == 2 ))" \
    "${VIEW_LOG_BTN_WIDTH}"
  showadvoption power btn_power_off "${adv_y}" "$(( selected_index == 3 ))"
}

message_view_log() {
  local title_x="$(( -CANVAS_SIZE / 2 + DEFAULT_MESSAGE_WIDTH / 2 ))"
  local title_y="$(( -CANVAS_SIZE / 2 + 162 ))"

  local title="$1"
  # global variables
  log_path="$2"
  log_line_pos=1
  log_num_lines=$(wc -l "${log_path}")

  message_base_screen
  showmessage "${title}" "${title_x}" "${title_y}"
  update_log_area
  menu_event_loop 4 0 view_log_onchange view_log_onselect
}

# First message we display at start up.
#
# This message also appears when booting factory images.
message_startup() {
  # b/158282097: force reprobe since type-c to DP connectors
  # seems not detected at boot
  for f in /sys/class/drm/*/status; do
    echo detect > "${f}"
  done
  sleep 1s

  local resolution
  resolution="$(frecon-lite --print-resolution || echo 1000 1000)"
  local x_res="${resolution% *}"
  local y_res="${resolution#* }"

  if [ "${x_res}" -le "${y_res}" ]; then
    # for tablet mode, add 20px margin for left and right edge.
    CANVAS_SIZE="$(( x_res - 40 ))"
  else
    CANVAS_SIZE="${y_res}"
  fi

  if [ "${CANVAS_SIZE}" -ge 1920 ]; then
    FRECON_SCALING_FACTOR=2
    CANVAS_SIZE="$(( CANVAS_SIZE / 2 ))"
  else
    FRECON_SCALING_FACTOR=1
  fi

  frecon-lite --enable-vt1 --daemon --no-login --enable-gfx \
    --enable-vts --scale="${FRECON_SCALING_FACTOR}" \
    --clear "${BACKGROUND}" --pre-create-vts \
    /dev/null

  # Turn of keyboard input processing.
  # We can't use ${TTY_CONSOLE} here since it is initialized after
  # this function.
  printf "\033]input:off\a" > /run/frecon/vt0

  . "${SCREENS}/lang_constants.sh"

  # If error happened before we can read vpd to determine locale,
  # initialize it to en
  if [ -z "${LANGDIR}" ]; then
    select_locale en-US
  fi
}

# not used, was smething like
# "hold power button 8 seconds to cancel"
message_validate() {
  :
}

# Tell the user the system developer mode switch is on.
message_developer_image() {
  message_base_screen
  instructions unverified
  show_stepper_in_progress
}

# Tell the user that they must endure the 5 minute wait for a
# developer key change.
message_key_change() {
  message_base_screen
  instructions key_change
  show_stepper_in_progress
  make_user_wait 300
}

# Announce that recovery is about to start. Start the moving box animation that
# will persist until recovery is complete.
message_recovery_start() {
  message_base_screen
  instructions recovering
  show_stepper_in_progress
  show_indeterminate_progress_bar &
  RECOVERY_PROGRESS_BAR_PID=$!
}

# not used
# Announce that enhanced disk wipe is started.
message_disk_wipe_start() {
  :
}

# not used
# Kill the spinner for disk wipe.
message_disk_wipe_end() {
  :
}

message_recovery_complete() {
  kill_progress_bar
  message_base_screen
  instructions_with_title recovery_complete
  show_stepper_done
}

# The same as message_recovery_complete, but with a different message notifying
# the user that their computer will automatically restart.
message_recovery_complete_noninteractive() {
  kill_progress_bar
  message_base_screen
  instructions complete_noninteractive
  show_stepper_done
  make_user_wait 10
}

# Kill the spinner animation and announce that recovery is
# complete and enhanced disk wipe is successful.
message_recovery_complete_wipe_successful() {
  kill_progress_bar
  message_base_screen
  instructions recovery_complete_wipe_success
  show_stepper_done
}


# Kill the spinner animation and announce that recovery is
# complete and enhanced disk wipe is failed.
message_recovery_complete_wipe_fail() {
  kill_progress_bar
  message_base_screen
  instructions recovery_complete_wipe_fail
  show_stepper_error
}


# Kill the spinner animation and inform user that an error occured
# during recovery but enhanced disk wipe is successful.
message_recovery_error_wipe_fail() {
  kill_progress_bar
  message_base_screen
  instructions recovery_error_wipe_fail
  show_stepper_error
}

# Kill the spinner animation and inform user that an error occured
# during both recovery and enhanced disk wipe.
message_recovery_error_wipe_success() {
  kill_progress_bar
  message_base_screen
  instructions recovery_error_wipe_success
  show_stepper_error
}

# Warn the user that the current image, although valid for
# unverified boot, won't boot if verification is re-enabled.
message_warn_invalid_install_kernel() {
  message_base_screen
  instructions dev_invalid_kernel
  show_stepper_error
}

# Tell the user that the image on the recovery media can't be
# installed, either because it failed verification, or because
# the version is out of date.
#
# This is an error condition equivalent to on_error, below.
message_invalid_install_kernel() {
  message_base_screen
  instructions invalid_kernel
  show_stepper_error
  signal_fatal_error
}

# Tell the user that installation can't continue because the device
# owner has engaged developer mode blocking, and the image to be
# installed is not an official image.
#
# This is an error condition equivalent to on_error, below.
message_block_developer_mode() {
  message_base_screen
  instructions block_dev_mode
  show_stepper_error
  signal_fatal_error
}

# Tell the user that the security module is hosed and point them to
# online resources for further information.
#
# This is an error condition equivalent to on_error, below.
message_security_module_failure() {
  message_base_screen
  instructions security_module_failure
  show_stepper_error
  signal_fatal_error
}

# Tell the user that we're installing a firmware update.
message_update_firmware() {
  instructions update_firmware
  message_base_screen
  show_stepper_in_progress
}

# Tell the user that the battery is too low to install a firmware
# update and that they need to charge the device.
message_update_firmware_low_battery() {
  message_base_screen
  instructions update_firmware_low_battery
  show_stepper_error
}

# Tell the user that the battery is too low to install a firmware
# update and that we're waiting for the battery to charge.
message_update_firmware_low_battery_charging() {
  message_base_screen
  instructions update_firmware_low_battery_charging
  show_stepper_error
}

language_onselect() {
  local selected_index=$1

  if [ "${selected_index}" -gt 0 ]; then
    local override_locale
    override_locale="$(echo "${SUPPORTED_LOCALES}" | \
                       cut -d' ' -f"${selected_index}")"
    select_locale "${override_locale}"
  fi

  clear_screen
  return 1
}

language_onchange() {
  local selected_index=$1

  show_language_menu "$(( selected_index == 0 ))"
  # shellcheck disable=SC2086
  show_language_dropdown "$(( selected_index - 1 ))" ${SUPPORTED_LOCALES}
}

message_language_menu() {
  message_base_screen

  local selected_index=0
  local i=0
  for locale in ${SUPPORTED_LOCALES}; do
    i="$(( i + 1 ))"
    if [ "${locale}" = "${LANGDIR}" ]; then
      selected_index="${i}"
      break
    fi
  done

  local locale_count
  locale_count="$(echo "${SUPPORTED_LOCALES}" | wc -w)"
  menu_event_loop "$(( locale_count + 1 ))" "${selected_index}" \
    language_onchange language_onselect
}

get_language_string_width() {
  local locale="$1"

  local lang_width
  eval "lang_width=\${LANGUAGE_$(echo "$1" | tr - _)_WIDTH}"
  echo "${lang_width}"
}

show_language_dropdown() {
  local selected_index="$1"
  shift

  local item_height=40
  local item_per_page="$(( (CANVAS_SIZE - 260) / item_height ))"
  local item_count="$#"

  # put the focused item on middle of the screen if possible
  local begin_index="$(( selected_index - item_per_page / 2 ))"
  if [ "${begin_index}" -lt 0 ]; then
    begin_index=0
  elif [ "$(( begin_index + item_per_page ))" -gt "${item_count}" ]; then
    begin_index="$(( item_count - item_per_page ))"
  fi
  shift "${begin_index}"

  local i="${begin_index}"
  local offset_y="$(( -CANVAS_SIZE / 2 + 88 ))"
  local background_x="$(( -CANVAS_SIZE / 2 + 360 ))"
  local lang_x lang_width
  while [ "${i}" -lt "$(( begin_index + item_per_page ))" ] && \
        [ "${i}" -lt "${item_count}" ]; do
    lang_width="$(get_language_string_width "$1")"
    lang_x="$(( -CANVAS_SIZE / 2 + lang_width / 2 + 40 ))"
    if [ "${selected_index}" -eq "${i}" ]; then
      showbox "${background_x}" "${offset_y}" 720 40 "${MENU_UI_BLUE}"
      showimage "${SCREENS}/$1/language_focused.png" "${lang_x}" "${offset_y}"
    else
      showbox "${background_x}" "${offset_y}" 720 40 "${MENU_UI_DROPDOWN_FRAME}"
      showbox "${background_x}" "${offset_y}" 718 38 "${MENU_UI_DROPDOWN_BG}"
      showimage "${SCREENS}/$1/language.png" "${lang_x}" "${offset_y}"
    fi

    i="$(( i + 1 ))"
    offset_y="$(( offset_y + item_height ))"
    shift
  done
}

show_stepper() {
  # the icon real size is 24x24, but it occupies a 36x36 block.
  # use 36 here for simplicity.
  local icon_size=36
  local separator_length=46
  local padding=6

  local stepper_x="$(( -CANVAS_SIZE / 2 + icon_size / 2 ))"
  local stepper_x_step="$(( icon_size + separator_length + padding * 2 ))"
  local stepper_y="$(( 144 - CANVAS_SIZE / 2 ))"
  local separator_x="$(( -CANVAS_SIZE / 2 + icon_size + padding + \
    separator_length / 2 ))"
  local separator_color="${MENU_UI_GREY}"

  showimage "${SCREENS}/ic_$1.png" "${stepper_x}" "${stepper_y}"
  showimage "${SCREENS}/ic_$2.png" \
    "$(( stepper_x + stepper_x_step ))" "${stepper_y}"
  showimage "${SCREENS}/ic_$3.png" \
    "$(( stepper_x + stepper_x_step * 2 ))" "${stepper_y}"

  showbox "${separator_x}" "${stepper_y}" "${separator_length}" 1 \
    "${separator_color}"
  showbox "$(( separator_x + stepper_x_step ))" "${stepper_y}" \
    "${separator_length}" 1 \
    "${separator_color}"
}

show_stepper_done() {
  show_stepper 'done' 'done' 'done'
}

show_stepper_error() {
  show_stepper 'done' 'done' 'stepper_error'
}

show_stepper_in_progress() {
  show_stepper 'done' 'done' '3-done'
}

# args offset, message
show_string_locale() {
  local offset_x="$1"
  local offset_y="$2"
  local message_token="$3"

  # Determine the filename of the message resource. Fall back to en-US if
  # the localized version of the message is not available.
  local message_file="${SCREENS}/${LANGDIR}/${message_token}.png"
  if [ ! -f "${message_file}" ]; then
    message_file="${SCREENS}/en-US/${message_token}.png"
  fi

  showimage "${message_file}" "${offset_x}" "${offset_y}"
}

show_language_menu() {
  local focused="$1"

  local offset_y="$(( -CANVAS_SIZE / 2 + 40 ))"
  local bg_x="$(( -CANVAS_SIZE / 2 + 145 ))"
  local globe_x="$(( -CANVAS_SIZE / 2 + 20 ))"
  local arrow_x="$(( -CANVAS_SIZE / 2 + 268 ))"
  local lang_width
  lang_width="$(get_language_string_width "${LANGDIR}")"
  local text_x="$(( -CANVAS_SIZE / 2 + 40 + lang_width / 2 ))"

  local menu_bg="${SCREENS}/language_menu_bg_focused.png"
  if [ "${focused:-0}" -eq 0 ]; then
    menu_bg="${SCREENS}/language_menu_bg.png"
  fi

  showimage "${menu_bg}" "${bg_x}" "${offset_y}"
  showimage "${SCREENS}/ic_language-globe.png" "${globe_x}" "${offset_y}"
  showimage "${SCREENS}/ic_dropdown.png" "${arrow_x}" "${offset_y}"
  showmessage "language_folded" "${text_x}" "${offset_y}"
}

show_footer() {
  local qr_code_size=86
  local qr_code_x="$(( -CANVAS_SIZE / 2 + qr_code_size / 2 ))"
  local qr_code_y="$(( CANVAS_SIZE / 2 - 56 - qr_code_size / 2 ))"

  local seperator_x="$(( 410 - CANVAS_SIZE / 2 ))"
  local seperator_y="${qr_code_y}"

  local footer_line_height=18
  local footer_y="$(( CANVAS_SIZE / 2 - 56 - qr_code_size + 9 ))"
  local footer_left_x="$(( qr_code_x + qr_code_size / 2 + 16 + \
      DEFAULT_MESSAGE_WIDTH / 2 ))"
  local footer_right_x="$(( seperator_x + 32 + DEFAULT_MESSAGE_WIDTH / 2 ))"

  show_string_locale "${footer_left_x}" "${footer_y}" footer_left_1
  show_string_locale "${footer_left_x}" \
    "$(( footer_y + footer_line_height * 2 + 14 ))" footer_left_2
  show_string_locale "${footer_left_x}" \
    "$(( footer_y + footer_line_height * 3 + 14 ))" footer_left_3

  local nav_btn_height=24
  local nav_btn_x="$(( seperator_x + 32 ))"
  local nav_btn_y="$(( CANVAS_SIZE / 2 - 56 - nav_btn_height / 2 ))"
  local footer_type=clamshell
  local nav_key_enter=key_enter
  local nav_key_up=key_up
  local nav_key_down=key_down
  local enter_icon_width=66
  local up_down_icon_width=24
  local icon_padding=8

  if is_detachable; then
    footer_type=tablet
    nav_key_enter=button_power
    nav_key_up=button_volume_up
    nav_key_down=button_volume_down
    enter_icon_width=40
  fi
  show_string_locale "${footer_right_x}" "${footer_y}" \
    "footer_right_1_${footer_type}"
  show_string_locale "${footer_right_x}" \
    "$(( footer_y + footer_line_height + 8 ))" "footer_right_2_${footer_type}"

  nav_btn_x="$(( nav_btn_x + enter_icon_width / 2 ))"
  showimage "${SCREENS}/nav-${nav_key_enter}.png" "${nav_btn_x}" "${nav_btn_y}"
  nav_btn_x="$(( nav_btn_x + enter_icon_width / 2 + icon_padding + \
    up_down_icon_width / 2 ))"
  showimage "${SCREENS}/nav-${nav_key_up}.png" "${nav_btn_x}" "${nav_btn_y}"
  nav_btn_x="$(( nav_btn_x + icon_padding + up_down_icon_width ))"
  showimage "${SCREENS}/nav-${nav_key_down}.png" "${nav_btn_x}" "${nav_btn_y}"

  showimage "${SCREENS}/qr_code.png" "${qr_code_x}" "${qr_code_y}"

  local hwid
  hwid="$(read_truncated_hwid)"
  local hwid_len="${#hwid}"
  local hwid_x="$(( qr_code_x + qr_code_size / 2 + 16 + 5 ))"
  local hwid_y="$(( footer_y + footer_line_height ))"
  if rtl; then
    hwid_x="$(( -hwid_x - MONOSPACE_GLYPH_WIDTH * (hwid_len - 2) ))"
  fi

  showtext "${hwid}" "${hwid_x}" "${hwid_y}" grey
  showbox "${seperator_x}" "${seperator_y}" 1 "${qr_code_size}" \
    "${MENU_UI_GREY}"
}

message_base_screen() {
  clear_main_area
  show_language_menu
  show_footer
}

message_recovery_in_progress() {
  message_base_screen
  instructions_with_title recovery_in_progress
  show_stepper_in_progress
}

# MINIOS SCREENS AND FUNCTIONS.

show_button_text() {
  local text="$1"
  local offset_y="$2"
  local focused="$3"
  local inner_width="$4"

  local btn_padding=32 # Left and right padding.
  local left_padding_x="$(( -CANVAS_SIZE / 2 + btn_padding / 2 ))"
  local offset_x="$(( left_padding_x + btn_padding / 2 + inner_width / 2 ))"
  local right_padding_x="$(( offset_x + btn_padding / 2 + inner_width / 2 ))"

  # Clear previous state.
  showbox "${offset_x}" "${offset_y}" "$(( btn_padding * 2 + inner_width ))" \
     "${BUTTON_HEIGHT}" "${BACKGROUND}"
  if rtl; then
    # Swap left and right border.
    local temp="${left_padding_x}"
    left_padding_x="${right_padding_x}"
    right_padding_x="${temp}"
  fi

  if [ "${focused}" -ne 0 ]; then
    showimage "${SCREENS}/btn_bg_left_focused.png" \
      "${left_padding_x}" "${offset_y}"
    showimage "${SCREENS}/btn_bg_right_focused.png" \
      "${right_padding_x}" "${offset_y}"
    showbox "${offset_x}" "$((offset_y))" "${inner_width}" "${BUTTON_HEIGHT}" \
       "${MENU_UI_BLUE}"
    showtext "${text}" "$((left_padding_x))" "${offset_y}" 'black'

  else
    showimage "${SCREENS}/btn_bg_left.png" \
      "${left_padding_x}" "${offset_y}"
    showimage "${SCREENS}/btn_bg_right.png" \
      "${right_padding_x}" "${offset_y}"
    # Draw top/down border on top of the message.
    showbox "${offset_x}" "$(( offset_y - (BUTTON_HEIGHT / 2) + 1))" \
      "${inner_width}" 1 "${MENU_UI_BTN_FRAME}"
    showbox "${offset_x}" "$(( offset_y + (BUTTON_HEIGHT / 2) ))" \
      "${inner_width}" 1 "${MENU_UI_BTN_FRAME}"
    showtext "${text}" "$((left_padding_x))" "${offset_y}" 'white'
  fi
}

minios_welcome_onselect () {
  local selected_index=$1
  case "${selected_index}" in
    0)
      message language_menu
      ;;
    1)
      message minios_dropdown
      ;;
    2)
      message minios_welcome
      ;;
  esac

  return 0
}

minios_welcome_onchange() {
  local selected_index=$1
  local title_y="$(( (-CANVAS_SIZE / 2) + 220 + 18 ))"

  message_base_screen
  instructions_with_title MiniOS_welcome
  show_stepper '1' '2' '3'
  show_language_menu "$(( selected_index == 0 ))"

  local btn_y="$(( title_y +80 ))"
  local btn_y_step="$(( BUTTON_HEIGHT + BUTTON_MARGIN ))"
  btn_y=$(( btn_y + btn_y_step * 2 ))
  showbutton btn_next "${btn_y}" "$(( selected_index == 1 ))" \
    "${DEBUG_OPTIONS_BTN_WIDTH}"
  btn_y=$(( btn_y + btn_y_step ))
  showbutton btn_back "${btn_y}" "$(( selected_index == 2 ))" \
    "${DEBUG_OPTIONS_BTN_WIDTH}"
}

message_minios_welcome() {
  message_base_screen
  REGION="$(vpd_get_value region)"
  dlog "MiniOS_welcome: VPD region is ${REGION}"
  menu_event_loop 3 1 minios_welcome_onchange minios_welcome_onselect
  return 0
}

show_item_menu(){
  local focused="$1"

  local offset_y="$(( (-CANVAS_SIZE / 2) + 350 ))"
  local bg_x="$(( (-CANVAS_SIZE / 2) + 145 ))"
  local globe_x="$(( (-CANVAS_SIZE / 2 )+ 20 ))"
  local arrow_x="$(( (-CANVAS_SIZE / 2) + 268 ))"
  local text_x="$(( (-CANVAS_SIZE / 2) + 100 ))"

  local menu_bg="${SCREENS}/language_menu_bg_focused.png"
  if [ "${focused:-0}" -eq 0 ]; then
    menu_bg="${SCREENS}/language_menu_bg.png"
  fi

  showimage "${menu_bg}" "${bg_x}" "${offset_y}"
  showimage "${SCREENS}/ic_language-globe.png" "${globe_x}" "${offset_y}"
  showimage "${SCREENS}/ic_dropdown.png" "${arrow_x}" "${offset_y}"
  showmessage "btn_MiniOS_display_options" "${text_x}" "${offset_y}"
}

item_dropdown_onselect() {
  local selected_index=$1

  NAME="$(echo "${NAME_LIST}" | \
                  cut -d\' -f"$((selected_index * 2))")"

  clear_screen
  return 1
}

item_dropdown_onchange() {
  local selected_index=$1
  local func="show_item_dropdown "$(( selected_index - 1 ))" ${NAME_LIST}"
  eval "${func}"
}

get_item_count(){
  echo $#
}

message_item_dropdown_menu() {
  clear_main_area
  instructions title_MiniOS_dropdown
  show_stepper '1-done' '2' '3'
  show_item_menu 1
  show_footer

  # Remove once recovery begins. Writing to the file myself to mock.
  # Needs single quotes & space or new line between each.
  echo "'item 1' 'item2_public' 'testing!! 123' 'test_option' " \
  "'32_char_is_the_longest_item_name' 'SELECT_ITEM' 'item 101'" > /tmp/list.txt
   NAME_LIST=""
  local func="get_item_count "
  while IFS= read -r item; do
       func="${func} ${item}"
       NAME_LIST=${NAME_LIST}" ${item}"
  done < /tmp/list.txt
  unset IFS

  local item_count
  item_count=$(eval "${func}")
  dlog "Items_dropdown_menu: number of items given ${item_count}"
  dlog "Items_dropdown_menu: items given ${NAME_LIST}"

  menu_event_loop "$(( item_count + 1 ))" "${selected_index}" \
  item_dropdown_onchange item_dropdown_onselect
}

show_item_dropdown() {
  local selected_index="$1"
  shift

  local item_height=40
  local item_per_page="$(( (CANVAS_SIZE - 260) / item_height ))"
  local item_count="$#"

  # Put the focused item on middle of the screen if possible.
  local begin_index="$(( selected_index - (item_per_page / 2) ))"
  if [ "${begin_index}" -lt 0 ]; then
    begin_index=0
  elif [ "$(( begin_index + item_per_page ))" -gt "${item_count}" ]; then
    begin_index="$(( item_count - item_per_page ))"
  fi
  shift "${begin_index}"

  local i="${begin_index}"
  local offset_y="$((  (-CANVAS_SIZE / 2) + 350 + item_height ))"
  local background_x="$(( (-CANVAS_SIZE / 2) + 360 ))"
  local lang_x lang_width

  while [ "${i}" -lt "$(( begin_index + item_per_page ))" ] && \
        [ "${i}" -lt "${item_count}" ]; do
    lang_x="$(( (-CANVAS_SIZE / 2) + 60 ))"
    if [ "${selected_index}" -eq "${i}" ]; then
      # Button focused.
      showbox "${background_x}" "${offset_y}" 720 40 "${MENU_UI_BLUE}"
      showtext "$1" "${lang_x}" "${offset_y}" 'black'
    else
      showbox "${background_x}" "${offset_y}" 720 40 "${MENU_UI_DROPDOWN_FRAME}"
      showbox "${background_x}" "${offset_y}" 718 38 "${MENU_UI_DROPDOWN_BG}"
      showtext "$1" "${lang_x}" "${offset_y}" 'grey'
    fi

    i="$(( i + 1 ))"
    offset_y="$(( offset_y + item_height ))"
    shift
  done
}

dropdown_screen_onchange() {
  local selected_index=$1
  local title_y="$(( (-CANVAS_SIZE / 2) + 238 ))"
  echo "${selected_index}"
  message_base_screen
  instructions title_MiniOS_dropdown
  show_stepper '1-done' '2' '3'
  show_language_menu "$(( selected_index == 0 ))"

  local btn_y="$(( title_y +  58 ))" # padding 40
  local btn_y_step="$(( BUTTON_HEIGHT + BUTTON_MARGIN ))"

  show_item_menu "$(( selected_index == 1 ))"

  # Back button.
  btn_y=$(( btn_y + (btn_y_step * 4) ))
  showbutton btn_back "${btn_y}" "$(( selected_index == 2 ))" \
     "${DEBUG_OPTIONS_BTN_WIDTH}"
}

dropdown_screen_onselect() {
  local selected_index=$1
  case "${selected_index}" in
    0)
      message language_menu
      ;;
    1)
      message item_dropdown_menu
      message password
      ;;
    2)
      message minios_welcome
      ;;
  esac
  return 0
}

message_minios_dropdown() {
  message_base_screen
  menu_event_loop 3 1 dropdown_screen_onchange dropdown_screen_onselect
}

password_onselect () {
  local selected_index=$1
  case "${selected_index}" in
    0)
      message language_menu
      ;;
    1)
      message downloading
      ;;
    2)
      message minios_dropdown
      ;;
    3)
      message minios_advanced
      ;;
  esac

  return 0
}

password_onchange() {
  local selected_index=$1
  local title_y="$(( (-CANVAS_SIZE / 2) + 238 ))"

  echo "${selected_index}"

  message_base_screen
  instructions_with_title MiniOS_pick_image
  show_stepper 'done' '2-done' '3'
  show_language_menu "$(( selected_index == 0 ))"


  local btn_y_step="$(( BUTTON_HEIGHT + BUTTON_MARGIN ))"
  local btn_y="$(( title_y + 58 + (btn_y_step * 2) ))" # padding 40

  showbutton btn_enter "${btn_y}" "$(( selected_index == 1 ))" \
    "${DEBUG_OPTIONS_BTN_WIDTH}"

  btn_y=$(( btn_y + (btn_y_step * 1) ))
  showbutton btn_back "${btn_y}" "$(( selected_index == 2 ))" \
    "${DEBUG_OPTIONS_BTN_WIDTH}"

  local adv_y="$(( (CANVAS_SIZE / 2) - 222 ))"
  showadvoption settings btn_debug_options "${adv_y}" \
    "$(( selected_index == 3 ))"
}

get_keyinput() {
  local btn_y="$(( -CANVAS_SIZE / 2 + 400 ))"
  local start="enter recovery password"

  show_button_text "${start}" "${btn_y}" 0 \
  "$((DEBUG_OPTIONS_BTN_WIDTH *3 - 10))"

  key_reader --country_code="${REGION}" --include_usb --print_length |
  while IFS= read -r line; do
    if [  ${#line} -ge 3 ]; then
      echo "${line}"
      return
    elif [ "${line}" -eq 0 ]; then
      local pass=""
    else
      local pass
      pass=$(printf '%.0s*' $(seq 1 "${line}"))
    fi
    show_button_text "${pass}" "${btn_y}" 0 \
    "$((DEBUG_OPTIONS_BTN_WIDTH *3 - 10))"
  done
}

message_password() {
  dlog "message_password: option picked is '${NAME}'"
  message_base_screen
  show_stepper 'done' '2-done' '3'
  instructions_with_title MiniOS_password

  # Get password from key_reader.
  local password
  password="$(get_keyinput)"
  dlog "Message_password: password entered is'${password}'"
  menu_event_loop 4 1 password_onchange password_onselect
}

message_downloading() {
  message_base_screen
  instructions_with_title MiniOS_downloading
  show_stepper 'done' 'done' '3-done'
  # For testing purposes wait on screen.
  make_user_wait 7
  message_complete
}

message_minios_advanced() {
  message_base_screen
  instructions title_MiniOS_advanced_options
  make_user_wait 10
  message downloading
}

message_complete() {
  message_base_screen
  instructions title_MiniOS_complete
  show_stepper 'done' 'done' 'done'

  make_user_wait 7
  # reboot -f
  show_button_text "Reboot" -100 1 \
  "$((DEBUG_OPTIONS_BTN_WIDTH))"

  # Remove later, just for seeing all the screens together.
  message_dropdown_selection_error
}

errorstate_onselect() {
  while true; do
    case "$(wait_menu_input)" in
      enter)
        eval "${BACK_PAGE}"
        ;;
      *)
        dlog "Minios error: ignore unknown key"
        ;;
    esac
  done
}

message_dropdown_selection_error() {
  # Change back_page to drop down screen later,
  # just for seeing all the screens together for testing.
  BACK_PAGE="message_minios_error"
  message_base_screen
  instructions_with_title MiniOS_error
  show_stepper 'done' 'done' 'stepper_error'

  showbutton btn_try_again -100 1 \
    "${DEBUG_OPTIONS_BTN_WIDTH}"
  errorstate_onselect
}

message_minios_error() {
  BACK_PAGE="message_minios_welcome"
  message_base_screen
  show_stepper 'done' 'done' 'stepper_error'
  instructions_with_title MiniOS_general_error

  showbutton btn_try_again -100 1 \
    "${DEBUG_OPTIONS_BTN_WIDTH}"
  errorstate_onselect
}
