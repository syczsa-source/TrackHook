
ARCHS = arm64
# 核心修复：SDK版本改为16.5，与sdks仓库中实际存在的版本完全匹配，最低支持iOS 15.0
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = com.bluecity.blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
