/* SPDX-License-Identifier: LGPL-2.1-or-later */
#define _POSIX_C_SOURCE 200809L
#include "pw_external_storage_ps4.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define PW_GOLDHEN_MARKER "/external-storage.enabled"
enum { PW_USB_SLOTS = 8, PW_LINK_BYTES = 4096 };

/* GoldHEN Plugins SDK syscall-500 command-2 backup layout. */
struct goldhen_jailbreak_backup {
    uint32_t cr_uid, cr_ruid, cr_rgid, cr_groups;
    uint64_t cr_paid, cr_caps[2];
    void *cr_prison, *fd_cdir, *fd_jdir, *fd_rdir;
};

static struct goldhen_jailbreak_backup backup;
static PwExternalStorageLog logger;
static char configured_data_root[512];
static int active;

static void log_line(const char *line)
{
    if (logger) logger(line);
}

static long goldhen_command(uint64_t command, void *data, int *error)
{
    long result;
    unsigned char failed;
    __asm__ volatile("syscall\n\tsetc %1"
                     : "=a"(result), "=q"(failed)
                     : "a"(0L), "D"(500L), "S"(command), "d"(data)
                     : "rcx", "r8", "r9", "r10", "r11", "memory", "cc");
    *error = failed ? (int)result : 0;
    return failed ? -1 : result;
}

static long guarded_command(uint64_t command, void *data, int *error)
{
    struct sigaction ignore, previous;
    memset(&ignore, 0, sizeof(ignore));
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    const int changed = sigaction(SIGSYS, &ignore, &previous) == 0;
    const long result = goldhen_command(command, data, error);
    if (changed) (void)sigaction(SIGSYS, &previous, NULL);
    return result;
}

void pw_external_storage_set_log(PwExternalStorageLog log)
{
    logger = log;
}

int pw_external_storage_enable_if_requested(const char *data_root)
{
    char path[512], line[192];
    struct stat marker;
    int error = 0;
    if (active) return 1;
    if (!data_root || snprintf(path, sizeof(path), "%s%s", data_root, PW_GOLDHEN_MARKER) >= (int)sizeof(path)) {
        log_line("external storage: invalid marker path");
        return 0;
    }
    if (stat(path, &marker) != 0 || !S_ISREG(marker.st_mode)) return 0;
    if (snprintf(configured_data_root, sizeof(configured_data_root), "%s", data_root) >=
        (int)sizeof(configured_data_root)) {
        log_line("external storage: data root is too long");
        return 0;
    }

    memset(&backup, 0, sizeof(backup));
    const long result = guarded_command(2, &backup, &error);
    if (result || error) {
        snprintf(line, sizeof(line), "external storage: GoldHEN unavailable result=%ld errno=%d", result, error);
        log_line(line);
        return 0;
    }
    if (setuid((uid_t)backup.cr_uid) != 0) {
        const int setuid_error = errno;
        int restore_error = 0;
        const long restore = guarded_command(3, &backup, &restore_error);
        snprintf(line, sizeof(line), "external storage: uid restore failed errno=%d rollback=%ld/%d",
                 setuid_error, restore, restore_error);
        log_line(line);
        memset(&backup, 0, sizeof(backup));
        return 0;
    }
    active = 1;
    snprintf(line, sizeof(line), "external storage: enabled uid=%u", (unsigned)getuid());
    log_line(line);
    return 1;
}

static int mounted_usb(unsigned slot)
{
    char path[32];
    struct stat mnt, volume;
    if (slot >= PW_USB_SLOTS || stat("/mnt", &mnt) != 0) return 0;
    snprintf(path, sizeof(path), "/mnt/usb%u", slot);
    if (stat(path, &volume) != 0 || !S_ISDIR(volume.st_mode)) return 0;
    /* Different st_dev is the usual mount test. Some PS4 exFAT mounts report
     * /mnt's device number, but still expose uid -1 and 0777 permissions. */
    return volume.st_dev != mnt.st_dev ||
           ((volume.st_mode & (S_IWGRP | S_IWOTH)) == (S_IWGRP | S_IWOTH) &&
            volume.st_uid == (uid_t)-1);
}

