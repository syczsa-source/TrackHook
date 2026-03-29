# 架构支持 (iOS 15+ 仅支持 arm64)
ARCHS = arm64

# 目标配置 (兼容 iOS 15+)
TARGET = iphone:clang:latest:15.0

# 指定注入的应用
INSTALL_TARGET_PROCESSES = com.bluecity.blued

include $(THEOS)/makefiles/common.mk

# 项目名称
TWEAK_NAME = TrackHook
TrackHook_FILES = TrackHook.xm

# 框架依赖
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation

# 编译选项 (iOS 15+ 优化)
TrackHook_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations
TrackHook_LDFLAGS = -undefined dynamic_lookup

# 忽略并行构建提示
THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

include $(THEOS_MAKE_PATH)/tweak.mk

# 安装后重启目标应用 (iOS 15+ 安全方式)
after-install::
	install.exec "killall -9 Blued"

# 打包后清理
after-package::
	@rm -rf $(THEOS_STAGING_DIR)/usr/lib/.debug
