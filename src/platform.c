#include "platform.h"
#include <ghostty/vt.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static bool secure_random(void *userdata, uint8_t *buf, size_t len)
{
    (void)userdata;
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return false;
    while (len) {
        ssize_t n = read(fd, buf, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return false; }
        buf += n; len -= (size_t)n;
    }
    close(fd);
    return true;
}

void imac_core_init(void)
{
    fprintf(stderr,"libghostty-vt %s\n",ghostty_version());
    if (ghostty_sys_set(GHOSTTY_SYS_OPT_RANDOM_SECURE, (const void *)secure_random)
        != GHOSTTY_SUCCESS) {
        fputs("Failed to initialize terminal entropy source\n", stderr);
        exit(1);
    }
}
