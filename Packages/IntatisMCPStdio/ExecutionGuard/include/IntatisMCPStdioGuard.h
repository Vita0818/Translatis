#ifndef INTATIS_MCP_STDIO_GUARD_H
#define INTATIS_MCP_STDIO_GUARD_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct intatis_mcp_stdio_guard intatis_mcp_stdio_guard_t;

typedef struct {
    const char *canonical_path;
    uint64_t device_id;
    uint64_t file_id;
    uint64_t byte_count;
} intatis_mcp_stdio_exec_identity_t;

typedef struct {
    int mode;
    uint32_t gateway_ipv4_network_order;
    uint16_t gateway_port_host_order;
} intatis_mcp_stdio_network_policy_t;

enum {
    INTATIS_MCP_STDIO_NETWORK_DENIED = 0,
    INTATIS_MCP_STDIO_NETWORK_EXACT_GATEWAY = 1
};

typedef struct {
    pid_t process_id;
    int stdin_descriptor;
    int stdout_descriptor;
    int stderr_descriptor;
    int error_number;
    intatis_mcp_stdio_guard_t *guard;
} intatis_mcp_stdio_guard_spawn_result_t;

typedef struct {
    int target_seen;
    int target_exited;
    int target_exit_status;
    int all_tracees_exited;
    int violation;
    int network_violation;
    int error_number;
} intatis_mcp_stdio_guard_poll_result_t;

enum {
    INTATIS_MCP_STDIO_GUARD_OK = 0,
    INTATIS_MCP_STDIO_GUARD_UNAVAILABLE = 1,
    INTATIS_MCP_STDIO_GUARD_PIPE_FAILED = 2,
    INTATIS_MCP_STDIO_GUARD_FORK_FAILED = 3,
    INTATIS_MCP_STDIO_GUARD_TRACE_FAILED = 4,
    INTATIS_MCP_STDIO_GUARD_IDENTITY_FAILED = 5,
    INTATIS_MCP_STDIO_GUARD_POLICY_VIOLATION = 6
};

/*
 * Performs a real SEIZE/INTERRUPT/EXITKILL/TRACESECCOMP probe, including
 * pidfd_getfd, PTRACE_GET_SYSCALL_INFO, syscall-number replacement, result
 * injection, and a proven syscall-exit stop. Returning success proves that
 * this host has every kernel primitive required by the guard.
 */
int intatis_mcp_stdio_execution_guard_probe(void);

/*
 * Forks only inside this C shim. The child performs async-signal-safe setup
 * and blocks on a private handshake until its parent has SEIZEd it with all
 * required options, then execs the already-vetted bwrap path. argv must
 * include "--seccomp 3"; fd 3 is installed by this function.
 */
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
    intatis_mcp_stdio_guard_spawn_result_t *result);

/*
 * Ptrace pump. Ordinary polling is non-blocking. An exact-network stop may
 * spend bounded time freezing all tracees. connect(2) is executed on a
 * pidfd-duplicated socket with a host-owned exact sockaddr; the tracee's
 * pointer-bearing syscall is skipped and receives the emulated result. This
 * makes post-validation pointer mutation unable to alter the actual peer.
 * Every tracee is continued only by this function. Successful exec stops are
 * checked before the new image executes user code.
 */
int intatis_mcp_stdio_guard_poll(
    intatis_mcp_stdio_guard_t *guard,
    intatis_mcp_stdio_guard_poll_result_t *result);

/*
 * Safety cleanup. The normal caller first TERM/KILLs and drains the exact
 * process group; destroy repeats KILL before releasing tracer state.
 */
void intatis_mcp_stdio_guard_destroy(
    intatis_mcp_stdio_guard_t *guard);

#ifdef __cplusplus
}
#endif

#endif
