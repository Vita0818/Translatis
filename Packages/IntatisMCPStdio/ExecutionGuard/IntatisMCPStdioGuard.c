#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "IntatisMCPStdioGuard.h"

#if defined(__linux__)

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <sched.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>

/*
 * The official Swift static Linux SDK intentionally ships musl userspace
 * headers without the kernel UAPI header set. Keep the small, stable classic
 * BPF/seccomp ABI needed by this guard local instead of adding a dependency on
 * host Linux headers (which would make cross-build output host-dependent).
 */
struct sock_filter {
    uint16_t code;
    uint8_t jt;
    uint8_t jf;
    uint32_t k;
};

struct intatis_seccomp_data {
    int nr;
    uint32_t arch;
    uint64_t instruction_pointer;
    uint64_t args[6];
};

#define BPF_LD 0x00
#define BPF_W 0x00
#define BPF_ABS 0x20
#define BPF_JMP 0x05
#define BPF_JEQ 0x10
#define BPF_JSET 0x40
#define BPF_K 0x00
#define BPF_RET 0x06
#define BPF_STMT(code_value, k_value) \
    { (uint16_t)(code_value), 0, 0, (k_value) }
#define BPF_JUMP(code_value, k_value, true_jump, false_jump) \
    { (uint16_t)(code_value), (true_jump), (false_jump), (k_value) }

#define SECCOMP_RET_KILL_PROCESS 0x80000000U
#define SECCOMP_RET_ERRNO 0x00050000U
#define SECCOMP_RET_TRACE 0x7ff00000U
#define SECCOMP_RET_ALLOW 0x7fff0000U
#define SECCOMP_RET_DATA 0x0000ffffU

#define SECCOMP_SET_MODE_FILTER 1U

struct sock_fprog {
    uint16_t len;
    struct sock_filter *filter;
};

#define AUDIT_ARCH_X86_64 0xc000003eU
#define AUDIT_ARCH_AARCH64 0xc00000b7U

#ifndef __WALL
#define __WALL 0x40000000
#endif

#ifndef PTRACE_O_EXITKILL
#define PTRACE_O_EXITKILL (1UL << 20)
#endif

#ifndef PTRACE_EVENT_STOP
#define PTRACE_EVENT_STOP 128
#endif

#ifndef PTRACE_EVENT_SECCOMP
#define PTRACE_EVENT_SECCOMP 7
#endif

#ifndef PTRACE_O_TRACESECCOMP
#define PTRACE_O_TRACESECCOMP (1UL << PTRACE_EVENT_SECCOMP)
#endif

#ifndef PTRACE_O_TRACESYSGOOD
#define PTRACE_O_TRACESYSGOOD 0x00000001
#endif

#ifndef PTRACE_SEIZE
#define PTRACE_SEIZE 0x4206
#endif

#ifndef PTRACE_INTERRUPT
#define PTRACE_INTERRUPT 0x4207
#endif

#ifndef PTRACE_GET_SYSCALL_INFO
#define PTRACE_GET_SYSCALL_INFO 0x420e
#endif

#ifndef PTRACE_SETREGSET
#define PTRACE_SETREGSET 0x4205
#endif

#define INTATIS_PTRACE_SYSCALL_INFO_NONE 0U
#define INTATIS_PTRACE_SYSCALL_INFO_ENTRY 1U
#define INTATIS_PTRACE_SYSCALL_INFO_EXIT 2U
#define INTATIS_PTRACE_SYSCALL_INFO_SECCOMP 3U

#ifndef NT_PRSTATUS
#define NT_PRSTATUS 1
#endif

#ifndef NT_ARM_SYSTEM_CALL
#define NT_ARM_SYSTEM_CALL 0x404
#endif

#ifndef CLONE_UNTRACED
#define CLONE_UNTRACED 0x00800000
#endif

#if defined(__x86_64__)
#define INTATIS_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define INTATIS_AUDIT_ARCH AUDIT_ARCH_AARCH64
#else
#define INTATIS_AUDIT_ARCH 0
#endif

#define INTATIS_SECCOMP_ALLOW SECCOMP_RET_ALLOW
#define INTATIS_SECCOMP_TRACE SECCOMP_RET_TRACE
#define INTATIS_SECCOMP_DENY \
    (SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA))
#define INTATIS_SECCOMP_NOT_IMPLEMENTED \
    (SECCOMP_RET_ERRNO | (ENOSYS & SECCOMP_RET_DATA))

typedef struct {
    pid_t pid;
    int alive;
    int is_wrapper_root;
    int may_exec_helper;
    int helper_exec_seen;
    int frozen;
    int pending_status;
} intatis_tracee_t;

typedef struct {
    char *canonical_path;
    uint64_t device_id;
    uint64_t file_id;
    uint64_t byte_count;
} intatis_owned_identity_t;

struct intatis_mcp_stdio_guard {
    pid_t group_id;
    pid_t initial_pid;
    pid_t target_pid;
    int wrapper_seen;
    int target_seen;
    int target_exited;
    int target_exit_status;
    int violation;
    int network_violation;
    int fatal_errno;
    intatis_mcp_stdio_network_policy_t network_policy;
    intatis_owned_identity_t wrapper;
    intatis_owned_identity_t primary;
    intatis_owned_identity_t *helpers;
    size_t helper_count;
    intatis_tracee_t *tracees;
    size_t tracee_count;
    size_t tracee_capacity;
};

#define INTATIS_MAXIMUM_TRACEE_COUNT 4096U
#define INTATIS_FREEZE_TIMEOUT_MILLISECONDS 2000U
#define INTATIS_NETWORK_SYSCALL_TIMEOUT_MILLISECONDS 5000U

typedef struct {
    struct sock_filter *items;
    size_t count;
    size_t capacity;
} intatis_filter_builder_t;

static void intatis_close_fd(int *fd) {
    if (*fd >= 0) {
        (void)close(*fd);
        *fd = -1;
    }
}

static int intatis_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) {
        return -1;
    }
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int intatis_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        return -1;
    }
    return intatis_set_cloexec(fd);
}

static int intatis_pipe_cloexec(int descriptors[2]) {
#if defined(__NR_pipe2)
    if (syscall(__NR_pipe2, descriptors, O_CLOEXEC) == 0) {
        return 0;
    }
    if (errno != ENOSYS) {
        return -1;
    }
#endif
    if (pipe(descriptors) < 0) {
        return -1;
    }
    if (intatis_set_cloexec(descriptors[0]) < 0 ||
        intatis_set_cloexec(descriptors[1]) < 0) {
        int saved = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        errno = saved;
        return -1;
    }
    return 0;
}

static int intatis_append_filter(
    intatis_filter_builder_t *builder,
    struct sock_filter instruction) {
    if (builder->count == builder->capacity) {
        size_t next = builder->capacity == 0 ? 32 : builder->capacity * 2;
        struct sock_filter *items = (struct sock_filter *)realloc(
            builder->items, next * sizeof(struct sock_filter));
        if (items == NULL) {
            return -1;
        }
        builder->items = items;
        builder->capacity = next;
    }
    builder->items[builder->count++] = instruction;
    return 0;
}

#define INTATIS_STMT(code_value, k_value) \
    ((struct sock_filter)BPF_STMT((code_value), (k_value)))
#define INTATIS_JUMP(code_value, k_value, true_jump, false_jump) \
    ((struct sock_filter)BPF_JUMP( \
        (code_value), (k_value), (true_jump), (false_jump)))

static int intatis_append_deny_syscall(
    intatis_filter_builder_t *builder,
    int syscall_number,
    uint32_t denial) {
    return intatis_append_filter(
               builder,
               INTATIS_JUMP(
                   BPF_JMP | BPF_JEQ | BPF_K,
                   (uint32_t)syscall_number,
                   0,
                   1)) ||
           intatis_append_filter(
               builder,
               INTATIS_STMT(BPF_RET | BPF_K, denial));
}

static int intatis_append_trace_syscall(
    intatis_filter_builder_t *builder,
    int syscall_number) {
    return intatis_append_deny_syscall(
        builder, syscall_number, INTATIS_SECCOMP_TRACE);
}

static int intatis_build_seccomp_filter(
    int helpers_enabled,
    struct sock_filter **items,
    size_t *count) {
    if (INTATIS_AUDIT_ARCH == 0) {
        errno = ENOTSUP;
        return -1;
    }
    intatis_filter_builder_t builder = {0};
    if (intatis_append_filter(
            &builder,
            INTATIS_STMT(
                BPF_LD | BPF_W | BPF_ABS,
                offsetof(struct intatis_seccomp_data, arch))) ||
        intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JEQ | BPF_K,
                INTATIS_AUDIT_ARCH,
                1,
                0)) ||
        intatis_append_filter(
            &builder,
            INTATIS_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS)) ||
        intatis_append_filter(
            &builder,
            INTATIS_STMT(
                BPF_LD | BPF_W | BPF_ABS,
                offsetof(struct intatis_seccomp_data, nr)))) {
        free(builder.items);
        return -1;
    }

