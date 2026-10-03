#ifndef INTATIS_PTY_LAUNCHER_H
#define INTATIS_PTY_LAUNCHER_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    INTATIS_PTY_STAGE_NONE = 0,
    INTATIS_PTY_STAGE_PREPARE = 1,
    INTATIS_PTY_STAGE_CHDIR = 2,
    INTATIS_PTY_STAGE_EXEC = 3
};

typedef struct {
    pid_t pid;
    int32_t master_fd;
    int32_t error_stage;
    int32_t error_number;
} IntatisPTYSpawnResult;

/// Starts an isolated controlling-terminal process.
///
/// All allocation and argument preparation must happen before this function.
/// On macOS, the child performs only C/POSIX setup between `forkpty` and
/// `execve`. An internal CLOEXEC pipe reports setup or exec errors to the
/// parent without confusing them with the managed command's own exit status.
int32_t intatis_spawn_managed_pty(
    const char *executable_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    uint16_t rows,
    uint16_t columns,
    IntatisPTYSpawnResult *result);

#ifdef __cplusplus
}
#endif

#endif
