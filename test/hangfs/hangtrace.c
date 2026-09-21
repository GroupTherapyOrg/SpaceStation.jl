// hangtrace: run a command with chosen directory trees behaving like a hung network filesystem.
//
//   hangtrace -p /depot:/home/me -f /run/x/hang [-l calls.log] -- command args...
//
// Every system call that takes a path (however it is made: libc, libuv's raw syscalls, a static
// binary) is trapped with a seccomp filter; this tracer reads the path, and when it lies under one
// of the prefixes it logs "<syscall>\t<path>\t<tid>" and, for as long as the flag file exists, does
// not let the thread continue. The thread is then stopped inside the kernel boundary of a system
// call, which is where a thread sits when NFS/BeeGFS/Lustre stops answering: the runtime cannot
// interrupt it, and a stop-the-world garbage collector has to wait for it. All other system calls
// run untraced at full speed. No root needed. Linux x86_64 or aarch64. Follows forks, threads, execs.
//
// Not emulated: page faults on mapped files, and I/O on descriptors that are already open.
#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__x86_64__)
#define ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define ARCH AUDIT_ARCH_AARCH64
#else
#error "hangtrace: x86_64 or aarch64 only"
#endif

// {syscall number, index of the path argument, index of the dirfd argument or -1, name}
struct sc { long nr; int path, dirfd; const char *name; };
static const struct sc table[] = {
#ifdef __NR_open
    {__NR_open, 0, -1, "open"}, {__NR_stat, 0, -1, "stat"}, {__NR_lstat, 0, -1, "lstat"}, {__NR_access, 0, -1, "access"},
    {__NR_readlink, 0, -1, "readlink"}, {__NR_mkdir, 0, -1, "mkdir"}, {__NR_unlink, 0, -1, "unlink"}, {__NR_rmdir, 0, -1, "rmdir"},
    {__NR_rename, 0, -1, "rename"}, {__NR_chmod, 0, -1, "chmod"},
#endif
    {__NR_openat, 1, 0, "openat"}, {__NR_newfstatat, 1, 0, "fstatat"}, {__NR_faccessat, 1, 0, "faccessat"},
    {__NR_readlinkat, 1, 0, "readlinkat"}, {__NR_mkdirat, 1, 0, "mkdirat"}, {__NR_unlinkat, 1, 0, "unlinkat"},
    {__NR_renameat, 1, 0, "renameat"}, {__NR_execve, 0, -1, "execve"}, {__NR_chdir, 0, -1, "chdir"},
    {__NR_statfs, 0, -1, "statfs"}, {__NR_truncate, 0, -1, "truncate"},
#ifdef __NR_statx
    {__NR_statx, 1, 0, "statx"},
#endif
#ifdef __NR_openat2
    {__NR_openat2, 1, 0, "openat2"},
#endif
#ifdef __NR_faccessat2
    {__NR_faccessat2, 1, 0, "faccessat2"},
#endif
#ifdef __NR_renameat2
    {__NR_renameat2, 1, 0, "renameat2"},
#endif
#ifdef __NR_execveat
    {__NR_execveat, 1, 0, "execveat"},
#endif
};
#define NSC ((int)(sizeof table / sizeof table[0]))

static const char *prefixes, *flag;
static FILE *logf;

static int under(const char *path) {
    const char *p = prefixes;
    while (p && *p) {
        const char *e = strchr(p, ':'); size_t n = e ? (size_t)(e - p) : strlen(p);
        while (n > 1 && p[n - 1] == '/') n--;
        if (n && strncmp(path, p, n) == 0 && (path[n] == '/' || path[n] == 0)) return 1;
        if (!e) break; p = e + 1;
    }
    return 0;
}

static int want_stacks;

