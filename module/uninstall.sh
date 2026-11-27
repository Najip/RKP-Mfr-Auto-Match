#!/system/bin/sh
# Runs when the module is removed. Clears every saved setting and state file
# so nothing from an old toggle is left behind. Props set with resetprop -n
# are not persistent, they go back to stock on the reboot after removal.
rm -f /data/adb/rkp_mfr_auto.conf \
      /data/adb/rkp_mfr_auto.mfr \
      /data/adb/rkp_mfr_auto.real_mfr \
      /data/adb/rkp_mfr_auto.exclude \
      /data/adb/rkp_mfr_auto.cam_auto \
      /data/adb/rkp_mfr_auto.cam_auto.tmp \
      /data/adb/rkp_mfr_auto.reboot \
      /data/adb/rkp_mfr_auto.log
