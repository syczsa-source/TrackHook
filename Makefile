# 架构支持 - 根据链接内容，明确指定arm64
ARCHS = arm64

# 目标配置 - 根据文档，明确指定SDK和部署版本
TARGET = iphone:clang:latest:13.0

# 指定注入的应用
INSTALL_TARGET_PROCESSES = com.bluecity.blued

include $(THEOS)/makefiles/common.mk

# 项目名称
TWEAK_NAME = TrackHook
TrackHook_FILES = Tweak.xm

# 框架依赖
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation

# 编译选项
TrackHook_CFLAGS = -fobjc-arc -Wno-error
TrackHook_CCFLAGS = -std=c++11
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
