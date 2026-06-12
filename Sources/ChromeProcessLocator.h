//
//  ChromeProcessLocator.h
//  Tabzilla
//
//  Resolves which running Chrome *process* (PID) to drive via Scripting Bridge.
//
//  Multiple processes can share one bundle id (e.g. an automation Chrome launched with
//  --user-data-dir alongside the user's normal Chrome). Apple Events delivered via
//  -[SBApplication applicationWithBundleIdentifier:] then resolve to an arbitrary one of
//  them. Targeting by PID (applicationWithProcessIdentifier:) is deterministic, so this
//  locator enumerates the candidate processes and applies a selection policy to choose
//  the intended instance.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A single running Chrome process and the launch arguments relevant to instance/profile
/// targeting. Value object — no behavior.
@interface ChromeInstance : NSObject
@property (nonatomic, assign) pid_t pid;
/// Value of --user-data-dir, or nil if the process was launched without it (the normal
/// user-facing Chrome). nil is the signal for "the default instance".
@property (nonatomic, copy, nullable) NSString *userDataDir;
/// Value of --profile-directory (e.g. "Default", "Profile 1"), or nil if unspecified.
@property (nonatomic, copy, nullable) NSString *profileDirectory;
@end

@interface ChromeProcessLocator : NSObject

/// Discovery (impure): enumerate running processes for `bundleId` and read each one's
/// --user-data-dir / --profile-directory launch arguments.
/// @return One ChromeInstance per running process; empty if none are running.
+ (NSArray<ChromeInstance *> *)instancesForBundleId:(NSString *)bundleId;

/// Selection policy (pure): choose the intended instance from `instances`.
///
/// Policy, in priority order:
///   1. If `preferredUserDataDir` is non-nil, the instance whose userDataDir matches it.
///   2. The instance launched without --user-data-dir (the normal user-facing Chrome).
///   3. If exactly one instance exists, that one.
///   4. Otherwise nil (ambiguous — caller should fall back to bundle-id targeting).
///
/// Exposed separately from discovery so it can be unit-tested with hand-built inputs.
/// @return The chosen instance, or nil if the policy cannot disambiguate.
+ (nullable ChromeInstance *)selectInstanceFrom:(NSArray<ChromeInstance *> *)instances
                           preferredUserDataDir:(nullable NSString *)preferredUserDataDir;

/// Convenience: discover + select, returning the chosen PID.
/// @return The chosen PID, or 0 if no instance could be resolved.
+ (pid_t)resolvePIDForBundleId:(NSString *)bundleId preferredUserDataDir:(nullable NSString *)preferredUserDataDir;

@end

NS_ASSUME_NONNULL_END