#ifdef __NR_setsid
    if (intatis_append_deny_syscall(
            &builder, __NR_setsid, INTATIS_SECCOMP_DENY)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_setpgid
    if (intatis_append_deny_syscall(
            &builder, __NR_setpgid, INTATIS_SECCOMP_DENY)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_unshare
    if (intatis_append_deny_syscall(
            &builder, __NR_unshare, INTATIS_SECCOMP_DENY)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_setns
    if (intatis_append_deny_syscall(
            &builder, __NR_setns, INTATIS_SECCOMP_DENY)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_ptrace
    if (intatis_append_deny_syscall(
            &builder, __NR_ptrace, INTATIS_SECCOMP_DENY)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_clone3
    /*
     * seccomp BPF cannot inspect the pointed-to clone_args atomically.
     * ENOSYS forces libc runtimes onto clone(2), whose flags are visible.
     */
    if (intatis_append_deny_syscall(
            &builder,
            __NR_clone3,
            INTATIS_SECCOMP_NOT_IMPLEMENTED)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_fork
    if (!helpers_enabled &&
        intatis_append_deny_syscall(
            &builder, __NR_fork, INTATIS_SECCOMP_DENY)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_vfork
    if (!helpers_enabled &&
        intatis_append_deny_syscall(
            &builder, __NR_vfork, INTATIS_SECCOMP_DENY)) {
        goto allocation_failure;
    }
#endif

#ifdef __NR_clone
    /*
     * Threads stay inside the same process image, share the leader's
     * descriptor table, and are trace-attached. Requiring CLONE_FILES lets
     * the tracer use a leader pidfd for a syscall issued by any thread.
     * A default authority denies every process-producing clone. A helper
     * authority permits process clone only when it cannot suppress tracing or
     * create a namespace that could escape the bwrap/process-group boundary.
     */
    if (intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JEQ | BPF_K,
                __NR_clone,
                0,
                helpers_enabled ? 8 : 6)) ||
        intatis_append_filter(
            &builder,
            INTATIS_STMT(
                BPF_LD | BPF_W | BPF_ABS,
                offsetof(struct intatis_seccomp_data, args[0]))) ||
        intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JSET | BPF_K,
                CLONE_THREAD,
                0,
                3)) ||
        intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JSET | BPF_K,
                CLONE_FILES,
                1,
                0)) ||
        intatis_append_filter(
            &builder,
            INTATIS_STMT(
                BPF_RET | BPF_K, INTATIS_SECCOMP_DENY)) ||
        intatis_append_filter(
            &builder,
            INTATIS_STMT(
                BPF_RET | BPF_K, INTATIS_SECCOMP_ALLOW))) {
        goto allocation_failure;
    }
    if (helpers_enabled) {
        const uint32_t forbidden =
            CLONE_UNTRACED | CLONE_NEWCGROUP | CLONE_NEWIPC |
            CLONE_NEWNET | CLONE_NEWNS | CLONE_NEWPID |
            CLONE_NEWUSER | CLONE_NEWUTS;
        if (intatis_append_filter(
                &builder,
                INTATIS_JUMP(
                    BPF_JMP | BPF_JSET | BPF_K,
                    forbidden,
                    0,
                    1)) ||
            intatis_append_filter(
                &builder,
                INTATIS_STMT(
                    BPF_RET | BPF_K, INTATIS_SECCOMP_DENY)) ||
            intatis_append_filter(
                &builder,
                INTATIS_STMT(
                    BPF_RET | BPF_K, INTATIS_SECCOMP_ALLOW))) {
            goto allocation_failure;
        }
    } else if (intatis_append_filter(
                   &builder,
                   INTATIS_STMT(
                       BPF_RET | BPF_K, INTATIS_SECCOMP_DENY))) {
        goto allocation_failure;
    }
#endif

#ifdef __NR_prctl
    /*
     * Preserve the wrapper's parent-death contract and prevent the target
     * from changing ptrace/subreaper ownership or revoking the dumpable state
     * required for the already-attached tracer's pidfd_getfd mediation.
     */
    if (intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JEQ | BPF_K,
                __NR_prctl,
                0,
                7)) ||
        intatis_append_filter(
            &builder,
            INTATIS_STMT(
                BPF_LD | BPF_W | BPF_ABS,
                offsetof(struct intatis_seccomp_data, args[0]))) ||
        intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JEQ | BPF_K,
                PR_SET_PDEATHSIG,
                4,
                0)) ||
        intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JEQ | BPF_K,
                PR_SET_CHILD_SUBREAPER,
                3,
                0)) ||
        intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JEQ | BPF_K,
                PR_SET_DUMPABLE,
                2,
                0)) ||
        intatis_append_filter(
            &builder,
            INTATIS_JUMP(
                BPF_JMP | BPF_JEQ | BPF_K,
                PR_SET_PTRACER,
                1,
                0)) ||
        intatis_append_filter(
            &builder,
            INTATIS_STMT(
                BPF_RET | BPF_K, INTATIS_SECCOMP_ALLOW)) ||
        intatis_append_filter(
            &builder,
            INTATIS_STMT(
                BPF_RET | BPF_K, INTATIS_SECCOMP_DENY))) {
        goto allocation_failure;
    }
#endif

    /*
     * A classic seccomp filter cannot safely dereference connect(2)'s
     * sockaddr. Route every network-authority syscall through a
     * PTRACE_EVENT_SECCOMP stop. The tracer either proves the exact gateway
     * tuple before continuing or kills the complete owned generation.
     */
