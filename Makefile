ARCHS = arm64 arm64e
TARGET = iphone:clang::14.0
INSTALL_TARGET_PROCESSES = Blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation WebKit
# 🔥 修复：补上横杠 -fobjc-arc
TrackHook_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
