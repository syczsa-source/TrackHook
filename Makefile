# 架构支持
ARCHS = arm64

# 目标配置 - 调整为iOS 13.0，以适配代码中的UIWindowScene
TARGET = iphone:clang:latest:13.0

# 指定注入的应用
INSTALL_TARGET_PROCESSES = com.bluecity.blued

include $(THEOS)/makefiles/common.mk

# 项目名称
TWEAK_NAME = TrackHook
TrackHook_FILES = TrackHook.xm

# 框架依赖
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation

# 编译选项
TrackHook_CFLAGS = -fobjc-arc -Wno-error
TrackHook_LDFLAGS = -undefined dynamic_lookup

# 忽略并行构建提示
THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

include $(THEOS_MAKE_PATH)/tweak.mk

# 安装后重启SpringBoard
after-install::
	install.exec "killall -9 SpringBoard"

# 打包后清理
after-package::
	@rm -rf $(THEOS_STAGING_DIR)/usr/lib/.debug
