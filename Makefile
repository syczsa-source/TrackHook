ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Blued

export THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

# 第一步：加载 Theos 公共基础规则
include $(THEOS)/makefiles/common.mk

# 第二步：定义项目专属配置
TWEAK_NAME = TrackHook
TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-missing-braces
TrackHook_LIBRARIES = objc

# 第三步：加载 Tweak 打包规则
include $(THEOS_MAKE_PATH)/tweak.mk
