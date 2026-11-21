/*
 * poweroff-hook.c — LD_PRELOAD hook for the stock AZ01 power-button daemon.
 *
 * /usr/bin/az01-pwrbtn (az01-power-button.service) imports libc reboot() and
 * calls it with RB_POWER_OFF when the GPIO power key is pressed. This library
 * is preloaded into that daemon (runtime systemd drop-in installed by
 * start-rb.sh) so the rbp session gets a graceful teardown first:
 *
 *   reboot(RB_POWER_OFF) -> /data/rbp-shutdown.sh -> real poweroff syscall
 *
 * The script must not call poweroff/reboot; the hook performs the real syscall
 * after the script returns. Build for the device with:
 *
 *   make -C scripts/device CROSS=arm-linux-gnueabihf- poweroff-hook.so
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdlib.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define SHUTDOWN_SCRIPT "/data/rbp-shutdown.sh"
#define GUARD_ENV       "RBP_SHUTDOWN_HOOK_ACTIVE"

/* <sys/reboot.h> defines RB_* but not the raw syscall magics. */
#ifndef LINUX_REBOOT_MAGIC1
#define LINUX_REBOOT_MAGIC1 0xfee1dead
#endif
#ifndef LINUX_REBOOT_MAGIC2
#define LINUX_REBOOT_MAGIC2 672274793
#endif

static void run_shutdown_script(void)
{
     pid_t pid;
     int status;

     /* Belt and braces: never recurse if a child somehow calls reboot again. */
     if (getenv(GUARD_ENV))
          return;
     setenv(GUARD_ENV, "1", 1);

     pid = fork();
     if (pid < 0)
          return;
     if (pid == 0) {
          /* The shell and its children must not preload this hook. */
          unsetenv("LD_PRELOAD");
          /* If the script wedges, still let the daemon power off. */
          alarm(20);
          execl("/bin/sh", "sh", SHUTDOWN_SCRIPT, (char *)NULL);
          _exit(127);
     }

     while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
          ;
}

int reboot(int howto)
{
     unsigned int how = (unsigned int)howto;

     if (how == RB_POWER_OFF || how == RB_HALT_SYSTEM || how == RB_AUTOBOOT)
          run_shutdown_script();

     return (int)syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                         (long)howto, (void *)0);
}