#ifdef __NR_socket
    if (intatis_append_trace_syscall(&builder, __NR_socket)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_connect
    if (intatis_append_trace_syscall(&builder, __NR_connect)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_bind
    if (intatis_append_trace_syscall(&builder, __NR_bind)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_listen
    if (intatis_append_trace_syscall(&builder, __NR_listen)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_accept
    if (intatis_append_trace_syscall(&builder, __NR_accept)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_accept4
    if (intatis_append_trace_syscall(&builder, __NR_accept4)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_sendto
    if (intatis_append_trace_syscall(&builder, __NR_sendto)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_sendmsg
    if (intatis_append_trace_syscall(&builder, __NR_sendmsg)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_sendmmsg
    if (intatis_append_trace_syscall(&builder, __NR_sendmmsg)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_io_uring_setup
    if (intatis_append_trace_syscall(&builder, __NR_io_uring_setup)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_io_uring_enter
    if (intatis_append_trace_syscall(&builder, __NR_io_uring_enter)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_io_uring_register
    if (intatis_append_trace_syscall(&builder, __NR_io_uring_register)) {
        goto allocation_failure;
    }
#endif
#ifdef __NR_bpf
    if (intatis_append_trace_syscall(&builder, __NR_bpf)) {
        goto allocation_failure;
    }
#endif

    if (intatis_append_filter(
            &builder,
            INTATIS_STMT(BPF_RET | BPF_K, INTATIS_SECCOMP_ALLOW))) {
        goto allocation_failure;
    }
    *items = builder.items;
    *count = builder.count;
    return 0;

allocation_failure:
    free(builder.items);
    errno = ENOMEM;
    return -1;
}

static int intatis_make_seccomp_fd(
    const char *runtime_directory,
    int helpers_enabled) {
    char path[4096];
    int length = snprintf(
        path,
        sizeof(path),
        "%s/%s",
        runtime_directory,
        "descendant-exec-filter.bpf");
    if (length <= 0 || (size_t)length >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int fd = open(
        path,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return -1;
    }
    (void)unlink(path);

    struct sock_filter *items = NULL;
    size_t count = 0;
    if (intatis_build_seccomp_filter(
            helpers_enabled, &items, &count) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    size_t byte_count = count * sizeof(struct sock_filter);
    const unsigned char *bytes = (const unsigned char *)items;
    size_t offset = 0;
    while (offset < byte_count) {
        ssize_t written = write(fd, bytes + offset, byte_count - offset);
        if (written > 0) {
            offset += (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            int saved = errno;
            free(items);
            close(fd);
            errno = saved;
            return -1;
        }
    }
    free(items);
    if (lseek(fd, 0, SEEK_SET) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

static int intatis_close_from_four(void) {
#if defined(__NR_close_range)
    if (syscall(__NR_close_range, 4U, ~0U, 0U) == 0) {
        return 0;
    }
    if (errno != ENOSYS) {
        return -1;
    }
#endif
    long maximum = sysconf(_SC_OPEN_MAX);
    if (maximum < 0 || maximum > 1048576) {
        maximum = 65536;
    }
    for (int descriptor = 4; descriptor < maximum; descriptor++) {
        (void)close(descriptor);
    }
    return 0;
}

static int intatis_write_handshake_byte(int fd) {
    const unsigned char byte = 0xa5U;
    for (;;) {
        ssize_t written = write(fd, &byte, sizeof(byte));
        if (written == (ssize_t)sizeof(byte)) {
            return 0;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        errno = EIO;
        return -1;
    }
}

static int intatis_read_handshake_byte(int fd) {
    unsigned char byte = 0;
    for (;;) {
        ssize_t count = read(fd, &byte, sizeof(byte));
        if (count == (ssize_t)sizeof(byte)) {
            return byte == 0xa5U ? 0 : -1;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        errno = EIO;
        return -1;
    }
}

static void intatis_guarded_child(
    const char *wrapper_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int stdin_read,
    int stdin_write,
    int stdout_read,
    int stdout_write,
    int stderr_read,
    int stderr_write,
    int seccomp_fd,
    int startup_child,
    int startup_parent) {
    pid_t expected_parent = getppid();
    if (setpgid(0, 0) < 0 ||
        prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) < 0 ||
        getppid() != expected_parent ||
        dup2(stdin_read, STDIN_FILENO) < 0 ||
        dup2(stdout_write, STDOUT_FILENO) < 0 ||
        dup2(stderr_write, STDERR_FILENO) < 0 ||
        dup2(seccomp_fd, 3) < 0) {
        _exit(126);
    }
    int flags = fcntl(3, F_GETFD);
    if (flags < 0 || fcntl(3, F_SETFD, flags & ~FD_CLOEXEC) < 0) {
        _exit(126);
    }
    (void)close(stdin_write);
    (void)close(stdout_read);
    (void)close(stderr_read);
    (void)close(startup_parent);
    /*
     * The parent SEIZEs this still-blocked process before releasing it.
     * Consequently no wrapper or target instruction can execute before all
     * ptrace options, including TRACESECCOMP and INTERRUPT support, are live.
     */
    if (intatis_write_handshake_byte(startup_child) < 0 ||
        intatis_read_handshake_byte(startup_child) < 0) {
        _exit(126);
    }
    (void)close(startup_child);
    if (intatis_close_from_four() < 0 ||
        chdir(working_directory) < 0) {
        _exit(126);
    }
    execve(wrapper_path, argv, envp);
    _exit(127);
}

static int intatis_capture_owned_identity(
    const char *path,
    intatis_owned_identity_t *identity) {
    struct stat metadata;
    if (path == NULL || lstat(path, &metadata) < 0 ||
        !S_ISREG(metadata.st_mode)) {
        return -1;
    }
    identity->canonical_path = strdup(path);
    if (identity->canonical_path == NULL) {
        return -1;
    }
    identity->device_id = (uint64_t)metadata.st_dev;
    identity->file_id = (uint64_t)metadata.st_ino;
    identity->byte_count = (uint64_t)metadata.st_size;
    return 0;
}

static int intatis_copy_identity(
    const intatis_mcp_stdio_exec_identity_t *source,
    intatis_owned_identity_t *destination) {
    if (source == NULL || source->canonical_path == NULL) {
        errno = EINVAL;
        return -1;
    }
    destination->canonical_path = strdup(source->canonical_path);
    if (destination->canonical_path == NULL) {
        return -1;
    }
    destination->device_id = source->device_id;
    destination->file_id = source->file_id;
    destination->byte_count = source->byte_count;
    return 0;
}

static int intatis_add_tracee(
    intatis_mcp_stdio_guard_t *guard,
    pid_t pid,
    int is_wrapper_root) {
    for (size_t index = 0; index < guard->tracee_count; index++) {
        if (guard->tracees[index].pid == pid) {
            guard->tracees[index].alive = 1;
            return 0;
        }
    }
    if (guard->tracee_count >= INTATIS_MAXIMUM_TRACEE_COUNT) {
        errno = E2BIG;
        return -1;
    }
    if (guard->tracee_count == guard->tracee_capacity) {
        size_t next =
            guard->tracee_capacity == 0 ? 8 : guard->tracee_capacity * 2;
        intatis_tracee_t *tracees = (intatis_tracee_t *)realloc(
            guard->tracees, next * sizeof(intatis_tracee_t));
        if (tracees == NULL) {
            return -1;
        }
        guard->tracees = tracees;
        guard->tracee_capacity = next;
    }
    intatis_tracee_t tracee;
    memset(&tracee, 0, sizeof(tracee));
    tracee.pid = pid;
    tracee.alive = 1;
    tracee.is_wrapper_root = is_wrapper_root;
    tracee.may_exec_helper =
        guard->target_seen && guard->helper_count > 0;
    guard->tracees[guard->tracee_count++] = tracee;
    return 0;
}

static intatis_tracee_t *intatis_find_tracee(
    intatis_mcp_stdio_guard_t *guard,
    pid_t pid) {
    for (size_t index = 0; index < guard->tracee_count; index++) {
        if (guard->tracees[index].pid == pid) {
            return &guard->tracees[index];
        }
    }
    return NULL;
}

static int intatis_identity_matches_pid(
    pid_t pid,
    const intatis_owned_identity_t *expected) {
    char proc_path[64];
    char resolved[4096];
    struct stat metadata;
    int length = snprintf(
        proc_path, sizeof(proc_path), "/proc/%ld/exe", (long)pid);
    if (length <= 0 || (size_t)length >= sizeof(proc_path) ||
        stat(proc_path, &metadata) < 0) {
        return 0;
    }
    ssize_t count = readlink(proc_path, resolved, sizeof(resolved) - 1);
    if (count <= 0 || (size_t)count >= sizeof(resolved)) {
        return 0;
    }
    resolved[count] = '\0';
    const char deleted_suffix[] = " (deleted)";
    size_t resolved_length = (size_t)count;
    size_t suffix_length = sizeof(deleted_suffix) - 1;
    if (resolved_length >= suffix_length &&
        strcmp(
            resolved + resolved_length - suffix_length,
            deleted_suffix) == 0) {
        return 0;
    }
    return strcmp(resolved, expected->canonical_path) == 0 &&
           (uint64_t)metadata.st_dev == expected->device_id &&
           (uint64_t)metadata.st_ino == expected->file_id &&
           (uint64_t)metadata.st_size == expected->byte_count;
}

static int intatis_match_helper(
    intatis_mcp_stdio_guard_t *guard,
    pid_t pid) {
    for (size_t index = 0; index < guard->helper_count; index++) {
        if (intatis_identity_matches_pid(pid, &guard->helpers[index])) {
            return 1;
        }
    }
    return 0;
}

#if defined(__x86_64__)
typedef struct {
    uint64_t r15;
    uint64_t r14;
    uint64_t r13;
    uint64_t r12;
    uint64_t rbp;
    uint64_t rbx;
    uint64_t r11;
    uint64_t r10;
    uint64_t r9;
    uint64_t r8;
    uint64_t rax;
    uint64_t rcx;
    uint64_t rdx;
    uint64_t rsi;
    uint64_t rdi;
    uint64_t orig_rax;
    uint64_t rip;
    uint64_t cs;
    uint64_t eflags;
    uint64_t rsp;
    uint64_t ss;
    uint64_t fs_base;
    uint64_t gs_base;
    uint64_t ds;
    uint64_t es;
    uint64_t fs;
    uint64_t gs;
} intatis_native_registers_t;
#elif defined(__aarch64__)
typedef struct {
    uint64_t registers[31];
    uint64_t stack_pointer;
    uint64_t program_counter;
    uint64_t processor_state;
} intatis_native_registers_t;
#endif

typedef struct {
    long syscall_number;
    uint64_t arguments[6];
} intatis_syscall_snapshot_t;

typedef struct {
    uint8_t operation;
    uint8_t padding[3];
    uint32_t architecture;
    uint64_t instruction_pointer;
    uint64_t stack_pointer;
} intatis_ptrace_syscall_info_prefix_t;

static int intatis_ptrace_syscall_operation(
    pid_t pid,
    uint8_t *operation) {
    intatis_ptrace_syscall_info_prefix_t information;
    memset(&information, 0, sizeof(information));
    long count = ptrace(
        PTRACE_GET_SYSCALL_INFO,
        pid,
        (void *)(uintptr_t)sizeof(information),
        &information);
    if (count < (long)sizeof(information) ||
        information.operation
            == INTATIS_PTRACE_SYSCALL_INFO_NONE) {
        errno = ENOTSUP;
        return -1;
    }
    *operation = information.operation;
    return 0;
}

static int intatis_read_syscall_snapshot(
    pid_t pid,
    intatis_syscall_snapshot_t *snapshot) {
#if defined(__x86_64__) || defined(__aarch64__)
    intatis_native_registers_t registers;
    memset(&registers, 0, sizeof(registers));
    struct iovec vector;
    vector.iov_base = &registers;
    vector.iov_len = sizeof(registers);
    if (ptrace(
            PTRACE_GETREGSET,
            pid,
            (void *)(uintptr_t)NT_PRSTATUS,
            &vector) < 0 ||
        vector.iov_len < sizeof(registers)) {
        return -1;
    }
#if defined(__x86_64__)
    snapshot->syscall_number = (long)registers.orig_rax;
    snapshot->arguments[0] = registers.rdi;
    snapshot->arguments[1] = registers.rsi;
    snapshot->arguments[2] = registers.rdx;
    snapshot->arguments[3] = registers.r10;
    snapshot->arguments[4] = registers.r8;
    snapshot->arguments[5] = registers.r9;
#else
    int syscall_number = 0;
    struct iovec syscall_vector;
    syscall_vector.iov_base = &syscall_number;
    syscall_vector.iov_len = sizeof(syscall_number);
    if (ptrace(
            PTRACE_GETREGSET,
            pid,
            (void *)(uintptr_t)NT_ARM_SYSTEM_CALL,
            &syscall_vector) < 0 ||
        syscall_vector.iov_len != sizeof(syscall_number)) {
        return -1;
    }
    snapshot->syscall_number = (long)syscall_number;
    for (size_t index = 0; index < 6; index++) {
        snapshot->arguments[index] = registers.registers[index];
    }
#endif
    return 0;
#else
    (void)pid;
    (void)snapshot;
    errno = ENOTSUP;
    return -1;
#endif
}

static int intatis_rewrite_syscall_number(
    pid_t pid,
    long syscall_number) {
#if defined(__x86_64__) || defined(__aarch64__)
    intatis_native_registers_t registers;
    memset(&registers, 0, sizeof(registers));
    struct iovec vector;
    vector.iov_base = &registers;
    vector.iov_len = sizeof(registers);
    if (ptrace(
            PTRACE_GETREGSET,
            pid,
            (void *)(uintptr_t)NT_PRSTATUS,
            &vector) < 0 ||
        vector.iov_len < sizeof(registers)) {
        return -1;
    }
#if defined(__x86_64__)
    registers.orig_rax = (uint64_t)syscall_number;
#else
    if (syscall_number < (long)INT_MIN ||
        syscall_number > (long)INT_MAX) {
        errno = EINVAL;
        return -1;
    }
    int arm_syscall_number = (int)syscall_number;
    struct iovec syscall_vector;
    syscall_vector.iov_base = &arm_syscall_number;
    syscall_vector.iov_len = sizeof(arm_syscall_number);
    return ptrace(
               PTRACE_SETREGSET,
               pid,
               (void *)(uintptr_t)NT_ARM_SYSTEM_CALL,
               &syscall_vector) < 0
        ? -1
        : 0;
#endif
#if defined(__x86_64__)
    vector.iov_len = sizeof(registers);
    return ptrace(
               PTRACE_SETREGSET,
               pid,
               (void *)(uintptr_t)NT_PRSTATUS,
               &vector) < 0
        ? -1
        : 0;
#endif
#else
    (void)pid;
    (void)syscall_number;
    errno = ENOTSUP;
    return -1;
#endif
}

static int intatis_rewrite_syscall_result(
    pid_t pid,
    long result) {
#if defined(__x86_64__) || defined(__aarch64__)
    intatis_native_registers_t registers;
    memset(&registers, 0, sizeof(registers));
    struct iovec vector;
    vector.iov_base = &registers;
    vector.iov_len = sizeof(registers);
    if (ptrace(
            PTRACE_GETREGSET,
            pid,
            (void *)(uintptr_t)NT_PRSTATUS,
            &vector) < 0 ||
        vector.iov_len < sizeof(registers)) {
        return -1;
    }
#if defined(__x86_64__)
    registers.rax = (uint64_t)result;
#else
    registers.registers[0] = (uint64_t)result;
#endif
    vector.iov_len = sizeof(registers);
    return ptrace(
               PTRACE_SETREGSET,
               pid,
               (void *)(uintptr_t)NT_PRSTATUS,
               &vector) < 0
        ? -1
        : 0;
#else
    (void)pid;
    (void)result;
    errno = ENOTSUP;
    return -1;
#endif
}

static int intatis_read_tracee_memory(
    pid_t pid,
    uint64_t source_address,
    void *destination,
    size_t byte_count) {
    if (source_address == 0 || destination == NULL ||
        byte_count == 0 ||
        source_address > UINTPTR_MAX ||
        source_address + byte_count < source_address) {
        errno = EFAULT;
        return -1;
    }
    unsigned char *bytes = (unsigned char *)destination;
    size_t offset = 0;
    while (offset < byte_count) {
        errno = 0;
        long word = ptrace(
            PTRACE_PEEKDATA,
            pid,
            (void *)(uintptr_t)(source_address + offset),
            NULL);
        if (word == -1 && errno != 0) {
            return -1;
        }
        size_t remaining = byte_count - offset;
        size_t copied =
            remaining < sizeof(word) ? remaining : sizeof(word);
        memcpy(bytes + offset, &word, copied);
        offset += copied;
    }
    return 0;
}

static int intatis_validate_network_syscall(
    intatis_mcp_stdio_guard_t *guard,
    pid_t pid) {
    intatis_syscall_snapshot_t snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    if (intatis_read_syscall_snapshot(pid, &snapshot) < 0) {
        return -1;
    }

#ifdef __NR_socket
    if (snapshot.syscall_number == __NR_socket) {
        int family = (int)snapshot.arguments[0];
        int type = (int)snapshot.arguments[1];
        int protocol = (int)snapshot.arguments[2];
        const int socket_type_mask = 0x0f;
        const int allowed_flags = SOCK_CLOEXEC | SOCK_NONBLOCK;
        return guard->network_policy.mode
                    == INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY &&
               family == AF_INET &&
               (type & socket_type_mask) == SOCK_STREAM &&
               (type & ~(socket_type_mask | allowed_flags)) == 0 &&
               (protocol == 0 || protocol == IPPROTO_TCP)
            ? 0
            : -1;
    }
#endif

#ifdef __NR_connect
    if (snapshot.syscall_number == __NR_connect) {
        if (guard->network_policy.mode
                != INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY ||
            snapshot.arguments[2] != sizeof(struct sockaddr_in)) {
            return -1;
        }
        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        if (intatis_read_tracee_memory(
                pid,
                snapshot.arguments[1],
                &address,
                sizeof(address)) < 0) {
            return -1;
        }
        return address.sin_family == AF_INET &&
               address.sin_port == htons(
                   guard->network_policy.gateway_port_host_order) &&
               address.sin_addr.s_addr ==
                   guard->network_policy.gateway_ipv4_network_order
            ? 0
            : -1;
    }
#endif

#ifdef __NR_sendto
    if (snapshot.syscall_number == __NR_sendto) {
        /*
         * Linux libc implements send(3) with sendto(2). A null destination is
         * therefore required for ordinary writes on the already-proven TCP
         * tunnel. Any destination-bearing sendto remains a bypass attempt.
         */
        return guard->network_policy.mode
                    == INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY &&
               snapshot.arguments[4] == 0 &&
               snapshot.arguments[5] == 0
            ? 0
            : -1;
    }
#endif

#ifdef __NR_sendmsg
    if (snapshot.syscall_number == __NR_sendmsg) {
        if (guard->network_policy.mode
                != INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY) {
            return -1;
        }
        struct msghdr message;
        memset(&message, 0, sizeof(message));
        if (intatis_read_tracee_memory(
                pid,
                snapshot.arguments[1],
                &message,
                sizeof(message)) < 0) {
            return -1;
        }
        /*
         * A destination-free/control-free message is equivalent to a write
         * on the connected exact gateway socket. Reject msg_name and ancillary
         * data so sendmsg cannot select another peer or pass an authority-
         * bearing descriptor.
         */
        return message.msg_name == NULL &&
               message.msg_namelen == 0 &&
               message.msg_control == NULL &&
               message.msg_controllen == 0
            ? 0
            : -1;
    }
#endif

    /*
     * bind/listen/accept, destination-bearing send calls, io_uring, and BPF
     * reach this stop only because the filter classified them as authority
     * expansion attempts. They are never valid for a stdio HTTPS tunnel.
     */
    return -1;
}

static uint64_t intatis_monotonic_milliseconds(void);

static int intatis_thread_group_leader(
    pid_t thread_id,
    pid_t *leader_id) {
    if (thread_id <= 0 || leader_id == NULL) {
        errno = EINVAL;
        return -1;
    }
    char path[64];
    int path_length = snprintf(
        path,
        sizeof(path),
        "/proc/%ld/status",
        (long)thread_id);
    if (path_length <= 0 ||
        (size_t)path_length >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int descriptor =
        open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return -1;
    }
    unsigned char status[16384];
    size_t used = 0;
    while (used < sizeof(status)) {
        ssize_t count =
            read(descriptor, status + used, sizeof(status) - used);
        if (count > 0) {
            used += (size_t)count;
            continue;
        }
        if (count == 0) {
            break;
        }
        if (errno != EINTR) {
            int saved = errno;
            (void)close(descriptor);
            errno = saved;
            return -1;
        }
    }
    if (used == sizeof(status)) {
        unsigned char extra = 0;
        ssize_t count;
        do {
            count = read(descriptor, &extra, sizeof(extra));
        } while (count < 0 && errno == EINTR);
        if (count != 0) {
            (void)close(descriptor);
            errno = count < 0 ? errno : EOVERFLOW;
            return -1;
        }
    }
    (void)close(descriptor);

    static const unsigned char prefix[] = {
        'T', 'g', 'i', 'd', ':',
    };
    for (size_t offset = 0;
         offset + sizeof(prefix) <= used;
         offset++) {
        if ((offset != 0 && status[offset - 1] != '\n') ||
            memcmp(status + offset, prefix, sizeof(prefix)) != 0) {
            continue;
        }
        size_t cursor = offset + sizeof(prefix);
        while (cursor < used &&
               (status[cursor] == ' ' ||
                status[cursor] == '\t')) {
            cursor++;
        }
        uint64_t parsed = 0;
        size_t digits = 0;
        while (cursor < used &&
               status[cursor] >= '0' &&
               status[cursor] <= '9') {
            uint64_t digit =
                (uint64_t)(status[cursor] - '0');
            if (parsed >
                ((uint64_t)INT_MAX - digit) / 10U) {
                errno = EOVERFLOW;
                return -1;
            }
            parsed = parsed * 10U + digit;
            digits++;
            cursor++;
        }
        while (cursor < used &&
               (status[cursor] == ' ' ||
                status[cursor] == '\t' ||
                status[cursor] == '\r')) {
            cursor++;
        }
        if (digits == 0 || parsed == 0 ||
            (cursor < used && status[cursor] != '\n')) {
            errno = EPROTO;
            return -1;
        }
        *leader_id = (pid_t)parsed;
        return 0;
    }
    errno = EPROTO;
    return -1;
}

/*
 * Perform connect(2) through a duplicate of the tracee's exact socket, using
 * only a host-owned sockaddr synthesized from the frozen policy. The tracee's
 * pointer is inspected to reject bypass intent, but it is never passed to the
 * kernel for the actual connection. Consequently an already-queued kernel
 * writer, a shared mapping, or any other actor changing that pointer after
 * inspection cannot alter the destination that is reached.
 */
static int intatis_emulate_exact_connect(
    const intatis_mcp_stdio_guard_t *guard,
    pid_t pid,
    const intatis_syscall_snapshot_t *snapshot,
    long *emulated_result) {
#if defined(__NR_connect) && defined(__NR_pidfd_open) && \
    defined(__NR_pidfd_getfd)
    if (guard->network_policy.mode
            != INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY ||
        snapshot->syscall_number != __NR_connect ||
        snapshot->arguments[0] > (uint64_t)INT_MAX ||
        emulated_result == NULL) {
        errno = EINVAL;
        return -1;
    }

    /*
     * pidfd_open accepts a thread-group leader on the supported baseline.
     * The seccomp clone rule requires CLONE_FILES for CLONE_THREAD, so the
     * leader exposes the exact descriptor table of a calling thread.
     */
    pid_t leader_id = 0;
    if (intatis_thread_group_leader(pid, &leader_id) < 0) {
        return -1;
    }
    int pid_descriptor =
        (int)syscall(__NR_pidfd_open, leader_id, 0U);
    if (pid_descriptor < 0) {
        return -1;
    }
    int socket_descriptor =
        (int)syscall(
            __NR_pidfd_getfd,
            pid_descriptor,
            (int)snapshot->arguments[0],
            0U);
    int duplicate_error = errno;
    (void)close(pid_descriptor);
    if (socket_descriptor < 0) {
        errno = duplicate_error;
        return -1;
    }

    int socket_type = 0;
    socklen_t socket_type_length = sizeof(socket_type);
    struct sockaddr_storage local_address;
    socklen_t local_address_length = sizeof(local_address);
    memset(&local_address, 0, sizeof(local_address));
    if (getsockopt(
            socket_descriptor,
            SOL_SOCKET,
            SO_TYPE,
            &socket_type,
            &socket_type_length) < 0) {
        int saved = errno;
        (void)close(socket_descriptor);
        errno = saved;
        return -1;
    }
    if (socket_type_length != sizeof(socket_type) ||
        socket_type != SOCK_STREAM) {
        (void)close(socket_descriptor);
        errno = ENOTSOCK;
        return -1;
    }
    if (getsockname(
            socket_descriptor,
            (struct sockaddr *)&local_address,
            &local_address_length) < 0) {
        int saved = errno;
        (void)close(socket_descriptor);
        errno = saved;
        return -1;
    }
    if (local_address_length < sizeof(sa_family_t) ||
        local_address.ss_family != AF_INET) {
        (void)close(socket_descriptor);
        errno = ENOTSOCK;
        return -1;
    }

    int descriptor_flags =
        fcntl(socket_descriptor, F_GETFL);
    if (descriptor_flags < 0) {
        int saved = errno;
        (void)close(socket_descriptor);
        errno = saved;
        return -1;
    }
    int originally_nonblocking =
        (descriptor_flags & O_NONBLOCK) != 0;
    if (!originally_nonblocking &&
        fcntl(
            socket_descriptor,
            F_SETFL,
            descriptor_flags | O_NONBLOCK) < 0) {
        int saved = errno;
        (void)close(socket_descriptor);
        errno = saved;
        return -1;
    }

    struct sockaddr_in gateway;
    memset(&gateway, 0, sizeof(gateway));
    gateway.sin_family = AF_INET;
    gateway.sin_port = htons(
        guard->network_policy.gateway_port_host_order);
    gateway.sin_addr.s_addr =
        guard->network_policy.gateway_ipv4_network_order;

    long result_value = 0;
    int connect_result = connect(
        socket_descriptor,
        (const struct sockaddr *)&gateway,
        sizeof(gateway));
    int connect_error = errno;
    if (connect_result < 0 &&
        !originally_nonblocking &&
        (connect_error == EINPROGRESS ||
         connect_error == EALREADY)) {
        struct pollfd descriptor;
        descriptor.fd = socket_descriptor;
        descriptor.events = POLLOUT;
        descriptor.revents = 0;
        uint64_t start = intatis_monotonic_milliseconds();
        if (start == 0) {
            connect_error = EIO;
            goto connect_failure;
        }
        for (;;) {
            uint64_t now = intatis_monotonic_milliseconds();
            if (now == 0 ||
                now - start >=
                    INTATIS_NETWORK_SYSCALL_TIMEOUT_MILLISECONDS) {
                connect_error = ETIMEDOUT;
                goto connect_failure;
            }
            uint64_t remaining =
                INTATIS_NETWORK_SYSCALL_TIMEOUT_MILLISECONDS -
                (now - start);
            int timeout =
                remaining > (uint64_t)INT_MAX
                    ? INT_MAX
                    : (int)remaining;
            int poll_result = poll(&descriptor, 1, timeout);
            if (poll_result > 0) {
                int socket_error = 0;
                socklen_t socket_error_length =
                    sizeof(socket_error);
                if (getsockopt(
                        socket_descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socket_error,
                        &socket_error_length) < 0) {
                    connect_error = errno;
                    goto connect_failure;
                }
                if (socket_error_length != sizeof(socket_error)) {
                    connect_error = EIO;
                    goto connect_failure;
                }
                connect_result = socket_error == 0 ? 0 : -1;
                connect_error = socket_error;
                break;
            }
            if (poll_result == 0) {
                connect_error = ETIMEDOUT;
                goto connect_failure;
            }
            if (errno != EINTR) {
                connect_error = errno;
                goto connect_failure;
            }
        }
    }
    if (connect_result < 0) {
        if (connect_error <= 0 || connect_error > 4095) {
            connect_error = EIO;
        }
        result_value = -(long)connect_error;
    }

    if (!originally_nonblocking &&
        fcntl(
            socket_descriptor,
            F_SETFL,
            descriptor_flags) < 0) {
        connect_error = errno;
        goto connect_failure;
    }
    (void)close(socket_descriptor);
    *emulated_result = result_value;
    return 0;

connect_failure:
    if (!originally_nonblocking) {
        (void)fcntl(
            socket_descriptor,
            F_SETFL,
            descriptor_flags);
    }
    (void)close(socket_descriptor);
    errno = connect_error == 0 ? EIO : connect_error;
    return -1;
#else
    (void)guard;
    (void)pid;
    (void)snapshot;
    (void)emulated_result;
    errno = ENOTSUP;
    return -1;
#endif
}

static void intatis_mark_violation(
    intatis_mcp_stdio_guard_t *guard,
    int error_number) {
    if (!guard->violation) {
        guard->violation = 1;
        guard->fatal_errno = error_number;
    }
    (void)kill(-guard->group_id, SIGKILL);
    for (size_t index = 0; index < guard->tracee_count; index++) {
        if (guard->tracees[index].alive) {
            (void)ptrace(
                PTRACE_KILL,
                guard->tracees[index].pid,
                NULL,
                NULL);
        }
    }
}

static void intatis_mark_network_violation(
    intatis_mcp_stdio_guard_t *guard,
    int error_number) {
    guard->network_violation = 1;
    intatis_mark_violation(guard, error_number);
}

static int intatis_decode_exit_status(int status);
static int intatis_handle_exec_event(
    intatis_mcp_stdio_guard_t *guard,
    intatis_tracee_t *tracee);

static uint64_t intatis_monotonic_milliseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) < 0) {
        return 0;
    }
    return (uint64_t)value.tv_sec * 1000U +
           (uint64_t)value.tv_nsec / 1000000U;
}

static void intatis_poll_pause(void) {
    struct timespec value;
    value.tv_sec = 0;
    value.tv_nsec = 1000000L;
    while (nanosleep(&value, &value) < 0 && errno == EINTR) {
    }
}

static void intatis_record_tracee_exit(
    intatis_mcp_stdio_guard_t *guard,
    pid_t pid,
    int status) {
    intatis_tracee_t *tracee =
        intatis_find_tracee(guard, pid);
    if (tracee == NULL) {
        return;
    }
    tracee->alive = 0;
    tracee->frozen = 0;
    tracee->pending_status = 0;
    if (pid == guard->target_pid) {
        guard->target_exited = 1;
        guard->target_exit_status =
            intatis_decode_exit_status(status);
    }
}

static int intatis_all_live_tracees_frozen(
    const intatis_mcp_stdio_guard_t *guard) {
    for (size_t index = 0; index < guard->tracee_count; index++) {
        if (guard->tracees[index].alive &&
            !guard->tracees[index].frozen) {
            return 0;
        }
    }
    return 1;
}

static int intatis_capture_frozen_stop(
    intatis_mcp_stdio_guard_t *guard,
    pid_t pid,
    int status) {
    if (WIFEXITED(status) || WIFSIGNALED(status)) {
        intatis_record_tracee_exit(guard, pid, status);
        return 0;
    }
    if (!WIFSTOPPED(status)) {
        errno = EIO;
        return -1;
    }
    intatis_tracee_t *tracee =
        intatis_find_tracee(guard, pid);
    if (tracee == NULL) {
        errno = ECHILD;
        return -1;
    }
    tracee->frozen = 1;
    tracee->pending_status = status;

    unsigned int event = ((unsigned int)status) >> 16;
    if (event == PTRACE_EVENT_FORK ||
        event == PTRACE_EVENT_VFORK ||
        event == PTRACE_EVENT_CLONE) {
        unsigned long child_pid = 0;
        if (ptrace(
                PTRACE_GETEVENTMSG,
                pid,
                NULL,
                &child_pid) < 0 ||
            child_pid == 0 ||
            intatis_add_tracee(
                guard, (pid_t)child_pid, 0) < 0) {
            return -1;
        }
    }
    return 0;
}

/*
 * Advance exactly one validated network syscall while every other tracee
 * remains ptrace-stopped. connect(2) is performed first through the trusted
 * duplicate and the untrusted pointer-bearing syscall is replaced with -1;
 * all other admitted calls reach syscall-exit before any tracee resumes. The
 * calling thread cannot execute user code in this interval.
 */
static int intatis_execute_frozen_network_syscall(
    intatis_mcp_stdio_guard_t *guard,
    pid_t pid) {
    intatis_tracee_t *tracee =
        intatis_find_tracee(guard, pid);
    if (tracee == NULL || !tracee->alive || !tracee->frozen) {
        errno = ECHILD;
        return -1;
    }
    intatis_syscall_snapshot_t expected;
    memset(&expected, 0, sizeof(expected));
    if (intatis_read_syscall_snapshot(
            pid, &expected) < 0) {
        return -1;
    }
    long observed_syscall_number = expected.syscall_number;
    long emulated_result = 0;
    int has_emulated_result = 0;
#ifdef __NR_connect
    if (expected.syscall_number == __NR_connect) {
        if (intatis_emulate_exact_connect(
                guard,
                pid,
                &expected,
                &emulated_result) < 0 ||
            intatis_rewrite_syscall_number(pid, -1) < 0) {
            return -1;
        }
        observed_syscall_number = -1;
        has_emulated_result = 1;
    }
#endif
    tracee->frozen = 0;
    tracee->pending_status = 0;
    if (ptrace(PTRACE_SYSCALL, pid, NULL, NULL) < 0) {
        return -1;
    }

    uint64_t start = intatis_monotonic_milliseconds();
    if (start == 0) {
        errno = EIO;
        return -1;
    }
    unsigned int syscall_stops = 0;
    for (;;) {
        int status = 0;
        pid_t waited = waitpid(pid, &status, WNOHANG | __WALL);
        if (waited == pid) {
            if (WIFEXITED(status) || WIFSIGNALED(status)) {
                intatis_record_tracee_exit(
                    guard, pid, status);
                errno = EIO;
                return -1;
            }
            tracee = intatis_find_tracee(guard, pid);
            if (tracee == NULL || !WIFSTOPPED(status)) {
                errno = EIO;
                return -1;
            }
            tracee->frozen = 1;
            tracee->pending_status = status;
            if ((((unsigned int)status) >> 16) != 0 ||
                WSTOPSIG(status) != (SIGTRAP | 0x80)) {
                errno = EIO;
                return -1;
            }
            uint8_t operation = 0;
            intatis_syscall_snapshot_t observed;
            memset(&observed, 0, sizeof(observed));
            if (intatis_ptrace_syscall_operation(
                    pid, &operation) < 0 ||
                intatis_read_syscall_snapshot(
                    pid, &observed) < 0 ||
                observed.syscall_number
                    != observed_syscall_number) {
                return -1;
            }
            if (operation
                    == INTATIS_PTRACE_SYSCALL_INFO_EXIT) {
                if (has_emulated_result &&
                    intatis_rewrite_syscall_result(
                        pid, emulated_result) < 0) {
                    return -1;
                }
                return 0;
            }
            if ((operation
                    != INTATIS_PTRACE_SYSCALL_INFO_ENTRY &&
                 operation
                    != INTATIS_PTRACE_SYSCALL_INFO_SECCOMP) ||
                ++syscall_stops > 2) {
                errno = EIO;
                return -1;
            }
            /*
             * ENTRY/SECCOMP stops still precede kernel consumption. Continue
             * only this tracee under PTRACE_SYSCALL; no user instruction can
             * run before the corresponding EXIT stop.
             */
            tracee->frozen = 0;
            tracee->pending_status = 0;
            if (ptrace(
                    PTRACE_SYSCALL,
                    pid,
                    NULL,
                    NULL) < 0) {
                return -1;
            }
            continue;
        }
        if (waited < 0 && errno != EINTR) {
            return -1;
        }
        uint64_t now = intatis_monotonic_milliseconds();
        if (now == 0 || now - start
                >= INTATIS_NETWORK_SYSCALL_TIMEOUT_MILLISECONDS) {
            errno = ETIMEDOUT;
            return -1;
        }
        intatis_poll_pause();
    }
}

/*
 * Close the ptrace pointer-argument TOCTOU window.
 *
 * Every clone/fork child is automatically ptrace-attached and stopped before
 * it can execute because TRACECLONE/FORK/VFORK is active. INTERRUPT therefore
 * reaches every runnable writer in this generation. Only after every live
 * tracee is frozen do we inspect pointer arguments. connect(2) is emulated
 * from a host-owned exact sockaddr, while every other admitted syscall is
 * advanced alone to syscall-exit before any tracee resumes.
 */
static int intatis_freeze_validate_and_execute_network(
    intatis_mcp_stdio_guard_t *guard,
    pid_t triggering_pid,
    int triggering_status) {
    intatis_tracee_t *trigger =
        intatis_find_tracee(guard, triggering_pid);
    if (trigger == NULL || !trigger->alive) {
        intatis_mark_network_violation(guard, ECHILD);
        return -1;
    }
    trigger->frozen = 1;
    trigger->pending_status = triggering_status;

    for (size_t index = 0; index < guard->tracee_count; index++) {
        intatis_tracee_t *tracee = &guard->tracees[index];
        if (!tracee->alive || tracee->frozen) {
            continue;
        }
        if (ptrace(
                PTRACE_INTERRUPT,
                tracee->pid,
                NULL,
                NULL) < 0 &&
            errno != EIO && errno != ESRCH) {
            intatis_mark_network_violation(guard, errno);
            return -1;
        }
    }

    uint64_t start = intatis_monotonic_milliseconds();
    if (start == 0) {
        intatis_mark_network_violation(guard, EIO);
        return -1;
    }
    while (!intatis_all_live_tracees_frozen(guard)) {
        int made_progress = 0;
        size_t observed_count = guard->tracee_count;
        for (size_t index = 0; index < observed_count; index++) {
            intatis_tracee_t *tracee = &guard->tracees[index];
            if (!tracee->alive || tracee->frozen) {
                continue;
            }
            pid_t pid = tracee->pid;
            int status = 0;
            pid_t waited = waitpid(
                pid, &status, WNOHANG | __WALL);
            if (waited == 0 ||
                (waited < 0 && errno == EINTR)) {
                continue;
            }
            if (waited < 0 ||
                intatis_capture_frozen_stop(
                    guard, pid, status) < 0) {
                int saved = errno;
                intatis_mark_network_violation(
                    guard, saved == 0 ? EIO : saved);
                return -1;
            }
            made_progress = 1;
        }
        /*
         * A clone event can add a child after the first interrupt pass. The
         * child is already auto-attached/stopped; INTERRUPT returning EIO is
         * accepted, and its pending stop is collected below.
         */
        for (size_t index = observed_count;
             index < guard->tracee_count;
             index++) {
            intatis_tracee_t *tracee = &guard->tracees[index];
            if (tracee->alive && !tracee->frozen &&
                ptrace(
                    PTRACE_INTERRUPT,
                    tracee->pid,
                    NULL,
                    NULL) < 0 &&
                errno != EIO && errno != ESRCH) {
                intatis_mark_network_violation(guard, errno);
                return -1;
            }
        }
        if (!made_progress) {
            uint64_t now = intatis_monotonic_milliseconds();
            if (now == 0 || now - start
                    >= INTATIS_FREEZE_TIMEOUT_MILLISECONDS) {
                intatis_mark_network_violation(
                    guard, ETIMEDOUT);
                return -1;
            }
            intatis_poll_pause();
        }
    }

    /*
     * Enforce any concurrent exec events before allowing a network syscall.
     * No tracee is resumed here, so identity checks and memory inspection see
     * one stable generation state.
     */
    for (size_t index = 0; index < guard->tracee_count; index++) {
        intatis_tracee_t *tracee = &guard->tracees[index];
        if (!tracee->alive || !tracee->frozen) {
            continue;
        }
        unsigned int event =
            ((unsigned int)tracee->pending_status) >> 16;
        if (event == PTRACE_EVENT_EXEC &&
            intatis_handle_exec_event(guard, tracee) < 0) {
            intatis_mark_violation(guard, EACCES);
            return -1;
        }
    }

    for (size_t index = 0; index < guard->tracee_count; index++) {
        intatis_tracee_t *tracee = &guard->tracees[index];
        if (!tracee->alive || !tracee->frozen ||
            (((unsigned int)tracee->pending_status) >> 16)
                != PTRACE_EVENT_SECCOMP) {
            continue;
        }
        pid_t pid = tracee->pid;
        uint8_t operation = 0;
        if (intatis_ptrace_syscall_operation(
                pid, &operation) < 0 ||
            operation
                != INTATIS_PTRACE_SYSCALL_INFO_SECCOMP ||
            intatis_validate_network_syscall(
                guard, pid) < 0 ||
            intatis_execute_frozen_network_syscall(
                guard, pid) < 0) {
            int saved = errno;
            intatis_mark_network_violation(
                guard, saved == 0 ? EACCES : saved);
            return -1;
        }
    }

    /*
     * Every inspected network syscall is now at syscall-exit. connect(2) never
     * consumed the tracee pointer; other admitted calls completed while every
     * possible same-generation writer remained stopped.
     */
    for (size_t index = 0; index < guard->tracee_count; index++) {
        intatis_tracee_t *tracee = &guard->tracees[index];
        if (!tracee->alive || !tracee->frozen) {
            continue;
        }
        int status = tracee->pending_status;
        unsigned int event = ((unsigned int)status) >> 16;
        int stop_signal = WSTOPSIG(status);
        int delivered_signal =
            event != 0 ||
                    stop_signal == SIGTRAP ||
                    stop_signal == SIGSTOP ||
                    stop_signal == (SIGTRAP | 0x80)
                ? 0
                : stop_signal;
        tracee->frozen = 0;
        tracee->pending_status = 0;
        if (ptrace(
                PTRACE_CONT,
                tracee->pid,
                NULL,
                (void *)(intptr_t)delivered_signal) < 0 &&
            errno != ESRCH) {
            intatis_mark_network_violation(guard, errno);
            return -1;
        }
    }
    return 0;
}

static int intatis_all_tracees_exited(
    const intatis_mcp_stdio_guard_t *guard) {
    for (size_t index = 0; index < guard->tracee_count; index++) {
        if (guard->tracees[index].alive) {
            return 0;
        }
    }
    return 1;
}

static int intatis_decode_exit_status(int status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
}

static int intatis_handle_exec_event(
    intatis_mcp_stdio_guard_t *guard,
    intatis_tracee_t *tracee) {
    if (!guard->wrapper_seen) {
        if (!tracee->is_wrapper_root ||
            !intatis_identity_matches_pid(tracee->pid, &guard->wrapper)) {
            return -1;
        }
        guard->wrapper_seen = 1;
        return 0;
    }
    if (!guard->target_seen) {
        if (!intatis_identity_matches_pid(tracee->pid, &guard->primary)) {
            return -1;
        }
        guard->target_seen = 1;
        guard->target_pid = tracee->pid;
        tracee->may_exec_helper = guard->helper_count > 0;
        return 0;
    }
    if (!tracee->may_exec_helper ||
        tracee->helper_exec_seen ||
        !intatis_match_helper(guard, tracee->pid)) {
        return -1;
    }
    tracee->helper_exec_seen = 1;
    tracee->may_exec_helper = 0;
    return 0;
}

static void intatis_execution_guard_probe_child(void) {
    struct sock_filter filter[] = {
        BPF_STMT(
            BPF_LD | BPF_W | BPF_ABS,
            offsetof(struct intatis_seccomp_data, nr)),
        BPF_JUMP(
            BPF_JMP | BPF_JEQ | BPF_K,
            __NR_getpid,
            0,
            1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program;
    program.len = (uint16_t)(
        sizeof(filter) / sizeof(filter[0]));
    program.filter = filter;
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0 ||
        syscall(
            __NR_seccomp,
            SECCOMP_SET_MODE_FILTER,
            0,
            &program) < 0) {
        _exit(112);
    }
    long emulated = syscall(__NR_getpid);
    _exit(emulated == 4242 ? 0 : 113);
}

int intatis_mcp_stdio_execution_guard_probe(void) {
    int startup_pair[2] = {-1, -1};
    if (socketpair(
            AF_UNIX,
            SOCK_STREAM | SOCK_CLOEXEC,
            0,
            startup_pair) < 0) {
        return 0;
    }
    pid_t child = fork();
    if (child < 0) {
        intatis_close_fd(&startup_pair[0]);
        intatis_close_fd(&startup_pair[1]);
        return 0;
    }
    if (child == 0) {
        intatis_close_fd(&startup_pair[0]);
        if (intatis_read_handshake_byte(startup_pair[1]) < 0) {
            _exit(111);
        }
        intatis_close_fd(&startup_pair[1]);
        intatis_execution_guard_probe_child();
    }
    int child_startup_descriptor = startup_pair[1];
    intatis_close_fd(&startup_pair[1]);
    int status = 0;
    uint8_t operation = 0;
    int pid_descriptor = -1;
    int duplicated_descriptor = -1;
    int duplicated_type = 0;
    socklen_t duplicated_type_length = sizeof(duplicated_type);
    if (ptrace(
            PTRACE_SEIZE,
            child,
            NULL,
            (void *)(uintptr_t)(
                PTRACE_O_EXITKILL |
                PTRACE_O_TRACESYSGOOD |
                PTRACE_O_TRACESECCOMP)) < 0 ||
        ptrace(PTRACE_INTERRUPT, child, NULL, NULL) < 0 ||
        waitpid(child, &status, __WALL) != child ||
        !WIFSTOPPED(status) ||
        (((unsigned int)status) >> 16)
            != PTRACE_EVENT_STOP ||
        (pid_descriptor =
             (int)syscall(__NR_pidfd_open, child, 0U)) < 0 ||
        (duplicated_descriptor =
             (int)syscall(
                 __NR_pidfd_getfd,
                 pid_descriptor,
                 child_startup_descriptor,
                 0U)) < 0 ||
        getsockopt(
            duplicated_descriptor,
            SOL_SOCKET,
            SO_TYPE,
            &duplicated_type,
            &duplicated_type_length) < 0 ||
        duplicated_type_length != sizeof(duplicated_type) ||
        duplicated_type != SOCK_STREAM ||
        ptrace(PTRACE_CONT, child, NULL, NULL) < 0 ||
        intatis_write_handshake_byte(startup_pair[0]) < 0 ||
        waitpid(child, &status, __WALL) != child ||
        !WIFSTOPPED(status) ||
        (((unsigned int)status) >> 16)
            != PTRACE_EVENT_SECCOMP ||
        intatis_ptrace_syscall_operation(
            child, &operation) < 0 ||
        operation
            != INTATIS_PTRACE_SYSCALL_INFO_SECCOMP ||
        intatis_rewrite_syscall_number(child, -1) < 0 ||
        ptrace(PTRACE_SYSCALL, child, NULL, NULL) < 0 ||
        waitpid(child, &status, __WALL) != child ||
        !WIFSTOPPED(status) ||
        (((unsigned int)status) >> 16) != 0 ||
        WSTOPSIG(status) != (SIGTRAP | 0x80) ||
        intatis_ptrace_syscall_operation(
            child, &operation) < 0 ||
        operation
            != INTATIS_PTRACE_SYSCALL_INFO_EXIT ||
        intatis_rewrite_syscall_result(child, 4242) < 0 ||
        ptrace(PTRACE_CONT, child, NULL, NULL) < 0 ||
        waitpid(child, &status, __WALL) != child ||
        !WIFEXITED(status) ||
            WEXITSTATUS(status) != 0) {
        intatis_close_fd(&duplicated_descriptor);
        intatis_close_fd(&pid_descriptor);
        intatis_close_fd(&startup_pair[0]);
        (void)kill(child, SIGKILL);
        (void)waitpid(child, NULL, 0);
        return 0;
    }
    intatis_close_fd(&duplicated_descriptor);
    intatis_close_fd(&pid_descriptor);
    intatis_close_fd(&startup_pair[0]);
    return 1;
}

int intatis_mcp_stdio_guard_spawn(
    const char *wrapper_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    const char *runtime_directory,
    const intatis_mcp_stdio_exec_identity_t *primary,
    const intatis_mcp_stdio_exec_identity_t *helpers,
    size_t helper_count,
    const intatis_mcp_stdio_network_policy_t *network_policy,
    intatis_mcp_stdio_guard_spawn_result_t *result) {
    if (result == NULL) {
        return INTATIS_MCP_STDIO_GUARD_UNAVAILABLE;
    }
    memset(result, 0, sizeof(*result));
    result->process_id = -1;
    result->stdin_descriptor = -1;
    result->stdout_descriptor = -1;
    result->stderr_descriptor = -1;
    if (wrapper_path == NULL || argv == NULL || envp == NULL ||
        working_directory == NULL || runtime_directory == NULL ||
        primary == NULL || network_policy == NULL ||
        (network_policy->mode != INTATIS_MCP_STDIO_NETWORK_DENIED &&
         network_policy->mode
            != INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY) ||
        (network_policy->mode
            == INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY &&
         (network_policy->gateway_ipv4_network_order
                != htonl(INADDR_LOOPBACK) ||
          network_policy->gateway_port_host_order == 0)) ||
        (network_policy->mode
            == INTATIS_MCP_STDIO_NETWORK_DENIED &&
         (network_policy->gateway_ipv4_network_order != 0 ||
          network_policy->gateway_port_host_order != 0)) ||
        INTATIS_AUDIT_ARCH == 0) {
        result->error_number = EINVAL;
        return INTATIS_MCP_STDIO_GUARD_UNAVAILABLE;
    }

    int stdin_pipe[2] = {-1, -1};
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    if (intatis_pipe_cloexec(stdin_pipe) < 0 ||
        intatis_pipe_cloexec(stdout_pipe) < 0 ||
        intatis_pipe_cloexec(stderr_pipe) < 0) {
        result->error_number = errno;
        intatis_close_fd(&stdin_pipe[0]);
        intatis_close_fd(&stdin_pipe[1]);
        intatis_close_fd(&stdout_pipe[0]);
        intatis_close_fd(&stdout_pipe[1]);
        intatis_close_fd(&stderr_pipe[0]);
        intatis_close_fd(&stderr_pipe[1]);
        return INTATIS_MCP_STDIO_GUARD_PIPE_FAILED;
    }
    int seccomp_fd =
        intatis_make_seccomp_fd(runtime_directory, helper_count > 0);
    if (seccomp_fd < 0) {
        result->error_number = errno;
        intatis_close_fd(&stdin_pipe[0]);
        intatis_close_fd(&stdin_pipe[1]);
        intatis_close_fd(&stdout_pipe[0]);
        intatis_close_fd(&stdout_pipe[1]);
        intatis_close_fd(&stderr_pipe[0]);
        intatis_close_fd(&stderr_pipe[1]);
        return INTATIS_MCP_STDIO_GUARD_UNAVAILABLE;
    }

    intatis_mcp_stdio_guard_t *guard =
        (intatis_mcp_stdio_guard_t *)calloc(1, sizeof(*guard));
    if (guard == NULL ||
        intatis_capture_owned_identity(
            wrapper_path, &guard->wrapper) < 0 ||
        intatis_copy_identity(primary, &guard->primary) < 0) {
        result->error_number = errno;
        intatis_close_fd(&seccomp_fd);
        intatis_close_fd(&stdin_pipe[0]);
        intatis_close_fd(&stdin_pipe[1]);
        intatis_close_fd(&stdout_pipe[0]);
        intatis_close_fd(&stdout_pipe[1]);
        intatis_close_fd(&stderr_pipe[0]);
        intatis_close_fd(&stderr_pipe[1]);
        intatis_mcp_stdio_guard_destroy(guard);
        return INTATIS_MCP_STDIO_GUARD_IDENTITY_FAILED;
    }
    guard->network_policy = *network_policy;
    if (helper_count > 0) {
        guard->helpers = (intatis_owned_identity_t *)calloc(
            helper_count, sizeof(intatis_owned_identity_t));
        if (guard->helpers == NULL) {
            result->error_number = ENOMEM;
            intatis_close_fd(&seccomp_fd);
            intatis_close_fd(&stdin_pipe[0]);
            intatis_close_fd(&stdin_pipe[1]);
            intatis_close_fd(&stdout_pipe[0]);
            intatis_close_fd(&stdout_pipe[1]);
            intatis_close_fd(&stderr_pipe[0]);
            intatis_close_fd(&stderr_pipe[1]);
            intatis_mcp_stdio_guard_destroy(guard);
            return INTATIS_MCP_STDIO_GUARD_IDENTITY_FAILED;
        }
        guard->helper_count = helper_count;
        for (size_t index = 0; index < helper_count; index++) {
            if (intatis_copy_identity(
                    &helpers[index], &guard->helpers[index]) < 0) {
                result->error_number = errno;
                intatis_close_fd(&seccomp_fd);
                intatis_close_fd(&stdin_pipe[0]);
                intatis_close_fd(&stdin_pipe[1]);
                intatis_close_fd(&stdout_pipe[0]);
                intatis_close_fd(&stdout_pipe[1]);
                intatis_close_fd(&stderr_pipe[0]);
                intatis_close_fd(&stderr_pipe[1]);
                intatis_mcp_stdio_guard_destroy(guard);
                return INTATIS_MCP_STDIO_GUARD_IDENTITY_FAILED;
            }
        }
    }

    int startup_pair[2] = {-1, -1};
    if (socketpair(
            AF_UNIX,
            SOCK_STREAM | SOCK_CLOEXEC,
            0,
            startup_pair) < 0) {
        result->error_number = errno;
        intatis_close_fd(&seccomp_fd);
        intatis_close_fd(&stdin_pipe[0]);
        intatis_close_fd(&stdin_pipe[1]);
        intatis_close_fd(&stdout_pipe[0]);
        intatis_close_fd(&stdout_pipe[1]);
        intatis_close_fd(&stderr_pipe[0]);
        intatis_close_fd(&stderr_pipe[1]);
        intatis_mcp_stdio_guard_destroy(guard);
        return INTATIS_MCP_STDIO_GUARD_PIPE_FAILED;
    }

    pid_t child = fork();
    if (child < 0) {
        result->error_number = errno;
        intatis_close_fd(&startup_pair[0]);
        intatis_close_fd(&startup_pair[1]);
        intatis_close_fd(&seccomp_fd);
        intatis_close_fd(&stdin_pipe[0]);
        intatis_close_fd(&stdin_pipe[1]);
        intatis_close_fd(&stdout_pipe[0]);
        intatis_close_fd(&stdout_pipe[1]);
        intatis_close_fd(&stderr_pipe[0]);
        intatis_close_fd(&stderr_pipe[1]);
        intatis_mcp_stdio_guard_destroy(guard);
        return INTATIS_MCP_STDIO_GUARD_FORK_FAILED;
    }
    if (child == 0) {
        intatis_guarded_child(
            wrapper_path,
            argv,
            envp,
            working_directory,
            stdin_pipe[0],
            stdin_pipe[1],
            stdout_pipe[0],
            stdout_pipe[1],
            stderr_pipe[0],
            stderr_pipe[1],
            seccomp_fd,
            startup_pair[1],
            startup_pair[0]);
    }

    intatis_close_fd(&startup_pair[1]);
    intatis_close_fd(&seccomp_fd);
    intatis_close_fd(&stdin_pipe[0]);
    intatis_close_fd(&stdout_pipe[1]);
    intatis_close_fd(&stderr_pipe[1]);
    guard->group_id = child;
    guard->initial_pid = child;
    if (intatis_add_tracee(guard, child, 1) < 0) {
        result->error_number = ENOMEM;
        (void)kill(-child, SIGKILL);
        (void)kill(child, SIGKILL);
        (void)waitpid(child, NULL, 0);
        intatis_close_fd(&startup_pair[0]);
        intatis_close_fd(&stdin_pipe[1]);
        intatis_close_fd(&stdout_pipe[0]);
        intatis_close_fd(&stderr_pipe[0]);
        intatis_mcp_stdio_guard_destroy(guard);
        return INTATIS_MCP_STDIO_GUARD_TRACE_FAILED;
    }

    const unsigned long options =
        PTRACE_O_EXITKILL | PTRACE_O_TRACESYSGOOD |
        PTRACE_O_TRACEEXEC |
        PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK |
        PTRACE_O_TRACECLONE | PTRACE_O_TRACEEXIT |
        PTRACE_O_TRACESECCOMP;
    if (intatis_read_handshake_byte(startup_pair[0]) < 0 ||
        getpgid(child) != child ||
        ptrace(
            PTRACE_SEIZE,
            child,
            NULL,
            (void *)(uintptr_t)options) < 0 ||
        intatis_set_nonblocking(stdin_pipe[1]) < 0 ||
        intatis_set_nonblocking(stdout_pipe[0]) < 0 ||
        intatis_set_nonblocking(stderr_pipe[0]) < 0 ||
        intatis_write_handshake_byte(startup_pair[0]) < 0) {
        result->error_number = errno;
        (void)kill(-child, SIGKILL);
        (void)kill(child, SIGKILL);
        (void)waitpid(child, NULL, 0);
        intatis_close_fd(&startup_pair[0]);
        intatis_close_fd(&stdin_pipe[1]);
        intatis_close_fd(&stdout_pipe[0]);
        intatis_close_fd(&stderr_pipe[0]);
        intatis_mcp_stdio_guard_destroy(guard);
        return INTATIS_MCP_STDIO_GUARD_TRACE_FAILED;
    }
    intatis_close_fd(&startup_pair[0]);

    result->process_id = child;
    result->stdin_descriptor = stdin_pipe[1];
    result->stdout_descriptor = stdout_pipe[0];
    result->stderr_descriptor = stderr_pipe[0];
    result->guard = guard;
    return INTATIS_MCP_STDIO_GUARD_OK;
}

int intatis_mcp_stdio_guard_poll(
    intatis_mcp_stdio_guard_t *guard,
    intatis_mcp_stdio_guard_poll_result_t *result) {
    if (guard == NULL || result == NULL) {
        return INTATIS_MCP_STDIO_GUARD_UNAVAILABLE;
    }
    memset(result, 0, sizeof(*result));
    int made_progress;
    do {
        made_progress = 0;
        size_t observed_count = guard->tracee_count;
        for (size_t index = 0; index < observed_count; index++) {
            intatis_tracee_t *tracee = &guard->tracees[index];
            if (!tracee->alive) {
                continue;
            }
            int status = 0;
            pid_t waited = waitpid(
                tracee->pid, &status, WNOHANG | __WALL);
            if (waited == 0) {
                continue;
            }
            if (waited < 0) {
                if (errno == EINTR) {
                    continue;
                }
                if (errno == ECHILD) {
                    intatis_mark_violation(guard, ECHILD);
                    continue;
                }
                intatis_mark_violation(guard, errno);
                continue;
            }
            made_progress = 1;
            if (WIFEXITED(status) || WIFSIGNALED(status)) {
                intatis_record_tracee_exit(
                    guard, waited, status);
                continue;
            }
            if (!WIFSTOPPED(status)) {
                continue;
            }
            unsigned int event = ((unsigned int)status) >> 16;
            int stop_signal = WSTOPSIG(status);
            int resumed_by_network_freeze = 0;
            if (event == PTRACE_EVENT_EXEC) {
                if (intatis_handle_exec_event(guard, tracee) < 0) {
                    intatis_mark_violation(guard, EACCES);
                }
            } else if (event == PTRACE_EVENT_SECCOMP) {
                if (intatis_freeze_validate_and_execute_network(
                        guard, waited, status) == 0) {
                    resumed_by_network_freeze = 1;
                }
            } else if (
                event == PTRACE_EVENT_FORK ||
                event == PTRACE_EVENT_VFORK ||
                event == PTRACE_EVENT_CLONE) {
                unsigned long child_pid = 0;
                if (ptrace(
                        PTRACE_GETEVENTMSG,
                        waited,
                        NULL,
                        &child_pid) < 0 ||
                    child_pid == 0 ||
                    intatis_add_tracee(
                        guard, (pid_t)child_pid, 0) < 0) {
                    intatis_mark_violation(guard, errno);
                }
            }
            if (!guard->violation &&
                !resumed_by_network_freeze) {
                int delivered_signal =
                    (stop_signal == SIGTRAP ||
                     stop_signal == SIGSTOP)
                        ? 0
                        : stop_signal;
                if (ptrace(
                        PTRACE_CONT,
                        waited,
                        NULL,
                        (void *)(intptr_t)delivered_signal) < 0 &&
                    errno != ESRCH) {
                    intatis_mark_violation(guard, errno);
                }
            }
        }
    } while (made_progress && !guard->violation);

    if (!guard->target_seen &&
        intatis_all_tracees_exited(guard)) {
        guard->target_exited = 1;
        if (guard->target_exit_status == 0) {
            guard->target_exit_status = -1;
        }
    }

    result->target_seen = guard->target_seen;
    result->target_exited = guard->target_exited;
    result->target_exit_status = guard->target_exit_status;
    result->all_tracees_exited = intatis_all_tracees_exited(guard);
    result->violation = guard->violation;
    result->network_violation = guard->network_violation;
    result->error_number = guard->fatal_errno;
    return guard->violation
        ? INTATIS_MCP_STDIO_GUARD_POLICY_VIOLATION
        : INTATIS_MCP_STDIO_GUARD_OK;
}

void intatis_mcp_stdio_guard_destroy(
    intatis_mcp_stdio_guard_t *guard) {
    if (guard == NULL) {
        return;
    }
    if (guard->group_id > 0) {
        (void)kill(-guard->group_id, SIGKILL);
    }
    for (size_t index = 0; index < guard->tracee_count; index++) {
        if (guard->tracees[index].alive) {
            (void)ptrace(
                PTRACE_KILL,
                guard->tracees[index].pid,
                NULL,
                NULL);
        }
    }
    free(guard->wrapper.canonical_path);
    free(guard->primary.canonical_path);
    for (size_t index = 0; index < guard->helper_count; index++) {
        free(guard->helpers[index].canonical_path);
    }
    free(guard->helpers);
    free(guard->tracees);
    free(guard);
}

#else

#include <string.h>

int intatis_mcp_stdio_execution_guard_probe(void) {
    return 0;
}

int intatis_mcp_stdio_guard_spawn(
    const char *wrapper_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    const char *runtime_directory,
    const intatis_mcp_stdio_exec_identity_t *primary,
    const intatis_mcp_stdio_exec_identity_t *helpers,
    size_t helper_count,
    const intatis_mcp_stdio_network_policy_t *network_policy,
    intatis_mcp_stdio_guard_spawn_result_t *result) {
    (void)wrapper_path;
    (void)argv;
    (void)envp;
    (void)working_directory;
    (void)runtime_directory;
    (void)primary;
    (void)helpers;
    (void)helper_count;
    (void)network_policy;
    if (result != NULL) {
        memset(result, 0, sizeof(*result));
        result->process_id = -1;
        result->stdin_descriptor = -1;
        result->stdout_descriptor = -1;
        result->stderr_descriptor = -1;
    }
    return INTATIS_MCP_STDIO_GUARD_UNAVAILABLE;
}

int intatis_mcp_stdio_guard_poll(
    intatis_mcp_stdio_guard_t *guard,
    intatis_mcp_stdio_guard_poll_result_t *result) {
    (void)guard;
    if (result != NULL) {
        memset(result, 0, sizeof(*result));
    }
    return INTATIS_MCP_STDIO_GUARD_UNAVAILABLE;
}

void intatis_mcp_stdio_guard_destroy(
    intatis_mcp_stdio_guard_t *guard) {
    (void)guard;
}

#endif
