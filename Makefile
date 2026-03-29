ARCHS = arm64 arm64e
# 核心修复：latest自动匹配CI中存在的SDK，最低部署版本保持14.0兼容
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Blued

# 忽略并行构建警告，适配CI环境
THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
# 开启ARC，忽略废弃API警告，关闭编译优化避免CI编译异常
TrackHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -O0
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation

include $(THEOS_MAKE_PATH)/tweak.mk