// Who made this call? Walk the stopped thread's frame pointers (Julia's generated code and its
// runtime keep them) and name, for each return address, the mapped file it lies in and the offset
// there. Symbol names are looked up afterwards (test/hangfs/resolve_stack.py), not here.
static long peek(pid_t tid, unsigned long addr, int *ok) {
    errno = 0; long v = ptrace(PTRACE_PEEKDATA, tid, (void *)addr, 0); *ok = (errno == 0); return v;
}
static void describe(pid_t tid, unsigned long addr, FILE *out) {
    char mapsfile[64], line[4600]; snprintf(mapsfile, sizeof mapsfile, "/proc/%d/maps", tid);
    FILE *m = fopen(mapsfile, "r");
    if (!m) { fprintf(out, "    %#lx\n", addr); return; }
    while (fgets(line, sizeof line, m)) {
        unsigned long a, b, off; char perms[8], path[4200]; path[0] = 0;
        if (sscanf(line, "%lx-%lx %7s %lx %*s %*s %4199[^\n]", &a, &b, perms, &off, path) >= 4 && addr >= a && addr < b) {
            char *p = path; while (*p == ' ') p++;
            fprintf(out, "    %#lx\t%s\t%#lx\n", addr, *p ? p : "[anonymous: JIT code]", addr - a + off);
            fclose(m); return;
        }
    }
    fclose(m); fprintf(out, "    %#lx\t?\n", addr);
}
static void dump_stack(pid_t tid, FILE *out) {
    unsigned long pc, fp;
#if defined(__x86_64__)
    struct user_regs_struct r; struct iovec io = {&r, sizeof r};
    if (ptrace(PTRACE_GETREGSET, tid, NT_PRSTATUS, &io) < 0) return;
    pc = r.rip; fp = r.rbp;
#else
    struct user_pt_regs r; struct iovec io = {&r, sizeof r};
    if (ptrace(PTRACE_GETREGSET, tid, NT_PRSTATUS, &io) < 0) return;
    pc = r.pc; fp = r.regs[29];
#endif
    fprintf(out, "  stack of %d:\n", tid);
    describe(tid, pc, out);
    for (int depth = 0; depth < 48 && fp; depth++) {
        int ok1, ok2; unsigned long next = (unsigned long)peek(tid, fp, &ok1), ret = (unsigned long)peek(tid, fp + sizeof(long), &ok2);
        if (!ok1 || !ok2 || !ret) break;
        describe(tid, ret, out);
        if (next <= fp) break;
        fp = next;
    }
}

static int read_string(pid_t tid, unsigned long addr, char *out, size_t cap) {
    size_t got = 0;
    while (got + 1 < cap) {
        size_t chunk = 4096 - ((addr + got) & 4095); // never cross a page in one read
        if (chunk > cap - 1 - got) chunk = cap - 1 - got;
        struct iovec l = {out + got, chunk}, r = {(void *)(addr + got), chunk};
        ssize_t n = process_vm_readv(tid, &l, 1, &r, 1, 0);
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; i++) if (out[got + i] == 0) return 0;
        got += (size_t)n;
    }
    out[got] = 0;
    return got ? 0 : -1;
}

static int get_call(pid_t tid, long *nr, unsigned long args[6]) {
#if defined(__x86_64__)
    struct user_regs_struct r; struct iovec io = {&r, sizeof r};
    if (ptrace(PTRACE_GETREGSET, tid, NT_PRSTATUS, &io) < 0) return -1;
    *nr = (long)r.orig_rax; args[0] = r.rdi; args[1] = r.rsi; args[2] = r.rdx; args[3] = r.r10; args[4] = r.r8; args[5] = r.r9;
#else
    struct user_pt_regs r; struct iovec io = {&r, sizeof r};
    if (ptrace(PTRACE_GETREGSET, tid, NT_PRSTATUS, &io) < 0) return -1;
    *nr = (long)r.regs[8]; for (int i = 0; i < 6; i++) args[i] = r.regs[i];
#endif
    return 0;
}

// the absolute path a trapped call is about, or "" when it cannot be told
static void resolve(pid_t tid, const struct sc *s, unsigned long args[6], char *out, size_t cap) {
    char raw[4200]; out[0] = 0;
    if (read_string(tid, args[s->path], raw, sizeof raw) < 0) return;
    if (raw[0] == '/') { snprintf(out, cap, "%s", raw); return; }
    char link[64], base[4200];
    int dirfd = s->dirfd < 0 ? AT_FDCWD : (int)args[s->dirfd];
    if (dirfd == AT_FDCWD) snprintf(link, sizeof link, "/proc/%d/cwd", tid);
    else snprintf(link, sizeof link, "/proc/%d/fd/%d", tid, dirfd);
    ssize_t n = readlink(link, base, sizeof base - 1);
    if (n <= 0) return;
    base[n] = 0;
    snprintf(out, cap, "%s/%s", base, raw);
}

