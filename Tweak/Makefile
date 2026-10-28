THEOS_PACKAGE_SCHEME = rootless
TARGET               := iphone:clang:16.5:15.0
ARCHS                = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AirTagCatTweak

AirTagCatTweak_FILES      = Tweak.x
AirTagCatTweak_CFLAGS     = -fno-objc-arc
AirTagCatTweak_FRAMEWORKS = Foundation CoreLocation

include $(THEOS_MAKE_PATH)/tweak.mk
