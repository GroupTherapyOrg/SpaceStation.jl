// hangfs: make a directory tree behave like a hung network filesystem, without root.
//
//   LD_PRELOAD=hangfs.so HANGFS_PREFIXES=/depot:/home/me HANGFS_FLAG=/run/x/hang HANGFS_LOG=/run/x/calls.log  prog
//
// Every path-taking libc call whose (absolute) path lies under one of the prefixes
//   - is appended to HANGFS_LOG as "<op>\t<path>\t<tid>" (when set): an audit of what a process still
//     asks of those trees, and
//   - BLOCKS for as long as the file HANGFS_FLAG exists: the calling thread sits inside a foreign call,
//     exactly where a thread sits when NFS/BeeGFS/Lustre stops answering (it cannot be interrupted by
//     the runtime, and a stop-the-world collector has to wait for it).
// It does not emulate page faults on mapped files (PinCode.jl is tested separately) and it cannot see
// calls made with raw syscalls or by statically linked programs. Linux, glibc or musl.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>

static const char *prefixes, *flag, *logpath;
static int logfd = -1, ready = 0;

static void init(void) {
    if (ready) return;
    prefixes = getenv("HANGFS_PREFIXES"); flag = getenv("HANGFS_FLAG"); logpath = getenv("HANGFS_LOG");
    if (logpath) logfd = (int)syscall(SYS_openat, AT_FDCWD, logpath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    ready = 1;
}

static int under(const char *path) {
    if (!path || path[0] != '/' || !prefixes) return 0;
    const char *p = prefixes;
    while (*p) {
        const char *e = strchr(p, ':'); size_t n = e ? (size_t)(e - p) : strlen(p);
        while (n > 1 && p[n - 1] == '/') n--;
        if (n && strncmp(path, p, n) == 0 && (path[n] == '/' || path[n] == 0)) return 1;
        if (!e) break; p = e + 1;
    }
    return 0;
}

static void gate(const char *op, const char *path) {
    init();
    char abs[4300];
    if (path && path[0] != '/' && prefixes) { // relative: judge it by the working directory
        char cwd[4096];
        if (syscall(SYS_getcwd, cwd, sizeof cwd) > 0) { snprintf(abs, sizeof abs, "%s/%s", cwd, path); path = abs; }
    }
    if (!under(path)) return;
    if (logpath && under(logpath)) return;
    if (logfd >= 0) {
        char line[4400];
        int n = snprintf(line, sizeof line, "%s\t%s\t%ld\n", op, path, (long)syscall(SYS_gettid));
        if (n > 0) { ssize_t w = write(logfd, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1)); (void)w; }
    }
    if (!flag) return;
    struct timespec ts = {0, 50 * 1000 * 1000};
    while (syscall(SYS_faccessat, AT_FDCWD, flag, F_OK, 0) == 0) nanosleep(&ts, NULL);
}

#define REAL(name) static __typeof__(name) *real; if (!real) real = dlsym(RTLD_NEXT, #name)

