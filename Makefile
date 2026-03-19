ARCHS = arm64
TARGET = iphone:clang:17.0:15.0
INSTALL_TARGET_PROCESSES = com.bluecity.blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