static void install_filter(void) {
    struct sock_filter prog[8 + 2 * 64]; int n = 0;
    prog[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
    prog[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, ARCH, 1, 0);
    prog[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    prog[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
    for (int i = 0; i < NSC; i++) {
        prog[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned)table[i].nr, 0, 1);
        prog[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE);
    }
    prog[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    struct sock_fprog fp = {(unsigned short)n, prog};
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &fp)) { perror("hangtrace: seccomp"); _exit(126); }
}

#define MAXHELD 4096
static pid_t held[MAXHELD]; static int nheld;
// tasks we have met: a task's FIRST stop is the SIGSTOP the kernel gives every new tracee, ours to swallow
#define NKNOWN (1 << 16)
static pid_t known[NKNOWN];
static int meet(pid_t t) { // 1 if new
    unsigned h = ((unsigned)t * 2654435761u) & (NKNOWN - 1);
    for (int k = 0; k < NKNOWN; k++, h = (h + 1) & (NKNOWN - 1)) { if (known[h] == t) return 0; if (known[h] == 0) { known[h] = t; return 1; } }
    return 0;
}

int main(int argc, char **argv) {
    const char *logpath = NULL; int i = 1;
    for (; i < argc && strcmp(argv[i], "--"); i++) {
        if (!strcmp(argv[i], "-p") && i + 1 < argc) prefixes = argv[++i];
        else if (!strcmp(argv[i], "-f") && i + 1 < argc) flag = argv[++i];
        else if (!strcmp(argv[i], "-l") && i + 1 < argc) logpath = argv[++i];
        else if (!strcmp(argv[i], "-b")) want_stacks = 1; // with -l: the stack of every call that is HELD
    }
    if (!prefixes || i + 1 >= argc) { fprintf(stderr, "usage: hangtrace -p prefix[:prefix] [-f flagfile] [-l log] -- command...\n"); return 2; }
    if (logpath) logf = fopen(logpath, "a");
    pid_t child = fork();
    if (child == 0) {
        ptrace(PTRACE_TRACEME, 0, 0, 0);
        raise(SIGSTOP);
        install_filter();
        execvp(argv[i + 1], argv + i + 1);
        perror("hangtrace: exec"); _exit(127);
    }
    int st; waitpid(child, &st, 0);
    long opts = PTRACE_O_TRACESECCOMP | PTRACE_O_TRACECLONE | PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | PTRACE_O_TRACEEXEC | PTRACE_O_EXITKILL;
    meet(child);
    ptrace(PTRACE_SETOPTIONS, child, 0, opts);
    ptrace(PTRACE_CONT, child, 0, 0);
    int code = 0;
    for (;;) {
        pid_t tid = waitpid(-1, &st, __WALL | (nheld ? WNOHANG : 0));
        if (tid == 0) { // threads are being held: let them go when the flag drops
            if (!flag || access(flag, F_OK) != 0) { for (int k = 0; k < nheld; k++) ptrace(PTRACE_CONT, held[k], 0, 0); nheld = 0; }
            else { struct timespec ts = {0, 20 * 1000 * 1000}; nanosleep(&ts, NULL); }
            continue;
        }
        if (tid < 0) { if (errno == ECHILD) break; if (errno == EINTR) continue; break; }
        if (WIFEXITED(st) || WIFSIGNALED(st)) { if (tid == child) code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st); continue; }
        if (!WIFSTOPPED(st)) continue;
        if (!(WSTOPSIG(st) == SIGSTOP)) meet(tid);
        int sig = WSTOPSIG(st), event = (unsigned)st >> 16;
        if (sig == SIGTRAP && event == PTRACE_EVENT_SECCOMP) {
            long nr; unsigned long args[6]; char path[8500];
            if (get_call(tid, &nr, args) == 0) {
                for (int k = 0; k < NSC; k++) if (table[k].nr == nr) {
                    resolve(tid, &table[k], args, path, sizeof path);
                    if (path[0] && under(path) && !(logpath && !strcmp(path, logpath))) {
                        if (logf) { fprintf(logf, "%s\t%s\t%d\n", table[k].name, path, tid); fflush(logf); }
                        if (flag && access(flag, F_OK) == 0 && nheld < MAXHELD) {
                            if (want_stacks && logf) { dump_stack(tid, logf); fflush(logf); }
                            held[nheld++] = tid; goto next;
                        }
                    }
                    break;
                }
            }
            ptrace(PTRACE_CONT, tid, 0, 0);
        } else if (sig == SIGTRAP && event) {
            ptrace(PTRACE_CONT, tid, 0, 0);              // clone/fork/exec notifications
        } else if (sig == SIGSTOP && meet(tid)) {
            ptrace(PTRACE_CONT, tid, 0, 0);              // a new task's first stop
        } else {
            ptrace(PTRACE_CONT, tid, 0, sig == SIGTRAP ? 0 : sig); // an ordinary signal: deliver it
        }
    next:;
    }
    return code;
}
