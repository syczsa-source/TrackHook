ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = com.bluecity.blued

# 保留你原有配置，新增编译容错+ARC支持+警告忽略
ADDITIONAL_CFLAGS += -Wno-deprecated-declarations -Wno-error -fobjc-arc
# 消除GNU Make并行构建警告，适配GitHub编译环境
THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook

TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation CoreGraphics
TrackHook_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk