//
//  Disclaim.m
//  Tabzilla
//

#import "Disclaim.h"
#import <os/log.h>
#import <spawn.h>

// Private SPI (declared in Apple's spawn_private.h, not the public SDK): sets
// whether a spawned child is *disclaimed* — i.e. becomes its OWN TCC responsible
// process instead of inheriting the spawner's. Forward-declared here because the
// header isn't shipped. Verified 2026-06-12 that a disclaimed re-exec of the
// Tabzilla bundle binary is attributed to `dev.tabzilla.Tabzilla` (consent dialog
// said "Tabzilla"; the grant is shared with the daemon). This is the same trick
// Chrome and similar agents use. It's unsupported SPI — if a future macOS breaks
// it, the fallback is the public-API approach of probing the daemon.
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);

extern char **environ;

// Sentinel env var: present in the re-exec'd child so we don't loop.
static NSString *const kDisclaimSentinel = @"TABZILLA_DISCLAIMED";

static os_log_t DisclaimLogger(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ log = os_log_create("dev.tabzilla.Tabzilla", "disclaim"); });
    return log;
}

void TabzillaDisclaimReexecIfNeeded(void) {
    // Already disclaimed (we are the re-exec'd child) — nothing to do.
    if (getenv(kDisclaimSentinel.UTF8String) != NULL) {
        return;
    }

    NSString *execPath = NSProcessInfo.processInfo.arguments.firstObject;
    if (execPath.length == 0) {
        os_log_error(DisclaimLogger(), "disclaim: no executable path; skipping re-exec");
        return;
    }

    // Rebuild argv: argv[0] + the original arguments, NULL-terminated.
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    int argc = (int)arguments.count;
    char **argv = calloc((size_t)argc + 1, sizeof(char *));
    if (argv == NULL) {
        return;
    }
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup(arguments[i].UTF8String);
    }
    argv[argc] = NULL;

    // Child environment = current environment + the sentinel.
    setenv(kDisclaimSentinel.UTF8String, "1", 1);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    int rc = responsibility_spawnattrs_setdisclaim(&attr, 1);
    if (rc != 0) {
        os_log_error(DisclaimLogger(), "disclaim: setdisclaim failed rc=%d; running un-disclaimed", rc);
        posix_spawnattr_destroy(&attr);
        goto cleanup;
    }

    pid_t pid = 0;
    int sp = posix_spawn(&pid, execPath.fileSystemRepresentation, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);

    if (sp != 0) {
        // Couldn't re-spawn — degrade gracefully and let the original process run.
        os_log_error(DisclaimLogger(), "disclaim: posix_spawn failed rc=%d; running un-disclaimed", sp);
        unsetenv(kDisclaimSentinel.UTF8String);
        goto cleanup;
    }

    // Parent: wait for the disclaimed child and exit with its status. We do NOT
    // return — the child is the real invocation now.
    int status = 0;
    waitpid(pid, &status, 0);
    for (int i = 0; i < argc; i++) {
        free(argv[i]);
    }
    free(argv);
    exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);

cleanup:
    for (int i = 0; i < argc; i++) {
        free(argv[i]);
    }
    free(argv);
}
