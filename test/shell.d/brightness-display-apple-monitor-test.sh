#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# With two Apple displays attached, each one's hiddev node is matched to its
# monitor through the USB Container ID its internal hub reports, which the display
# repeats in its EDID. Selecting a real node needs `sudo asdcontrol --detect` and
# hardware, so load the wrapper's functions and drive the matching against a fake
# sysfs tree shaped like a Studio Display: the hiddev interface hangs off a device
# without a Container ID, under a hub that has one.
eval "$(sed -n '/^[a-z_]*() {$/,/^}$/p' "$ROOT/bin/omarchy-brightness-display-apple")"

sys="$TMPDIR/sys"
usbmisc_path="$sys/class/usbmisc"
drm_path="$sys/class/drm"
mkdir -p "$usbmisc_path" "$drm_path"

left_id="3e88b84e834a491aa6ce932ac656eff9"
right_id="dea995a24726424e9dbde61148c21579"

write_hex() {
  printf '%b' "$(sed 's/../\\x&/g' <<<"$1")" >"$2"
}

# BOS header, then a USB 2.0 extension capability, then the 20-byte Container ID
# capability (descriptor type 0x10, capability type 0x04).
hub_bos() {
  printf '050f2000020710020600000014100400%s' "$1"
}

# The display's own BOS has a platform capability but no Container ID.
display_bos="050f1c0002071002020000001410050000000000000000000000000000000000"

add_display() {
  local hiddev="$1"
  local hub="$2"
  local container_id="$3"
  local hub_path="$sys/devices/pci0000:00/usb1/$hub"

  mkdir -p "$hub_path/$hub.4/$hub.4:1.2" "$usbmisc_path/$hiddev"
  write_hex "$(hub_bos "$container_id")" "$hub_path/bos_descriptors"
  write_hex "$display_bos" "$hub_path/$hub.4/bos_descriptors"
  ln -s "$hub_path/$hub.4/$hub.4:1.2" "$usbmisc_path/$hiddev/device"
}

add_monitor() {
  local connector="$1"
  local container_id="$2"

  mkdir -p "$drm_path/card1-$connector"
  # A base EDID block followed by a DisplayID extension holding the Container ID.
  write_hex "00ffffffffffff000610$(printf '%0108d' 0)02700029001000$container_id" "$drm_path/card1-$connector/edid"
}

add_display hiddev2 1-1 "$right_id"
add_display hiddev7 3-1 "$left_id"
add_monitor DP-6 "$right_id"
add_monitor DP-8 "$left_id"
mkdir -p "$drm_path/card1-DP-1"
: >"$drm_path/card1-DP-1/edid"

[[ $(usb_container_id /dev/usb/hiddev7) == "$left_id" ]] ||
  fail "reads the Container ID from the display's hub" "got: $(usb_container_id /dev/usb/hiddev7 || true)"
pass "reads the Container ID from the display's hub"

monitor="DP-8"
monitor_edid="$(monitor_edid_hex)"
device_matches_monitor /dev/usb/hiddev7 || fail "matches the left display's hiddev node to DP-8"
! device_matches_monitor /dev/usb/hiddev2 || fail "does not match the right display's hiddev node to DP-8"
pass "matches each hiddev node only to its own monitor"

monitor="DP-6"
monitor_edid="$(monitor_edid_hex)"
device_matches_monitor /dev/usb/hiddev2 || fail "matches the right display's hiddev node to DP-6"
! device_matches_monitor /dev/usb/hiddev7 || fail "does not match the left display's hiddev node to DP-6"
pass "matches the second display to its monitor"

monitor="DP-1"
! monitor_edid_hex >/dev/null || fail "a connector with an empty EDID yields no EDID"
pass "a connector with an empty EDID yields no EDID"

[[ -z $(usb_container_id /dev/usb/hiddev9 || true) ]] || fail "a hiddev node with no sysfs entry has no Container ID"
pass "a hiddev node with no sysfs entry has no Container ID"

# The monitor name ends up in a cache filename and a sysfs glob.
status=0
PATH="$ROOT/bin:$PATH" omarchy-brightness-display-apple --monitor "../evil" >/dev/null 2>&1 || status=$?
(( status == 1 )) || fail "rejects a monitor name that is not a connector name" "exit status: $status"
pass "rejects a monitor name that is not a connector name"
