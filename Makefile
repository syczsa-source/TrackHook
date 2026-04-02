# 🔥 修复：删除固定SDK版本，自动使用GitHub环境可用SDK
ARCHS = arm64 arm64e
# 关键修改：TARGET = iphone:clang:最低支持系统
# 原错误写法：iphone:clang:15.0:14.0
TARGET = iphone:clang::14.0
INSTALL_TARGET_PROCESSES = Blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation WebKit
TrackHook_CFLAGS = fobjc-arc
TrackHook_USE_FLEX = 0

include $(THEOS_MAKE_PATH)/tweak.mk
