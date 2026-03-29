ARCHS = arm64 arm64e
TARGET = iphone:clang:14.0:14.0
INSTALL_TARGET_PROCESSES = Blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation

include $(THEOS_MAKE_PATH)/tweak.mk