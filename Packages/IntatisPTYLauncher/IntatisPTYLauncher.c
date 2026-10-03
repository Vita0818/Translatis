#include "IntatisPTYLauncher.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_OSX
#include <sys/ioctl.h>
#include <util.h>

typedef struct {
    int32_t stage;
    int32_t error_number;
} IntatisPTYChildError;

static int intatis_set_cloexec(int descriptor) {
    int flags = fcntl(descriptor, F_GETFD);
    if (flags == -1) {
        return errno;
    }
    if (fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == -1) {
        return errno;
    }
    return 0;
}

static int intatis_maximum_descriptor(void) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 &&
        limit.rlim_cur != RLIM_INFINITY &&
        limit.rlim_cur <= INT_MAX) {
        return (int)limit.rlim_cur;
    }
    long value = sysconf(_SC_OPEN_MAX);
    if (value >= 4 && value <= INT_MAX) {
        return (int)value;
    }
    return 1048576;
}

static void intatis_report_child_error(
    int descriptor,
    int32_t stage,
    int32_t error_number,
    int exit_code) {
    IntatisPTYChildError payload = {
        .stage = stage,
        .error_number = error_number
    };
    const uint8_t *bytes = (const uint8_t *)&payload;
    size_t offset = 0;
    while (offset < sizeof(payload)) {
        ssize_t count = write(
            descriptor,
            bytes + offset,
            sizeof(payload) - offset);
        if (count > 0) {
            offset += (size_t)count;
        } else if (count == -1 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    _exit(exit_code);
}

static void intatis_reset_child_signals(void) {
    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    (void)sigprocmask(SIG_SETMASK, &empty_mask, NULL);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (int signal_number = 1; signal_number < NSIG; signal_number++) {
        if (signal_number == SIGKILL || signal_number == SIGSTOP) {
            continue;
        }
        (void)sigaction(signal_number, &action, NULL);
    }
}

static void intatis_kill_and_reap(pid_t pid) {
    (void)kill(-pid, SIGKILL);
    (void)kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {
    }
}

int32_t intatis_spawn_managed_pty(
    const char *executable_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    uint16_t rows,
    uint16_t columns,
    IntatisPTYSpawnResult *result) {
    if (executable_path == NULL ||
        argv == NULL ||
        envp == NULL ||
        working_directory == NULL ||
        result == NULL) {
        return EINVAL;
    }

    *result = (IntatisPTYSpawnResult){
        .pid = -1,
        .master_fd = -1,
        .error_stage = INTATIS_PTY_STAGE_PREPARE,
        .error_number = 0
    };

    int error_pipe[2] = {-1, -1};
    if (pipe(error_pipe) == -1) {
        return errno;
    }
    int pipe_error = intatis_set_cloexec(error_pipe[0]);
    if (pipe_error == 0) {
        pipe_error = intatis_set_cloexec(error_pipe[1]);
    }
    if (pipe_error != 0) {
        (void)close(error_pipe[0]);
        (void)close(error_pipe[1]);
        return pipe_error;
    }

    int maximum_descriptor = intatis_maximum_descriptor();
    int master_descriptor = -1;
    struct winsize window = {
        .ws_row = rows,
        .ws_col = columns,
        .ws_xpixel = 0,
        .ws_ypixel = 0
    };
    pid_t pid = forkpty(
        &master_descriptor,
        NULL,
        NULL,
        &window);
    if (pid == -1) {
        int launch_error = errno;
        (void)close(error_pipe[0]);
        (void)close(error_pipe[1]);
        return launch_error;
    }

    if (pid == 0) {
        (void)close(error_pipe[0]);
        int error_descriptor = error_pipe[1];
        if (error_descriptor != 3) {
            if (dup2(error_descriptor, 3) == -1) {
                intatis_report_child_error(
                    error_descriptor,
                    INTATIS_PTY_STAGE_PREPARE,
                    errno,
                    126);
            }
            (void)close(error_descriptor);
            error_descriptor = 3;
        }
        int cloexec_error = intatis_set_cloexec(error_descriptor);
        if (cloexec_error != 0) {
            intatis_report_child_error(
                error_descriptor,
                INTATIS_PTY_STAGE_PREPARE,
                cloexec_error,
                126);
        }

        intatis_reset_child_signals();
        for (int descriptor = 4;
             descriptor < maximum_descriptor;
             descriptor++) {
            (void)close(descriptor);
        }
        if (chdir(working_directory) == -1) {
            intatis_report_child_error(
                error_descriptor,
                INTATIS_PTY_STAGE_CHDIR,
                errno,
                126);
        }
        execve(executable_path, argv, envp);
        intatis_report_child_error(
            error_descriptor,
            INTATIS_PTY_STAGE_EXEC,
            errno,
            127);
    }

    (void)close(error_pipe[1]);
    IntatisPTYChildError child_error = {
        .stage = INTATIS_PTY_STAGE_NONE,
        .error_number = 0
    };
    uint8_t *bytes = (uint8_t *)&child_error;
    size_t offset = 0;
    while (offset < sizeof(child_error)) {
        ssize_t count = read(
            error_pipe[0],
            bytes + offset,
            sizeof(child_error) - offset);
        if (count > 0) {
            offset += (size_t)count;
        } else if (count == 0) {
            break;
        } else if (errno == EINTR) {
            continue;
        } else {
            int read_error = errno;
            (void)close(error_pipe[0]);
            (void)close(master_descriptor);
            intatis_kill_and_reap(pid);
            return read_error;
        }
    }
    (void)close(error_pipe[0]);

    if (offset != 0) {
        (void)close(master_descriptor);
        intatis_kill_and_reap(pid);
        result->error_stage = child_error.stage;
        result->error_number = child_error.error_number;
        return child_error.error_number != 0 ? child_error.error_number : EIO;
    }

    int master_error = intatis_set_cloexec(master_descriptor);
    if (master_error != 0) {
        (void)close(master_descriptor);
        intatis_kill_and_reap(pid);
        return master_error;
    }

    result->pid = pid;
    result->master_fd = master_descriptor;
    result->error_stage = INTATIS_PTY_STAGE_NONE;
    result->error_number = 0;
    return 0;
}

#else

int32_t intatis_spawn_managed_pty(
    const char *executable_path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    uint16_t rows,
    uint16_t columns,
    IntatisPTYSpawnResult *result) {
    (void)executable_path;
    (void)argv;
    (void)envp;
    (void)working_directory;
    (void)rows;
    (void)columns;
    if (result != NULL) {
        *result = (IntatisPTYSpawnResult){
            .pid = -1,
            .master_fd = -1,
            .error_stage = INTATIS_PTY_STAGE_PREPARE,
            .error_number = ENOTSUP
        };
    }
    return ENOTSUP;
}

#endif
