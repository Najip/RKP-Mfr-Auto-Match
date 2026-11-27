#!/usr/bin/env bash
# Print a monotonic, 32-bit-safe versionCode for Magisk / KernelSU / APatch.
#
# Older builds used the raw epoch second as versionCode, which overflows the
# 32-bit signed integer the managers compare in January 2038. This keeps the
# "time based and always increasing" property at one-minute resolution:
#
#   1770000000 + floor(epoch_seconds / 60)
#
# 1.77e9 is above every epoch-based versionCode published so far, so existing
# installs still see an update, and INT32_MAX is not reached for ~700 years.
# Two builds produced inside the same minute share a code; that only affects
# update prompts between pre-releases built back to back.
set -euo pipefail

epoch="${SOURCE_DATE_EPOCH:-$(date -u +%s)}"
echo $((1770000000 + epoch / 60))
