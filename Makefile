TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = com.kuaishou.ksa

ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KSDoubleTap

KSDoubleTap_FILES = Tweak.xm
KSDoubleTap_CFLAGS = -fobjc-arc -I.
KSDoubleTap_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
