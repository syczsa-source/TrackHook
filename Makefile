ARCHS = arm64 arm64e
TARGET = iphone:clang:15.0:14.0
INSTALL_TARGET_PROCESSES = Blued  # 目标App是Blued，无需修改

include $(THEOS)/makefiles/common.mk

# 🔴 必须和项目名、xm文件名、plist名完全一致：TrackHook
TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation WebKit
TrackHook_CFLAGS = -fobjc-arc
TrackHook_USE_FLEX = 0

include $(THEOS_MAKE_PATH)/tweak.mk
