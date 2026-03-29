ARCHS = arm64 arm64e
# 核心修复：latest自动匹配CI中存在的最新SDK，最低部署版本保持14.0，完全兼容
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Blued

# 忽略并行构建警告（可选，也可以在CI中安装新版make解决）
THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
# 开启ARC，忽略废弃API警告
TrackHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation

include $(THEOS_MAKE_PATH)/tweak.mk