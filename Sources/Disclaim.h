//
//  Disclaim.h
//  Tabzilla
//
//  TCC "disclaim" re-exec: run a CLI invocation as its OWN responsible process
//  so Accessibility/Automation prompts and grants are attributed to Tabzilla's
//  bundle identity, not to the launching terminal. See Disclaim.m for details.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// If this process hasn't already been disclaimed, re-spawn an identical copy of
/// itself as its own TCC responsible process (via the `posix_spawn` disclaim SPI)
/// and exit with the child's status. Returns only in the child / when no re-exec
/// is needed; callers can then proceed normally.
///
/// Idempotent via an environment sentinel, so the child does not loop. On any
/// failure it logs and returns without re-execing (degrades to the old
/// terminal-attributed behavior rather than breaking the command).
void TabzillaDisclaimReexecIfNeeded(void);

NS_ASSUME_NONNULL_END
