ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Blued

export THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

TWEAK_NAME = TrackHook
TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-missing-braces
TrackHook_LIBRARIES = objc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
