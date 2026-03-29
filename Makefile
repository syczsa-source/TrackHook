ARCHS = armv7 arm64
TARGET = iphone:clang:latest:8.0
INSTALL_TARGET_PROCESSES = com.bluecity.blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrackHook
TrackHook_FILES = TrackHook.xm
TrackHook_FRAMEWORKS = UIKit Foundation CoreLocation
TrackHook_CFLAGS = -fobjc-arc -Wno-error -DTHEOS_LEAN_AND_MEAN
TrackHook_LDFLAGS = -Wl,-segalign,4000 -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"  # 安全重启

after-package::
	@rm -rf $(THEOS_STAGING_DIR)/usr/lib/.debug
