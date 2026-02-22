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
        @try {
            ChromeTab *newTab = [[[chrome classForScriptingClass:@"tab"] alloc] init];
            [[targetWindow tabs] addObject:newTab];
            [newTab setURL:urlString];
        } @catch (NSException *exception) {
            if (error) {
                *error = [NSError errorWithDomain:TabzillaErrorDomain
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Scripting Bridge error"}];
            }
            return NO;
        }
    } else {
        // No matching window - create new one
        @try {
            ChromeWindow *newWindow = [[[chrome classForScriptingClass:@"window"] alloc] init];
            [chrome.windows addObject:newWindow];
            newWindow.givenName = windowName;

            // Set URL on the default tab
            ChromeTab *activeTab = newWindow.activeTab;
            activeTab.URL = urlString;
        } @catch (NSException *exception) {
            if (error) {
                *error = [NSError errorWithDomain:TabzillaErrorDomain
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Scripting Bridge error"}];
            }
            return NO;
        }

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
    @try {
        ChromeTab *newTab = [[[chrome classForScriptingClass:@"tab"] alloc] init];
        [[targetWindow tabs] addObject:newTab];
        [newTab setURL:urlString];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:TabzillaErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Scripting Bridge error"}];
        }
        return NO;
    }

    return YES;
}

- (nullable NSArray<ChromeTabInfo *> *)getAllTabsForBundleId:(NSString *)bundleId {
    ChromeApplication *chrome = [self chromeAppForBundleId:bundleId];
    if (!chrome) return nil;

    // Check if browser is running
    if (![chrome isRunning]) return @[];

    NSMutableArray<ChromeTabInfo *> *allTabs = [NSMutableArray array];

    // Batch fetch window properties (1 IPC call per property across all windows)
    SBElementArray<ChromeWindow *> *windows = chrome.windows;
    NSArray *windowIds = [windows valueForKey:@"id"];
    NSArray *windowNames = [windows valueForKey:@"givenName"];

    // For each window, batch fetch tab properties (2 IPC calls per window)
    NSInteger windowIndex = 0;
    for (ChromeWindow *window in windows) {
        NSString *windowId = windowIds[windowIndex];
        NSString *windowName = windowNames[windowIndex];
        if ([windowName isEqual:[NSNull null]]) windowName = @"";

        SBElementArray<ChromeTab *> *tabs = window.tabs;
        NSArray *tabIds = [tabs valueForKey:@"id"];
        NSArray *tabURLs = [tabs valueForKey:@"URL"];

        for (NSInteger tabIndex = 0; tabIndex < tabIds.count; tabIndex++) {
            ChromeTabInfo *info = [[ChromeTabInfo alloc] init];
            info.windowId = windowId;
            info.tabId = tabIds[tabIndex];
            info.tabIndex = tabIndex + 1;  // 1-based for activeTabIndex
            info.windowName = windowName;
            NSString *url = tabURLs[tabIndex];
            info.tabURL = [url isEqual:[NSNull null]] ? @"" : url;
            [allTabs addObject:info];
        }
        windowIndex++;
    }

    return allTabs;
}

- (nullable ChromeTabInfo *)findTabMatchingPattern:(NSString *)pattern
                                   preferredWindow:(nullable NSString *)preferredWindow
                                          bundleId:(NSString *)bundleId {
    // Delegate to cache-aware method with no cache (will fetch fresh)
    return [self findTabMatchingPattern:pattern
                        preferredWindow:preferredWindow
                               bundleId:bundleId
                           fromTabCache:nil];
}

- (nullable ChromeTabInfo *)findTabMatchingPattern:(NSString *)pattern
                                   preferredWindow:(nullable NSString *)preferredWindow
                                          bundleId:(NSString *)bundleId
                                      fromTabCache:(nullable NSArray<ChromeTabInfo *> *)cachedTabs {

    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:0
                                                                             error:&regexError];
    if (regexError) {
        [[Logger shared] log:[NSString stringWithFormat:@"ChromeController: Invalid regex pattern: %@", pattern]];
        return nil;
    }

    // Use cached tabs if provided, otherwise fetch fresh
    NSArray<ChromeTabInfo *> *tabs = cachedTabs ?: [self getAllTabsForBundleId:bundleId];
    if (!tabs) return nil;

    // Early termination optimization: if preferredWindow is specified,
    // search that window first and return immediately on match
    if (preferredWindow && preferredWindow.length > 0) {
        for (ChromeTabInfo *info in tabs) {
            if ([info.windowName caseInsensitiveCompare:preferredWindow] == NSOrderedSame) {
                NSRange range = NSMakeRange(0, info.tabURL.length);
                if ([regex firstMatchInString:info.tabURL options:0 range:range]) {
                    return info;
                }
            }
        }
    }

    // Search all tabs for first match
    for (ChromeTabInfo *info in tabs) {
        NSRange range = NSMakeRange(0, info.tabURL.length);
        if ([regex firstMatchInString:info.tabURL options:0 range:range]) {
            return info;
        }
    }

    return nil;
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

    // Batch fetch window properties (1 IPC call per property across all windows)
    SBElementArray<ChromeWindow *> *windows = chrome.windows;
    NSArray *windowIds = [windows valueForKey:@"id"];
    NSArray *givenNames = [windows valueForKey:@"givenName"];
    NSArray *activeTabIndices = [windows valueForKey:@"activeTabIndex"];

    NSInteger windowIndex = 0;
    for (ChromeWindow *window in windows) {
        NSString *windowId = windowIds[windowIndex];
        NSString *givenName = givenNames[windowIndex];
        if ([givenName isEqual:[NSNull null]]) givenName = @"";
        NSInteger activeTabIdx = [activeTabIndices[windowIndex] integerValue];

        // Batch fetch all tab properties for this window
        SBElementArray<ChromeTab *> *tabsArray = window.tabs;
        NSArray *tabIds = [tabsArray valueForKey:@"id"];
        NSArray *tabURLs = [tabsArray valueForKey:@"URL"];
        NSArray *tabTitles = [tabsArray valueForKey:@"title"];

        NSMutableArray<NSDictionary *> *tabs = [NSMutableArray array];
        for (NSInteger tabIndex = 0; tabIndex < tabIds.count; tabIndex++) {
            NSString *tabId = tabIds[tabIndex];
            NSString *tabURL = tabURLs[tabIndex];
            NSString *tabTitle = tabTitles[tabIndex];
            if ([tabURL isEqual:[NSNull null]]) tabURL = @"";
            if ([tabTitle isEqual:[NSNull null]]) tabTitle = @"";
            BOOL isActive = (tabIndex + 1 == activeTabIdx);

            [tabs addObject:@{
                @"id": tabId ?: @"",
                @"index": @(tabIndex + 1),
                @"url": tabURL,
                @"title": tabTitle,
                @"active": @(isActive)
            }];
        }

        [result addObject:@{
            @"id": windowId ?: @"",
            @"givenName": givenName,
            @"tabCount": @(tabs.count),
            @"tabs": tabs
        }];
        windowIndex++;
    }

    return result;
}

@end
