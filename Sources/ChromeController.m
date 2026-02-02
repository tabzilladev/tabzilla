//
//  ChromeController.m
//  Tabzilla
//
//  Chrome browser control via Scripting Bridge
//

#import "ChromeController.h"
#import "Chrome.h"
#import <ScriptingBridge/ScriptingBridge.h>
#import "Tabzilla-Swift.h"

NSErrorDomain const TabzillaErrorDomain = @"dev.tabzilla.Tabzilla";

@implementation ChromeTabInfo
@end

@implementation ChromeController

+ (instancetype)shared {
    static ChromeController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ChromeController alloc] init];
    });
    return instance;
}

- (BOOL)isChromeInstalled {
    return [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.google.Chrome"] != nil;
}

- (nullable ChromeApplication *)chromeAppForBundleId:(NSString *)bundleId {
    return (ChromeApplication *)[SBApplication applicationWithBundleIdentifier:bundleId];
}

- (BOOL)openURL:(NSString *)urlString
       inWindow:(NSString *)windowName
       bundleId:(NSString *)bundleId
          error:(NSError **)error {

    ChromeApplication *chrome = [self chromeAppForBundleId:bundleId];
    if (!chrome) {
        if (error) {
            *error = [NSError errorWithDomain:TabzillaErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Chrome not available"}];
        }
        return NO;
    }

    // Find existing window with matching givenName (case-insensitive exact match)
    // Store the window ID since Scripting Bridge proxies can be unstable
    NSString *targetWindowId = nil;

    for (ChromeWindow *window in chrome.windows) {
        NSString *givenName = window.givenName;
        BOOL hasGivenName = (givenName != nil && givenName.length > 0);
        if (hasGivenName && [givenName caseInsensitiveCompare:windowName] == NSOrderedSame) {
            targetWindowId = [window id];
            break;
        }
    }

    if (targetWindowId) {
        // Get window directly by ID using SBObject's objectWithID:
        // This gives us a stable reference (iterating windows array gives unstable proxies)
        ChromeWindow *targetWindow = (ChromeWindow *)[[chrome windows] objectWithID:targetWindowId];

        // Bring window to front and activate Chrome
        [targetWindow setIndex:1];
        [chrome activate];

        // Create new tab in target window
        ChromeTab *newTab = [[[chrome classForScriptingClass:@"tab"] alloc] init];
        [[targetWindow tabs] addObject:newTab];
        [newTab setURL:urlString];
    } else {
        // No matching window - create new one
        ChromeWindow *newWindow = [[[chrome classForScriptingClass:@"window"] alloc] init];
        [chrome.windows addObject:newWindow];
        newWindow.givenName = windowName;

        // Set URL on the default tab
        ChromeTab *activeTab = newWindow.activeTab;
        activeTab.URL = urlString;

        [chrome activate];
    }

    return YES;
}

- (BOOL)openURL:(NSString *)urlString
  inWindowWithId:(NSString *)windowId
       bundleId:(NSString *)bundleId
          error:(NSError **)error {

    ChromeApplication *chrome = [self chromeAppForBundleId:bundleId];
    if (!chrome) {
        if (error) {
            *error = [NSError errorWithDomain:TabzillaErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Chrome not available"}];
        }
        return NO;
    }

    // Get window by ID for stable reference
    ChromeWindow *targetWindow = (ChromeWindow *)[[chrome windows] objectWithID:windowId];
    if (!targetWindow) {
        if (error) {
            *error = [NSError errorWithDomain:TabzillaErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Window not found"}];
        }
        return NO;
    }

    // Bring window to front and activate Chrome
    [targetWindow setIndex:1];
    [chrome activate];

    // Create new tab in target window
    ChromeTab *newTab = [[[chrome classForScriptingClass:@"tab"] alloc] init];
    [[targetWindow tabs] addObject:newTab];
    [newTab setURL:urlString];

    return YES;
}

- (nullable ChromeTabInfo *)findTabMatchingPattern:(NSString *)pattern
                                   preferredWindow:(nullable NSString *)preferredWindow
                                          bundleId:(NSString *)bundleId {

    ChromeApplication *chrome = [self chromeAppForBundleId:bundleId];
    if (!chrome) return nil;

    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:0
                                                                             error:&regexError];
    if (regexError) {
        [[Logger shared] log:[NSString stringWithFormat:@"ChromeController: Invalid regex pattern: %@", pattern]];
        return nil;
    }

    NSMutableArray<ChromeTabInfo *> *matches = [NSMutableArray array];

    for (ChromeWindow *window in chrome.windows) {
        NSString *windowId = [window id];
        NSString *windowName = window.givenName ?: @"";

        NSInteger tabIndex = 1;
        for (ChromeTab *tab in window.tabs) {
            NSString *tabId = [tab id];
            NSString *tabURL = tab.URL ?: @"";
            NSRange range = NSMakeRange(0, tabURL.length);

            if ([regex firstMatchInString:tabURL options:0 range:range]) {
                ChromeTabInfo *info = [[ChromeTabInfo alloc] init];
                info.windowId = windowId;
                info.tabId = tabId;
                info.windowIndex = 0;  // Not used anymore
                info.tabIndex = tabIndex;  // Still useful for activeTabIndex
                info.windowName = windowName;
                info.tabURL = tabURL;
                [matches addObject:info];
            }
            tabIndex++;
        }
    }

    if (matches.count == 0) return nil;

    // Apply tie-breakers
    // 1. Prefer tabs in windows matching preferredWindow (case-insensitive exact match)
    if (preferredWindow) {
        for (ChromeTabInfo *info in matches) {
            if ([info.windowName caseInsensitiveCompare:preferredWindow] == NSOrderedSame) {
                return info;
            }
        }
    }

    // 2. Return first match
    return matches.firstObject;
}

- (void)focusTabWithWindowId:(NSString *)windowId
                    tabIndex:(NSInteger)tabIndex
                    bundleId:(NSString *)bundleId {

    ChromeApplication *chrome = [self chromeAppForBundleId:bundleId];
    if (!chrome) return;

    // Get window by ID for stable reference
    ChromeWindow *window = (ChromeWindow *)[[chrome windows] objectWithID:windowId];
    if (!window) return;

    // Set active tab and bring window to front
    [window setActiveTabIndex:tabIndex];
    [window setIndex:1];
    [chrome activate];
}

- (void)navigateTabWithWindowId:(NSString *)windowId
                          tabId:(NSString *)tabId
                          toURL:(NSString *)urlString
                       bundleId:(NSString *)bundleId {

    ChromeApplication *chrome = [self chromeAppForBundleId:bundleId];
    if (!chrome) return;

    // Get window by ID for stable reference
    ChromeWindow *window = (ChromeWindow *)[[chrome windows] objectWithID:windowId];
    if (!window) return;

    // Get tab by ID for stable reference
    ChromeTab *tab = (ChromeTab *)[[window tabs] objectWithID:tabId];
    if (!tab) return;

    [tab setURL:urlString];
}

- (nullable NSArray<NSDictionary *> *)getAllWindowsForBundleId:(NSString *)bundleId {
    ChromeApplication *chrome = [self chromeAppForBundleId:bundleId];
    if (!chrome) return nil;

    // Check if browser is running
    if (![chrome isRunning]) return @[];

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];

    for (ChromeWindow *window in chrome.windows) {
        NSString *windowId = [window id];
        NSString *givenName = window.givenName ?: @"";
        NSInteger activeTabIdx = window.activeTabIndex;

        NSMutableArray<NSDictionary *> *tabs = [NSMutableArray array];
        NSInteger tabIndex = 1;
        for (ChromeTab *tab in window.tabs) {
            NSString *tabId = [tab id];
            NSString *tabURL = tab.URL ?: @"";
            NSString *tabTitle = tab.title ?: @"";
            BOOL isActive = (tabIndex == activeTabIdx);

            [tabs addObject:@{
                @"id": tabId ?: @"",
                @"index": @(tabIndex),
                @"url": tabURL,
                @"title": tabTitle,
                @"active": @(isActive)
            }];
            tabIndex++;
        }

        [result addObject:@{
            @"id": windowId ?: @"",
            @"givenName": givenName,
            @"tabCount": @(tabs.count),
            @"tabs": tabs
        }];
    }

    return result;
}

@end