int open(const char *p, int f, ...) { mode_t m = 0; if (f & (O_CREAT | O_TMPFILE)) { va_list a; va_start(a, f); m = va_arg(a, mode_t); va_end(a); } gate("open", p); REAL(open); return real(p, f, m); }
int open64(const char *p, int f, ...) { mode_t m = 0; if (f & (O_CREAT | O_TMPFILE)) { va_list a; va_start(a, f); m = va_arg(a, mode_t); va_end(a); } gate("open", p); REAL(open64); return real(p, f, m); }
int openat(int d, const char *p, int f, ...) { mode_t m = 0; if (f & (O_CREAT | O_TMPFILE)) { va_list a; va_start(a, f); m = va_arg(a, mode_t); va_end(a); } gate("openat", p); REAL(openat); return real(d, p, f, m); }
int openat64(int d, const char *p, int f, ...) { mode_t m = 0; if (f & (O_CREAT | O_TMPFILE)) { va_list a; va_start(a, f); m = va_arg(a, mode_t); va_end(a); } gate("openat", p); REAL(openat64); return real(d, p, f, m); }
FILE *fopen(const char *p, const char *m) { gate("fopen", p); REAL(fopen); return real(p, m); }
FILE *fopen64(const char *p, const char *m) { gate("fopen", p); REAL(fopen64); return real(p, m); }
int stat(const char *p, struct stat *s) { gate("stat", p); REAL(stat); return real(p, s); }
int lstat(const char *p, struct stat *s) { gate("lstat", p); REAL(lstat); return real(p, s); }
int fstatat(int d, const char *p, struct stat *s, int f) { gate("fstatat", p); REAL(fstatat); return real(d, p, s, f); }
#ifdef __GLIBC__
int stat64(const char *p, struct stat64 *s) { gate("stat", p); REAL(stat64); return real(p, s); }
int lstat64(const char *p, struct stat64 *s) { gate("lstat", p); REAL(lstat64); return real(p, s); }
int fstatat64(int d, const char *p, struct stat64 *s, int f) { gate("fstatat", p); REAL(fstatat64); return real(d, p, s, f); }
// glibc < 2.33 (RHEL 8): stat() is an inline wrapper around these
int __xstat(int v, const char *p, struct stat *s) { gate("stat", p); static int (*real)(int, const char *, struct stat *); if (!real) real = dlsym(RTLD_NEXT, "__xstat"); return real(v, p, s); }
int __lxstat(int v, const char *p, struct stat *s) { gate("lstat", p); static int (*real)(int, const char *, struct stat *); if (!real) real = dlsym(RTLD_NEXT, "__lxstat"); return real(v, p, s); }
int __xstat64(int v, const char *p, struct stat64 *s) { gate("stat", p); static int (*real)(int, const char *, struct stat64 *); if (!real) real = dlsym(RTLD_NEXT, "__xstat64"); return real(v, p, s); }
int __lxstat64(int v, const char *p, struct stat64 *s) { gate("lstat", p); static int (*real)(int, const char *, struct stat64 *); if (!real) real = dlsym(RTLD_NEXT, "__lxstat64"); return real(v, p, s); }
int __fxstatat(int v, int d, const char *p, struct stat *s, int f) { gate("fstatat", p); static int (*real)(int, int, const char *, struct stat *, int); if (!real) real = dlsym(RTLD_NEXT, "__fxstatat"); return real(v, d, p, s, f); }
int __fxstatat64(int v, int d, const char *p, struct stat64 *s, int f) { gate("fstatat", p); static int (*real)(int, int, const char *, struct stat64 *, int); if (!real) real = dlsym(RTLD_NEXT, "__fxstatat64"); return real(v, d, p, s, f); }
int statx(int d, const char *p, int f, unsigned int m, struct statx *s) { gate("statx", p); REAL(statx); return real(d, p, f, m, s); }
#endif
int access(const char *p, int m) { gate("access", p); REAL(access); return real(p, m); }
int faccessat(int d, const char *p, int m, int f) { gate("faccessat", p); REAL(faccessat); return real(d, p, m, f); }
ssize_t readlink(const char *p, char *b, size_t n) { gate("readlink", p); REAL(readlink); return real(p, b, n); }
ssize_t readlinkat(int d, const char *p, char *b, size_t n) { gate("readlinkat", p); REAL(readlinkat); return real(d, p, b, n); }
char *realpath(const char *p, char *r) { gate("realpath", p); REAL(realpath); return real(p, r); }
DIR *opendir(const char *p) { gate("opendir", p); REAL(opendir); return real(p); }
int chdir(const char *p) { gate("chdir", p); REAL(chdir); return real(p); }
int mkdir(const char *p, mode_t m) { gate("mkdir", p); REAL(mkdir); return real(p, m); }
int unlink(const char *p) { gate("unlink", p); REAL(unlink); return real(p); }
int rmdir(const char *p) { gate("rmdir", p); REAL(rmdir); return real(p); }
int rename(const char *a, const char *b) { gate("rename", a); gate("rename", b); REAL(rename); return real(a, b); }
int chmod(const char *p, mode_t m) { gate("chmod", p); REAL(chmod); return real(p, m); }
void *dlopen(const char *p, int f) { gate("dlopen", p); REAL(dlopen); return real(p, f); }
int execve(const char *p, char *const a[], char *const e[]) { gate("execve", p); REAL(execve); return real(p, a, e); }
int posix_spawn(pid_t *pid, const char *p, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at, char *const a[], char *const e[]) { gate("posix_spawn", p); REAL(posix_spawn); return real(pid, p, fa, at, a, e); }
int posix_spawnp(pid_t *pid, const char *p, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at, char *const a[], char *const e[]) { gate("posix_spawnp", p); REAL(posix_spawnp); return real(pid, p, fa, at, a, e); }
