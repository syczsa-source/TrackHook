ARCHS = arm64 arm64e
# ✅ 正确写法：iphone:clang:SDK版本:部署版本
# ✅ 用 `latest` 让 Theos 自动匹配系统里存在的最新SDK，不用硬编码
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Blued

# 屏蔽并行编译的提示，不用改CI脚本
export THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

TWEAK_NAME = TrackHook
TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TrackHook_LIBRARIES = objc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
