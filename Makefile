ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = com.bluecity.blued

ADDITIONAL_CFLAGS += -Wno-deprecated-declarations

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk