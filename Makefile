# 保持您原有的架构设置
ARCHS = arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = com.bluecity.blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

# 注意：如果按照之前的建议改用了 Logos 语法，请确保这里是 .xm 后缀
TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk