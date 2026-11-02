// Diagnostics for end users (docs/46): a log file and a crash report in
// ~/Library/Logs/Slab that they can send along with a bug report.
//
// slab.log holds what slab prints to stderr (std.log, panic messages) when
// it was not started from a terminal; the previous run's is kept as
// slab.log.1. A fatal signal writes crash-<start time>.txt there with the
// signal, the fault address and a backtrace, then lets the OS take its
// usual course (its own report lands in DiagnosticReports).

#include <dirent.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#define KEEP_CRASHES 5

static char g_crash_path[1024];
static char g_header[512];
static char g_altstack[64 * 1024];

static void mkdirs(const char *path) {
    char tmp[1024];
    size_t n = strlen(path);
    if (n >= sizeof tmp) return;
    memcpy(tmp, path, n + 1);
    for (size_t i = 1; i < n; i++) {
        if (tmp[i] != '/') continue;
        tmp[i] = 0;
        mkdir(tmp, 0755);
        tmp[i] = '/';
    }
    mkdir(tmp, 0755);
}

static size_t put(char *dst, size_t at, size_t cap, const char *s) {
    size_t n = strlen(s);
    if (at + n >= cap) n = cap - at - 1;
    memcpy(dst + at, s, n);
    return at + n;
}

static size_t put_hex(char *dst, size_t at, size_t cap, uintptr_t v) {
    char b[24];
    int i = 0;
    do {
        b[i++] = "0123456789abcdef"[v & 15];
        v >>= 4;
    } while (v && i < 20);
    at = put(dst, at, cap, "0x");
    while (i > 0 && at + 1 < cap) dst[at++] = b[--i];
    return at;
}

static const char *sig_name(int sig) {
    switch (sig) {
    case SIGSEGV: return "SIGSEGV (bad memory access)";
    case SIGBUS: return "SIGBUS (bad memory access)";
    case SIGILL: return "SIGILL (illegal instruction)";
    case SIGFPE: return "SIGFPE (arithmetic error)";
    case SIGABRT: return "SIGABRT (abort: a panic or failed assertion)";
    case SIGTRAP: return "SIGTRAP (trap)";
    default: return "signal";
    }
}

static void handler(int sig, siginfo_t *si, void *ctx) {
    (void)ctx;
    int fd = open(g_crash_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char line[256];
        size_t at = 0;
        write(fd, g_header, strlen(g_header));
        at = put(line, at, sizeof line, "\nfatal: ");
        at = put(line, at, sizeof line, sig_name(sig));
        at = put(line, at, sizeof line, "\nfault address: ");
        at = put_hex(line, at, sizeof line, (uintptr_t)si->si_addr);
        at = put(line, at, sizeof line, "\nimage slide: ");
        at = put_hex(line, at, sizeof line, (uintptr_t)_dyld_get_image_vmaddr_slide(0));
        at = put(line, at, sizeof line, "\n\nbacktrace (this thread):\n");
        write(fd, line, at);
        void *frames[64];
        int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    // Back to the default action: a synchronous fault re-executes and the
    // OS writes its own report; an abort is raised again.
    signal(sig, SIG_DFL);
    if (sig == SIGABRT) raise(sig);
}

// Keep only the newest KEEP_CRASHES crash reports (names sort by time).
static void prune(const char *dir) {
    char names[64][64];
    int count = 0;
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) && count < 64) {
        if (strncmp(e->d_name, "crash-", 6) != 0 || strlen(e->d_name) >= 64) continue;
        strcpy(names[count++], e->d_name);
    }
    closedir(d);
    for (int i = 1; i < count; i++) // insertion sort, oldest first
        for (int j = i; j > 0 && strcmp(names[j - 1], names[j]) > 0; j--) {
            char t[64];
            strcpy(t, names[j]);
            strcpy(names[j], names[j - 1]);
            strcpy(names[j - 1], t);
        }
    for (int i = 0; i < count - KEEP_CRASHES; i++) {
        char p[1200];
        snprintf(p, sizeof p, "%s/%s", dir, names[i]);
        unlink(p);
    }
}

// Set up logging and crash reports in `dir`. 0 on success.
int slab_diag_start(const char *dir, const char *version) {
    mkdirs(dir);
    char log[1100], old[1100];
    snprintf(log, sizeof log, "%s/slab.log", dir);
    snprintf(old, sizeof old, "%s/slab.log.1", dir);

    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", &tm);
    snprintf(g_crash_path, sizeof g_crash_path, "%s/crash-%s.txt", dir, stamp);

    struct utsname u;
    uname(&u);
    snprintf(g_header, sizeof g_header, "Slab %s\nstarted %s\n%s %s %s (pid %d)\nlog: %s\n",
        version, stamp, u.sysname, u.release, u.machine, (int)getpid(), log);

    prune(dir);

    // Not from a terminal: stderr goes to the log (the previous one is kept).
    if (!isatty(2)) {
        rename(log, old);
        int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
        if (fd >= 0) {
            write(fd, g_header, strlen(g_header));
            write(fd, "\n", 1);
            dup2(fd, 2);
            close(fd);
        }
    }

    stack_t ss = {.ss_sp = g_altstack, .ss_size = sizeof g_altstack, .ss_flags = 0};
    sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    const int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP};
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], &sa, NULL);
    return 0;
}
