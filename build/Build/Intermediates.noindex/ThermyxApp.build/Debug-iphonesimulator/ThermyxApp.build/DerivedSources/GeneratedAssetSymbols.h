#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"com.thermyx.app";

/// The "LaunchBackground" asset catalog color resource.
static NSString * const ACColorNameLaunchBackground AC_SWIFT_PRIVATE = @"LaunchBackground";

/// The "ThermyxBadge" asset catalog image resource.
static NSString * const ACImageNameThermyxBadge AC_SWIFT_PRIVATE = @"ThermyxBadge";

/// The "ThermyxLogo" asset catalog image resource.
static NSString * const ACImageNameThermyxLogo AC_SWIFT_PRIVATE = @"ThermyxLogo";

/// The "ThermyxWordmark" asset catalog image resource.
static NSString * const ACImageNameThermyxWordmark AC_SWIFT_PRIVATE = @"ThermyxWordmark";

#undef AC_SWIFT_PRIVATE
