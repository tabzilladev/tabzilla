//
//  ChromeProcessLocator.m
//  Tabzilla
//

#import "ChromeProcessLocator.h"
#import <AppKit/AppKit.h>
#import <os/log.h>
#import <sys/sysctl.h>

static os_log_t LocatorLogger(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ log = os_log_create("dev.tabzilla.Tabzilla", "locator"); });
    return log;
}

@implementation ChromeInstance
@end

// Read the full argument vector of a process via KERN_PROCARGS2.
//
// The KERN_PROCARGS2 buffer layout is: [int argc][exec_path\0][padding\0...][argv[0]\0]
// [argv[1]\0]...[argv[argc-1]\0][env...]. We parse out the argc argv strings after the
// exec path. Returns nil if the process is gone or its args are unreadable (e.g. owned by
// another user) — callers treat nil as "no targeting info".
static NSArray<NSString *> *ArgumentsForPID(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};

    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) {
        return nil;
    }

    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (sysctl(mib, 3, buffer.mutableBytes, &size, NULL, 0) != 0) {
        return nil;
    }

    const char *bytes = (const char *)buffer.bytes;
    if (size < sizeof(int)) {
        return nil;
    }

    int argc = 0;
    memcpy(&argc, bytes, sizeof(int));

    const char *cursor = bytes + sizeof(int);
    const char *end = bytes + size;

    // Skip the exec path (NUL-terminated).
    while (cursor < end && *cursor != '\0') {
        cursor++;
    }
    // Skip the run of NUL padding between exec path and argv[0].
    while (cursor < end && *cursor == '\0') {
        cursor++;
    }

    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 0; i < argc && cursor < end; i++) {
        const char *argStart = cursor;
        while (cursor < end && *cursor != '\0') {
            cursor++;
        }
        NSString *arg = [[NSString alloc] initWithBytes:argStart
                                                 length:(NSUInteger)(cursor - argStart)
                                               encoding:NSUTF8StringEncoding];
        if (arg) {
            [args addObject:arg];
        }
        cursor++;  // step over the NUL terminator
    }

    return args;
}

// Extract the value of a `--flag=value` or `--flag value` style argument. Returns nil if
// absent.
static NSString *FlagValue(NSArray<NSString *> *args, NSString *flag) {
    NSString *prefix = [flag stringByAppendingString:@"="];
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *arg = args[i];
        if ([arg hasPrefix:prefix]) {
            return [arg substringFromIndex:prefix.length];
        }
        if ([arg isEqualToString:flag] && i + 1 < args.count) {
            return args[i + 1];
        }
    }
    return nil;
}

@implementation ChromeProcessLocator

+ (NSArray<ChromeInstance *> *)instancesForBundleId:(NSString *)bundleId {
    NSMutableArray<ChromeInstance *> *instances = [NSMutableArray array];

    NSArray<NSRunningApplication *> *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleId];

    for (NSRunningApplication *app in running) {
        pid_t pid = app.processIdentifier;
        if (pid <= 0) {
            continue;
        }

        ChromeInstance *instance = [[ChromeInstance alloc] init];
        instance.pid = pid;

        NSArray<NSString *> *args = ArgumentsForPID(pid);
        if (args) {
            instance.userDataDir = FlagValue(args, @"--user-data-dir");
            instance.profileDirectory = FlagValue(args, @"--profile-directory");
        }

        [instances addObject:instance];
    }

    return instances;
}

+ (nullable ChromeInstance *)selectInstanceFrom:(NSArray<ChromeInstance *> *)instances
                           preferredUserDataDir:(nullable NSString *)preferredUserDataDir {
    if (instances.count == 0) {
        return nil;
    }

    // 1. Explicit preference wins.
    if (preferredUserDataDir.length > 0) {
        for (ChromeInstance *instance in instances) {
            if ([instance.userDataDir isEqualToString:preferredUserDataDir]) {
                return instance;
            }
        }
    }

    // 2. Prefer the instance launched without --user-data-dir (normal user-facing Chrome).
    for (ChromeInstance *instance in instances) {
        if (instance.userDataDir == nil) {
            return instance;
        }
    }

    // 3. Unambiguous single instance.
    if (instances.count == 1) {
        return instances.firstObject;
    }

    // 4. Ambiguous — let the caller fall back to bundle-id targeting.
    return nil;
}

+ (pid_t)resolvePIDForBundleId:(NSString *)bundleId preferredUserDataDir:(nullable NSString *)preferredUserDataDir {
    NSArray<ChromeInstance *> *instances = [self instancesForBundleId:bundleId];
    ChromeInstance *chosen = [self selectInstanceFrom:instances preferredUserDataDir:preferredUserDataDir];
    if (chosen) {
        return chosen.pid;
    }

    if (instances.count > 1) {
        os_log_info(
            LocatorLogger(),
            "Ambiguous Chrome instances for %{public}@ (%lu running, none default); "
            "falling back to bundle-id targeting",
            bundleId, (unsigned long)instances.count);
    }
    return 0;
}

@end
