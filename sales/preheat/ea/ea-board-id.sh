#!/bin/bash
# Copyright 2026, Jamf Software LLC.
# This work is licensed under the terms of the Jamf Source Available License
# https://github.com/jamf/scripts/blob/main/LICENCE.md
# Jamf Pro Extension Attribute: Content Caching - Board ID
# Data type: String.  Runs on every Mac.
# Apple silicon: hw.target gives the board ID Apple's update service keys on (e.g. J413AP).
# Intel: fall back to the board-id from the device tree (e.g. Mac-7BA5B2D9E42DDD94).
#   Intel Macs with a T2 chip: Apple's service keys on the T2's board, not this one; admin/readiness-check.py
#   substitutes it from the model identifier (lookup_board), so this EA stays as it is.
B=$(/usr/sbin/sysctl -n hw.target 2>/dev/null)
if [[ -z "$B" ]]; then
  B=$(/usr/sbin/ioreg -p IODeviceTree -r -n / -d 1 2>/dev/null | /usr/bin/awk -F'"' '/board-id/{print $4}')
fi
echo "<result>${B:-Unknown}</result>"
