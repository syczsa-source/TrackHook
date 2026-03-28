# 架构支持
ARCHS = arm64 arm64e

# 目标配置
TARGET = iphone:clang:latest:12.0

# 指定注入的应用
INSTALL_TARGET_PROCESSES = SpringBoard
INSTALL_TARGET_PROCESSES += com.bluecity.blued

# 包含 Theos 公共配置
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

# 包含 Theos 的 tweak 构建规则
include $(THEOS_MAKE_PATH)/tweak.mk

# 安装后重启 SpringBoard
after-install::
	install.exec "killall -9 SpringBoard"

# 清理规则
clean::
	@rm -rf .theos packages *.deb
