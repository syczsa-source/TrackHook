ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = com.bluecity.blued

# 编译容错+警告消除
ADDITIONAL_CFLAGS += -Wno-deprecated-declarations -Wno-error -fobjc-arc
THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation CoreGraphics
TrackHook_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk