# 1. 架构支持：建议包含 arm64e，以支持 A12 及更新芯片的设备（如 iPhone XS 及以上）
ARCHS = arm64 arm64e

# 2. 目标配置：建议移除特定的 clang 版本号，以使用 Theos 环境默认的、已验证可用的编译器，避免环境问题。
# 将 iOS 版本下限设为 13.0，与代码中 @available(iOS 13.0, *) 的检查保持一致。
TARGET = iphone:latest:13.0

# 3. 指定注入的进程：此项完全正确。
INSTALL_TARGET_PROCESSES = com.bluecity.blued

include $(THEOS)/makefiles/common.mk

# 4. 项目名称
TWEAK_NAME = TrackHook
TrackHook_FILES = TrackHook.xm # 确保您的源代码文件名为 TrackHook.xm

# 5. 依赖框架：您的列表正确，CoreLocation 是必须的。
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation

# 6. 依赖库：对于使用 CydiaSubstrate 的现代 Theos 项目，通常不需要显式链接 `substrate`。
# 可以安全地移除此行。如果移除后编译报错，再添加回来。
# TrackHook_LIBRARIES = substrate

# 7. 编译选项：
#    - `-fobjc-arc` 是必须的，因为您的代码使用了 ARC 风格的内存管理。
#    - 警告抑制选项：可以保留以确保编译通过，但更干净的做法是尽可能修复代码警告，而非全局压制。
#      此处为您保留最关键的几个，移除了一些可能不必要的。
ADDITIONAL_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unsupported-availability-guard

# 8. 此项用于忽略并行构建的提示，在 CI/CD 环境中很有用，建议保留。
THEOS_IGNORE_PARALLEL_BUILDING_NOTICE = yes

include $(THEOS_MAKE_PATH)/tweak.mk

# 9. 安装后的清理脚本（可选但推荐）：在打包后删除无关的 .dsym 调试符号文件，减小 DEB 包体积。
after-package::
	@rm -rf $(THEOS_STAGING_DIR)/usr/lib/.debug
