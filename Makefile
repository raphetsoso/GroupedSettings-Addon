THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Preferences Tips MobileAddressBook MobilePhone MobileSafari Files MobileMail Health MobileSlideshow Camera MobileTimer Maps Weather Reminders Fitness FindMy Translate Freeform VoiceMemos Books Support Journal Bridge Home MobileSMS MobileCal MobileNotes AppStore Passbook Calculator Compass Measure Shortcuts Music TV Podcasts FaceTime Stocks Magnifier MobileStore Passwords

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GroupedSettings17Addon

GroupedSettings17Addon_FILES = Tweak.x
GroupedSettings17Addon_FRAMEWORKS = UIKit Foundation
GroupedSettings17Addon_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

# git/zip uploads can drop the exec bit; dpkg requires maintainer scripts to be 0555-0775.
# Fix the source script before Theos copies layout/DEBIAN into the package.
_ := $(shell chmod 755 layout/DEBIAN/preinst 2>/dev/null)
