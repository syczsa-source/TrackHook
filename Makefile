ARCHS = arm64 arm64e
TARGET = iphone:clang:15.0:14.0
INSTALL_TARGET_PROCESSES = Blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluedDistance

BluedDistance_FILES = Tweak.xm
BluedDistance_FRAMEWORKS = UIKit Foundation WebKit
BluedDistance_CFLAGS = -fobjc-arc
BluedDistance_USE_FLEX = 0

include $(THEOS_MAKE_PATH)/tweak.mk