static int keep_non_usb_link(const char *line, size_t length)
{
    return !(length >= 3 && line[1] == ':' && line[2] == '\t' && line[0] >= 'd' && line[0] <= 'k');
}

void pw_external_storage_prepare_prefix(const char *prefix)
{
    if (!active) return;
    char directory[1024], table[1080], temporary[1084], contents[PW_LINK_BYTES];
    size_t used = 0;
    if (!prefix || !*prefix || snprintf(directory, sizeof(directory), "%s/dosdevices", prefix) >= (int)sizeof(directory) ||
        snprintf(table, sizeof(table), "%s/.pw-symlinks", directory) >= (int)sizeof(table) ||
        snprintf(temporary, sizeof(temporary), "%s.tmp", table) >= (int)sizeof(temporary)) {
        log_line("external storage: invalid prefix path");
        return;
    }
    struct stat info;
    if (stat(directory, &info) != 0 && mkdir(directory, 0777) != 0 && errno != EEXIST) {
        log_line("external storage: cannot create prefix dosdevices");
        return;
    }

    errno = 0;
    FILE *input = fopen(table, "rb");
    if (input) {
        while (used + 1 < sizeof(contents)) {
            if (!fgets(contents + used, (int)(sizeof(contents) - used), input)) break;
            size_t length = strlen(contents + used);
            if (length && keep_non_usb_link(contents + used, length)) used += length;
            else contents[used] = '\0';
        }
        const int read_error = ferror(input);
        fclose(input);
        if (read_error) {
            log_line("external storage: cannot read prefix drive link table");
            return;
        }
    } else if (errno != ENOENT) {
        log_line("external storage: cannot open prefix drive link table");
        return;
    }
    unsigned mask = 0;
    for (unsigned slot = 0; active && slot < PW_USB_SLOTS; ++slot) {
        if (!mounted_usb(slot)) continue;
        int count = snprintf(contents + used, sizeof(contents) - used, "%c:\t/mnt/usb%u\n", 'd' + slot, slot);
        if (count < 0 || (size_t)count >= sizeof(contents) - used) {
            log_line("external storage: drive link table is full");
            return;
        }
        used += (size_t)count;
        mask |= 1u << slot;
    }
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        log_line("external storage: cannot create drive link table");
        return;
    }
    size_t written = 0;
    while (written < used) {
        ssize_t count = write(fd, contents + written, used - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        written += (size_t)count;
    }
    int ok = written == used && fsync(fd) == 0;
    if (close(fd) != 0) ok = 0;
    if (ok && rename(temporary, table) == 0) {
        char line[160];
        snprintf(line, sizeof(line), "external storage: prefix drive table refreshed mask=%02x",
                 mask);
        log_line(line);
    } else {
        unlink(temporary);
        log_line("external storage: drive link table write failed");
    }
}

void pw_external_storage_restore(const char *reason)
{
    if (!active) return;
    int error = 0;
    const long result = guarded_command(3, &backup, &error);
    char line[160];
    snprintf(line, sizeof(line), "external storage: restored reason=%s result=%ld errno=%d",
             reason ? reason : "unspecified", result, error);
    log_line(line);
    active = 0;
    memset(&backup, 0, sizeof(backup));
}

int pw_external_storage_restore_for_loadexec(void)
{
    const int was_enabled = active;
    if (was_enabled) pw_external_storage_restore("loadexec");
    return was_enabled;
}

void pw_external_storage_resume_after_failed_loadexec(int was_enabled)
{
    if (was_enabled && configured_data_root[0])
        (void)pw_external_storage_enable_if_requested(configured_data_root);
}
