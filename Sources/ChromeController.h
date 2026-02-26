//
//  ChromeController.h
//  Tabzilla
//
//  Chrome browser control via Scripting Bridge
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of a tab search operation
@interface ChromeTabInfo : NSObject
@property (nonatomic, copy) NSString *windowId;
@property (nonatomic, copy) NSString *tabId;
@property (nonatomic, assign) NSInteger tabIndex;     // Used for activeTabIndex
@property (nonatomic, copy) NSString *windowName;
@property (nonatomic, copy) NSString *tabURL;
@end

/// Controller for Chrome browser automation via Scripting Bridge
@interface ChromeController : NSObject

/// Shared instance
+ (instancetype)shared;

/// Open a URL in a named window (creates window if needed)
/// @param urlString The URL to open
/// @param windowName The givenName to match/create
/// @param bundleId The browser bundle ID (e.g., com.google.Chrome)
/// @param error Error output
/// @return YES on success
- (BOOL)openURL:(NSString *)urlString
       inWindow:(NSString *)windowName
       bundleId:(NSString *)bundleId
          error:(NSError **)error NS_SWIFT_NOTHROW;

/// Open a URL in a specific window identified by ID
/// @param urlString The URL to open
/// @param windowId The window ID (from ChromeTabInfo)
/// @param bundleId The browser bundle ID (e.g., com.google.Chrome)
/// @param error Error output
/// @return YES on success
- (BOOL)openURL:(NSString *)urlString
  inWindowWithId:(NSString *)windowId
       bundleId:(NSString *)bundleId
          error:(NSError **)error NS_SWIFT_NOTHROW;

/// Fetch all tabs for a browser (for caching during multi-action routing)
/// @param bundleId The browser bundle ID
/// @return Array of ChromeTabInfo objects, or nil if browser unavailable
- (nullable NSArray<ChromeTabInfo *> *)getAllTabsForBundleId:(NSString *)bundleId;

/// Find a tab matching a regex pattern using a pre-fetched tab cache
/// @param pattern Regex pattern to match against tab URLs
/// @param preferredWindow Preferred window name (optional)
/// @param bundleId The browser bundle ID (used only if cachedTabs is nil)
/// @param cachedTabs Pre-fetched tabs from getAllTabsForBundleId: (optional - if nil, fetches fresh)
/// @return Tab info if found, nil otherwise
- (nullable ChromeTabInfo *)findTabMatchingPattern:(NSString *)pattern
                                   preferredWindow:(nullable NSString *)preferredWindow
                                          bundleId:(NSString *)bundleId
                                      fromTabCache:(nullable NSArray<ChromeTabInfo *> *)cachedTabs;

/// Focus a specific tab
/// @param windowId Window ID from ChromeTabInfo
/// @param tabIndex Tab index (1-based, for activeTabIndex)
/// @param bundleId The browser bundle ID
- (void)focusTabWithWindowId:(NSString *)windowId
                    tabIndex:(NSInteger)tabIndex
                    bundleId:(NSString *)bundleId;

/// Navigate a specific tab to a new URL
/// @param windowId Window ID from ChromeTabInfo
/// @param tabId Tab ID from ChromeTabInfo
/// @param urlString The URL to navigate to
/// @param bundleId The browser bundle ID
- (void)navigateTabWithWindowId:(NSString *)windowId
                          tabId:(NSString *)tabId
                          toURL:(NSString *)urlString
                       bundleId:(NSString *)bundleId;

/// Get all windows and tabs for a browser (for status/debugging)
/// @param bundleId The browser bundle ID
/// @return Array of dictionaries with window/tab info, or nil if browser unavailable
- (nullable NSArray<NSDictionary *> *)getAllWindowsForBundleId:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END
