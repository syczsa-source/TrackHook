ARCHS = arm64 arm64e
TARGET = iphone:clang:14.0
INSTALL_TARGET_PROCESSES = Blued

# 固定插件名
TWEAK_NAME = TrackHook
TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TrackHook_LIBRARIES = objc

# Theos 标准引入放末尾
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
