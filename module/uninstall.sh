#!/system/bin/sh
# Called by Magisk / KernelSU / APatch when the module is removed.
#
# resetprop changes are not persistent, so the props return to their stock
# values after the next reboot. Remove the runtime state this module created.
rm -f /data/adb/rkp_mfr_auto.conf \
      /data/adb/rkp_mfr_auto.mfr \
      /data/adb/rkp_mfr_auto.real_mfr \
      /data/adb/rkp_mfr_auto.exclude \
      /data/adb/rkp_mfr_auto.cam_auto \
      /data/adb/rkp_mfr_auto.cam_auto.tmp \
      /data/adb/rkp_mfr_auto.reboot \
      /data/adb/rkp_mfr_auto.log
rm -f /data/adb/rkp_mfr_auto.seen.*
rm -rf /data/adb/rkp_mfr_auto_export
exit 0
