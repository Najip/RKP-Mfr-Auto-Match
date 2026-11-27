LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := rkp_mfr_auto
LOCAL_SRC_FILES := main.cpp
LOCAL_CPPFLAGS := -std=c++17 -O2 -Wall -Wextra -Werror -fvisibility=hidden -fvisibility-inlines-hidden -fno-exceptions -fno-rtti
LOCAL_LDFLAGS := -Wl,--gc-sections -Wl,--exclude-libs,ALL
include $(BUILD_SHARED_LIBRARY)
