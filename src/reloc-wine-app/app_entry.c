/* The title's real entry point lives in this high-address PRX. The tiny eboot
 * loads this module and transfers control here. Keep module 0's RW data at
 * 0x7fff0000 mapped: libkernel reads it after release. Release only the eboot
 * segments in the low Windows image range immediately before guest startup. */
#include <orbis/libkernel.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

enum { MODULE_INFO_BYTES = 0x160, MAX_SEGMENTS = 4 };
#define RANGE_BASE ((uintptr_t)0x400000)
#define RANGE_END  ((uintptr_t)0x55c000)

typedef struct { const void *address; uint32_t size, protection; } Segment;
extern int main(int argc, char **argv);

static void say(const char *fmt, ...)
{
    char line[384];
    va_list args;
    va_start(args, fmt);
    vsnprintf(line, sizeof(line) - 2, fmt, args);
    va_end(args);
    size_t n = strlen(line);
    line[n++] = '\n';
    line[n] = 0;
    sceKernelDebugOutText(0, line);
}

static int eboot_segments(Segment out[MAX_SEGMENTS], uint32_t *count)
{
    uint8_t raw[MODULE_INFO_BYTES] __attribute__((aligned(16)));
    memset(raw, 0, sizeof(raw));
    *(uint64_t *)raw = sizeof(raw);
    int rc = sceKernelGetModuleInfo((OrbisKernelModule)0, (OrbisKernelModuleInfo *)raw);
    if (rc < 0) return rc;
    uint32_t n;
    memcpy(&n, raw + 0x148, sizeof(n));
    if (!n || n > MAX_SEGMENTS) return -1;
    for (uint32_t i = 0; i < n; ++i) {
        uint8_t *entry = raw + 0x108 + i * 16;
        uint64_t address;
        memcpy(&address, entry, 8);
        memcpy(&out[i].size, entry + 8, 4);
        memcpy(&out[i].protection, entry + 12, 4);
        out[i].address = (const void *)(uintptr_t)address;
        if (!address || !out[i].size) return -1;
    }
    *count = n;
    return 0;
}

__attribute__((visibility("default")))
int pw_relocated_wine_release_eboot(void)
{
    Segment segments[MAX_SEGMENTS];
    uint32_t count = 0;
    say("relocwine: releasing eboot low segments before guest start");
    if (eboot_segments(segments, &count)) {
        say("relocwine: cannot read eboot module info; stopping safely");
        return -1;
    }
    for (uint32_t i = 0; i < count; ++i) {
        uintptr_t base = (uintptr_t)segments[i].address;
        uintptr_t end = base + segments[i].size;
        if (base >= RANGE_END || end <= RANGE_BASE) continue;
        say("relocwine: unmapping eboot seg%u %p..%p size=0x%x", i,
            (void *)base, (void *)end, segments[i].size);
        int rc = sceKernelMunmap((void *)base, segments[i].size);
        say("relocwine: seg%u munmap rc=0x%x", i, rc);
        if (rc) {
            say("relocwine: release failed; stopping before Wine startup");
            return rc;
        }
    }
    say("relocwine: eboot released");
    return 0;
}

__attribute__((visibility("default"), noreturn))
void pw_relocated_wine_start(int argc, char **argv)
{
    say("relocwine: high-address PRX active; keeping eboot mapped through setup");
    (void)main(argc, argv);
    say("relocwine: Wine main returned; holding PRX instead of returning to eboot");
    for (;;) sceKernelUsleep(1000000);
}
