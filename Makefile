ARCHS = arm64 arm64e
TARGET = iphone:clang:15.5:14.0
INSTALL_TARGET_PROCESSES = Blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackTweak

TrackTweak_FILES = TrackTweak.xm
TrackTweak_FRAMEWORKS = UIKit Foundation
TrackTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TrackTweak_LIBRARIES = objc

include $(THEOS_MAKE_PATH)/tweak.mk
