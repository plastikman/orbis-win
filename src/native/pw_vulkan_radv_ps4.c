/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* libvulkan.prx's entry points on PS4.
 *
 * win32u reaches Vulkan by dlopen(SONAME_LIBVULKAN) -- "libvulkan.so" -- and
 * pw_wine_dl turns that into libvulkan.prx (pw_wine_dl.c:52). It then looks up
 * vkGetInstanceProcAddr and vkGetDeviceProcAddr. Mesa's archive exports
 * neither: it exports the ICD's door, vk_icdGetInstanceProcAddr, and the
 * common device dispatch, exactly as the bundle's vkloader documents. So this
 * file is the same two-symbol shim, which is all a loader on this console can
 * be -- there is no libvulkan.so to find and no icd.d to read.
 *
 * ⚠ This is the PS4 arm of wine/ps5/pw_vulkan_radv.c, not a copy of it. That
 * one also bridges presentation to PS5_Mesa's WSI. This PS4 build carries
 * stock Mesa WSI instead. The pw_videoout_cursor export below is the narrow
 * bridge Wine needs: it forwards a transient cursor image into PS4 WSI, where
 * the image is copied and composited into the next scan-out frame. */
#include <vulkan/vulkan_core.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/stat.h>
#include <stdio.h>      /* snprintf, for the stack-size note below */

extern int wsi_orbis_cursor_update(const uint32_t *argb, uint32_t width, uint32_t height,
                                  int32_t x, int32_t y, uint32_t screen_width, uint32_t screen_height);

__attribute__((visibility("default")))
int pw_videoout_cursor(const uint32_t *argb, uint32_t width, uint32_t height,
                       int32_t x, int32_t y, uint32_t screen_width, uint32_t screen_height)
{
    return wsi_orbis_cursor_update(argb, width, height, x, y, screen_width, screen_height);
}

/* ⚠ THE TITLE'S FRAMES WHILE NO SWAPCHAIN PRESENTS, with upstream's signatures (wine/ps5/pw_vulkan_radv.c). Once a
 * game has a Vulkan surface the display is RADV's; the title then shows its GDI frames, movies and loading spinner
 * through these, and without them it found none ("vulkan frames idle=0 show=0") and those frames were dropped:
 * a WON Half-Life menu stayed black (2026-11-05). wsi_orbis keeps two linear A8R8G8B8 buffers of its own for them
 * (Mesa patch 0038). */
extern _Bool wsi_orbis_idle(void);
extern void *wsi_orbis_title_frame_begin(int *status);
extern int wsi_orbis_title_frame_flip(void);
extern int wsi_orbis_quiesce(unsigned timeout_ms, unsigned *waited_ms, int *pending_last);

/* 1 when a frame given to pw_videoout_show_tiled would show: no swapchain is presenting. */
__attribute__((visibility("default")))
int pw_videoout_idle(void)
{
    return wsi_orbis_idle() ? 1 : 0;
}

/* ⚠ "TILED" IN NAME ONLY ON PS4. Upstream's title draws the PS5's VideoOut tiling here, but on this console its
 * pw_videoout_ps5_draw_scaled is src/native/pw_platform_bind_ps4.c's, which draws the frame LINEAR in B8G8R8A8
 * order at a 1920 x 4 byte stride, because this scan-out is linear. Untiling it scrambled the WON Half-Life menu
 * into tiles (2026-11-05); the frame is copied as it is. 0 shown, 1 a swapchain is presenting, <0 failed. */
enum { PW_TITLE_WIDTH = 1920, PW_TITLE_HEIGHT = 1080 };

__attribute__((visibility("default")))
int pw_videoout_show_tiled(const void *tiled, uint64_t bytes, uint32_t width, uint32_t height)
{
    int status = -1;

    if (tiled == NULL || width != PW_TITLE_WIDTH || height != PW_TITLE_HEIGHT ||
        bytes < (uint64_t)width * height * 4u)
        return -1;
    uint32_t *out = wsi_orbis_title_frame_begin(&status);
    if (out == NULL)
        return status;
    memcpy(out, tiled, (size_t)width * height * 4u);
    return wsi_orbis_title_frame_flip();
}

/* Lock-free drain of RADV's pending flips at exit: 1 no output open, 0 drained, -1 timed out. */
__attribute__((visibility("default")))
int pw_videoout_quiesce(unsigned timeout_ms, unsigned *waited_ms, int *pending_last)
{
    return wsi_orbis_quiesce(timeout_ms, waited_ms, pending_last);
}

PFN_vkVoidFunction VKAPI_CALL vk_icdGetInstanceProcAddr(VkInstance instance, const char *name);
PFN_vkVoidFunction VKAPI_CALL vk_common_GetDeviceProcAddr(VkDevice device, const char *name);

/* Defined at the end of this file, next to the reasoning for it. */
static void pw_radv_load_env(void);

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name)
{
    /* Before RADV can read a single one of them: this is the first entry point
     * anything calls, and vkCreateInstance -- where the driver reads its
     * environment -- comes through it. */
    pw_radv_load_env();
    return vk_icdGetInstanceProcAddr(instance, name);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice device, const char *name)
{
    return vk_common_GetDeviceProcAddr(device, name);
}

/* ⚠ strdup(NULL). RADV calls it during initialisation and this console's libc
 * reads the argument with no check, so the process takes a fault at address 0
 * inside libSceLibcInternal and the driver never reports what it was missing:
 *
 *     syscall fault 0xc0000005 at libSceLibcInternal.sprx+0x4fa4d, address 0
 *       called from libvulkan.prx+0x1677e7f   -> strdup+0xf
 *
 * A NULL here means something RADV expected to be a string was not -- a device
 * name, a path, an environment value -- and on this console environ is its own
 * problem (docs/FINDINGS.md: setenv succeeds but never publishes it, and only
 * ntdll links pw_prx_env_ps4.o). Answer NULL as a sane libc would, and say so
 * once, so the next thing RADV reports is the missing value rather than a
 * fault with no name on it.
 *
 * strdup is already defined strongly in this link -- the driver archive comes
 * in whole -- so this goes through --wrap, the same way the cwd layer takes
 * over its 28 calls, rather than trying to replace the definition. */


char *__wrap_strdup(const char *text)
{
    extern int sceKernelDebugOutText(int channel, const char *line);
    static int reported;

    if (!text) {
        if (reported < 4) {
            reported++;
            sceKernelDebugOutText(0, "libvulkan: strdup(NULL) refused\n");
        }
        return NULL;
    }
    size_t bytes = strlen(text) + 1;
    char *copy = malloc(bytes);
    if (copy) memcpy(copy, text, bytes);
    return copy;
}

/* ⚠ A valid, empty environ. The SDK ships libc only as a static archive, so
 * every PRX carries a private environment, and this console's setenv reports
 * success while never publishing it: environ stays NULL however many variables
 * are set. ntdll answers that by linking pw_prx_env_ps4.o and pointing environ
 * at its own list; nothing did it for this module.
 *
 * Mesa walks it. driParseConfigFiles reads driconf from the environment, and
 * walked straight into the NULL:
 *
 *     syscall fault 0xc0000005 at libSceLibcInternal.sprx+0xbb8af, address 0
 *       called from libvulkan.prx+0x13fa674  -> driParseConfigFiles+0xb24
 *
 * which is the same shape the ntdll note records for get_initial_environment.
 * An empty list is the honest value -- there are no variables here to read --
 * and it terminates on the first entry instead of faulting. The init array runs
 * from module_start, so this is in place before any entry point is called. */
extern char **environ;
extern char *program_invocation_short_name;
extern char *program_invocation_name;
static char *pw_empty_environ[1] = { NULL };

__attribute__((constructor)) static void pw_publish_environ(void)
{
    extern int sceKernelDebugOutText(int channel, const char *line);

    if (!environ) {
        environ = pw_empty_environ;
        sceKernelDebugOutText(0, "libvulkan: environ was NULL, published an empty one\n");
    }

    /* ⚠ And the process name, which is the NULL driconf actually met. Mesa's
     * util_get_process_name() returns program_invocation_short_name, a glibc
     * convention: the symbol exists here as a weak object the static libc
     * carries, but nothing on this console ever sets it, so it is NULL. That
     * NULL reaches driParseConfigFiles as the application name and is strdup'd
     * on the way -- which is why the strdup guard fired and the fault stayed in
     * driconf after environ turned out to be fine:
     *
     *     libvulkan: strdup(NULL) refused
     *     syscall fault ... at libSceLibcInternal.sprx+0xbb8af, address 0
     *       called from libvulkan.prx+0x13fa734  -> driParseConfigFiles+0xbe4
     *
     * A constant is the honest answer: driconf uses the name only to match
     * per-application workarounds, and there are none for a title that reports
     * itself as this. Both symbols are writable data in the module. */
    if (!program_invocation_short_name) {
        program_invocation_short_name = (char *)"prospero-win";
        sceKernelDebugOutText(0, "libvulkan: process name was NULL, set to prospero-win\n");
    }
    if (!program_invocation_name) program_invocation_name = program_invocation_short_name;
}

/* ⚠ General-dynamic TLS, which this console answers with NULL.
 *
 * RADV imports __tls_get_addr; the one it links returns NULL, and ACO uses
 * thread_local, so a field is read off that NULL and the driver dies the
 * moment DXVK asks it to compile anything:
 *
 *     err:vulkan:vkCreateComputePipelines Exception 0xc0000005 in Unix call.
 *     syscall fault 0xc0000005 at libvulkan.so+0x12f0f29, address 1120
 *       -> aco_compile_shader + 0x2e9
 *
 * docs/FINDINGS.md measured the same thing before: general-dynamic TLS answers
 * NULL here, which is why wowprospero is built -femulated-tls with its own
 * __emutls_get_address. RADV arrives as a prebuilt archive and cannot be
 * recompiled that way without rebuilding Mesa, so give it a __tls_get_addr
 * that works instead.
 *
 * ⚠ A zeroed block is not an approximation here, it is exact. This module's
 * PT_TLS is
 *
 *     TLS  filesz 0x000000  memsz 0x001130    .tbss only, NOBITS
 *
 * -- no .tdata at all, so every thread-local it has starts as zero and there
 * is no initialiser image to copy. 0x1130 bytes also covers the 0x1120 the
 * fault was reading. The block is rounded up and bounds-checked, so an offset
 * past the end reports itself rather than becoming a silent corruption.
 *
 * Through --wrap: the definition it links now comes from an archive member
 * that is pulled in for its neighbours, so replacing it outright collides. */
#define PW_TLS_BLOCK_BYTES 0x2000u

struct pw_tls_index { unsigned long module, offset; };

static pthread_key_t pw_tls_key;
static pthread_once_t pw_tls_once = PTHREAD_ONCE_INIT;
static int pw_tls_ready;

static void pw_tls_free(void *block) { free(block); }

static void pw_tls_create_key(void)
{
    pw_tls_ready = pthread_key_create(&pw_tls_key, pw_tls_free) == 0;
}

void *__wrap___tls_get_addr(struct pw_tls_index *index)
{
    extern int sceKernelDebugOutText(int channel, const char *line);
    static int reported;
    unsigned char *block;

    pthread_once(&pw_tls_once, pw_tls_create_key);
    if (!pw_tls_ready || !index) return NULL;
    if (index->offset >= PW_TLS_BLOCK_BYTES) {
        if (reported < 4) {
            reported++;
            sceKernelDebugOutText(0, "libvulkan: TLS offset past the block\n");
        }
        return NULL;
    }
    if (!(block = pthread_getspecific(pw_tls_key))) {
        if (!(block = calloc(1, PW_TLS_BLOCK_BYTES))) return NULL;
        if (pthread_setspecific(pw_tls_key, block)) { free(block); return NULL; }
    }
    return block + index->offset;
}

/* ⚠ A thread created without a stack size costs 16 MiB of flexible memory.
 *
 * GTA IV cannot start a thread after about a dozen, and the reason is not
 * threads: flexible memory is gone. At the moment pthread_create is refused
 * there are 3072 KiB left of 449536, and the regions holding it are these --
 *
 *     flexible_holder rank=1 bytes=378880K count=24 prot=0x3 name=orbis
 *     flexible_region rank=2 at=7d7bb0000 bytes=16384K prot=0x3 name=orbis
 *     flexible_region rank=3 at=7d8bb0000 bytes=16384K prot=0x3 name=orbis
 *     ...
 *
 * twenty-four contiguous 16 MiB mappings, 370 MiB of the 461 MiB this process
 * has mapped. src/thread-probe had already measured what a 16 MiB region is:
 * its trial C, threads taking the library's own stack, managed 28 before
 * flexible memory hit zero -- about 16 MiB each. These are thread stacks.
 *
 * Mesa starts its worker threads through scePthreadCreate (u_thread_create),
 * and where the attribute is NULL this console gives each one a 16 MiB stack.
 * Wine's own threads escape it only because spawn_thread hands over a stack of
 * its own.
 *
 * So supply the size Mesa does not. 4 MiB: generous for what these threads do
 * -- ACO and NIR, which recurse over a shader's control flow and not much else
 * -- and a quarter of what Linux hands a default thread, where the same code
 * runs. Twenty-four of them cost 96 MiB instead of 384 MiB. If a compile
 * thread ever faults deep in a pass, this is the number to raise first.
 *
 * ⚠ Only threads that asked for nothing, or for more than this, are changed. A
 * caller that chose its own smaller stack keeps it. */
enum { PW_RADV_THREAD_STACK = 4u << 20 };

int scePthreadAttrInit(pthread_attr_t *attr);
int scePthreadAttrDestroy(pthread_attr_t *attr);
int scePthreadAttrSetstacksize(pthread_attr_t *attr, size_t size);
int scePthreadAttrGetstacksize(const pthread_attr_t *attr, size_t *size);
int scePthreadAttrGetdetachstate(const pthread_attr_t *attr, int *state);
int scePthreadAttrSetdetachstate(pthread_attr_t *attr, int state);
int sceKernelDebugOutText(int channel, const char *text);

int __real_scePthreadCreate(pthread_t *thread, const pthread_attr_t *attr,
                            void *(*entry)(void *), void *arg, const char *name);

int __wrap_scePthreadCreate(pthread_t *thread, const pthread_attr_t *attr,
                            void *(*entry)(void *), void *arg, const char *name)
{
    static unsigned adjusted;
    pthread_attr_t local;
    size_t size = 0;
    int detach = 0, rc;

    if (attr && !scePthreadAttrGetstacksize(attr, &size) && size && size <= PW_RADV_THREAD_STACK)
        return __real_scePthreadCreate(thread, attr, entry, arg, name);
    if (scePthreadAttrInit(&local))
        return __real_scePthreadCreate(thread, attr, entry, arg, name);
    if (attr && !scePthreadAttrGetdetachstate(attr, &detach))
        scePthreadAttrSetdetachstate(&local, detach);
    scePthreadAttrSetstacksize(&local, PW_RADV_THREAD_STACK);
    rc = __real_scePthreadCreate(thread, &local, entry, arg, name);
    scePthreadAttrDestroy(&local);

    /* The first few, so a run says whether this module owns those twenty-four
     * mappings or only some of them. ⚠ Whether this channel carries from a PRX
     * is not certain -- it does from wineserver and does not from wowprospero
     * -- but the flexible-memory figures in the title's log answer the same
     * question without it. */
    if (adjusted++ < 8) {
        char line[160];

        snprintf(line, sizeof(line),
                 "radv: thread %u \"%s\" asked %zuK, given %uK\n",
                 adjusted, name ? name : "-", size >> 10, PW_RADV_THREAD_STACK >> 10);
        sceKernelDebugOutText(0, line);
    }
    return rc;
}

/* ⚠ RADV's own switches have never been reachable on this console.
 *
 * mesa-ps4 is full of them -- ORBIS_TESS_WORKGROUPS to resize the tessellation
 * ring, ORBIS_HS_OFFCHIP_PER_SE to re-arm the per-shader-engine reading,
 * ORBIS_TESS_RING_WATERMARK to measure the ring's high-water mark, which is how
 * the 256-workgroup figure in ac_gpu_info.c was arrived at in the first place.
 * Every one of them is a getenv, and this module imports getenv but has no
 * environment to read: the SDK ships libc as a static archive, so each PRX
 * carries a private one, and src/native/pw_prx_env_ps4.c exists because this
 * console's setenv reports success while leaving environ NULL.
 *
 * So the driver's instrumentation has been switched off the whole time, and
 * the comment in ac_gpu_info.c offering ORBIS_HS_OFFCHIP_PER_SE=1 "if the
 * factor-ring candidate is eliminated" describes a knob nobody here could
 * turn.
 *
 * Give this module an environment of its own, out of a file, so those knobs
 * work. pw_ps4_setenv writes into this PRX's environment and publishes it, and
 * because RADV is linked into this same PRX its getenv reads exactly that.
 *
 * RADV's messages normally go to stderr, which the console doesn't capture for
 * this PRX. Give the next diagnostic run a retrievable log by default, then
 * let radv.env in the title's data folder (pw_radv_data_root) override either
 * value. The runtime config is
 * loaded after these defaults, before Mesa's first option lookup:
 *
 *     MESA_LOG_FILE=<data folder>/radv.log
 *     MESA_LOG_LEVEL=info
 *
 * ⚠ A file rather than the title's environment on purpose. Nothing can hand a
 * variable across to a private environment, and a file is also the pattern the
 * rest of this port already uses for switches it cannot pass (pw_wow_profile,
 * pw_sched, pw_image_view_fd_release). */
int pw_ps4_setenv(const char *name, const char *value);

/* The running title's data folder: /data/<TITLE_ID> when the title keeps one
 * (Playden: /data/PLDN10001), else orbis-win's /data/prospero-win. The title
 * ID is read from the package's own param.sfo, so the same driver serves
 * every title that ships it. */
int32_t sceKernelGetAppInfo(int pid, void *info);
int getpid(void);

/* /data/<title> if it is a folder, else leaves root as it is. */
static void pw_radv_use_title(const char *title, char *root, size_t capacity)
{
    struct stat info;
    char path[64];

    for (const char *c = title; *c; c++)
        if (!((*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9'))) return;
    if (!*title) return;
    snprintf(path, sizeof(path), "/data/%s", title);
    if (stat(path, &info) == 0 && S_ISDIR(info.st_mode)) snprintf(root, capacity, "%s", path);
}

static void pw_radv_data_root(char *root, size_t capacity)
{
    unsigned char sfo[4096], app[0x100];
    struct stat info;
    size_t length = 0;
    FILE *file;

    snprintf(root, capacity, "/data/prospero-win");
    /* The kernel's record of this app first (OrbisAppInfo: TitleId[10] at
     * 0x10): a PS4 title could not open its param.sfo (01.60). The runtime
     * (fork src/pw_title.h, wine64_main.c) picks its folder the same way. */
    memset(app, 0, sizeof(app));
    if (sceKernelGetAppInfo(getpid(), app) == 0 && app[0x10]) {
        char title[11];
        memcpy(title, app + 0x10, 10);
        title[10] = 0;
        pw_radv_use_title(title, root, capacity);
        return;
    }
    if (!(file = fopen("/app0/sce_sys/param.sfo", "rb"))) return;
    length = fread(sfo, 1, sizeof(sfo), file);
    fclose(file);
    /* PSF: magic "\0PSF", key table at 0x08, data table at 0x0c, entry count
     * at 0x10, then 16-byte entries (key offset u16, format u16, length u32,
     * max u32, data offset u32). */
    if (length < 20 || memcmp(sfo, "\0PSF", 4)) return;
    uint32_t keys, data, count;
    memcpy(&keys, sfo + 8, 4);
    memcpy(&data, sfo + 12, 4);
    memcpy(&count, sfo + 16, 4);
    for (uint32_t i = 0; i < count && 20 + (i + 1) * 16 <= length; i++) {
        const unsigned char *entry = sfo + 20 + i * 16;
        uint16_t key;
        uint32_t size, offset;
        char title[16], path[64];

        memcpy(&key, entry, 2);
        memcpy(&size, entry + 4, 4);
        memcpy(&offset, entry + 12, 4);
        if (keys + key + 9 > length || memcmp(sfo + keys + key, "TITLE_ID", 9)) continue;
        if (size < 2 || size > sizeof(title) || data + offset + size > length) return;
        memcpy(title, sfo + data + offset, size);
        title[size - 1] = 0;
        for (const char *c = title; *c; c++)
            if (!((*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9'))) return;
        snprintf(path, sizeof(path), "/data/%s", title);
        if (stat(path, &info) == 0 && S_ISDIR(info.st_mode)) snprintf(root, capacity, "%s", path);
        return;
    }
}

static void pw_radv_load_env(void)
{
    static int loaded;
    char line[256], root[64], path[96];
    FILE *file;

    if (loaded++) return;
    pw_radv_data_root(root, sizeof(root));
    /* Mesa's default logger sends PRX stderr to a sink. Keep the diagnostics
     * in a file that can be retrieved after a failed title run. Explicit
     * values in radv.env still take precedence. */
    snprintf(path, sizeof(path), "%s/radv.log", root);
    pw_ps4_setenv("MESA_LOG_FILE", path);
    pw_ps4_setenv("MESA_LOG_LEVEL", "info");
    /* The title's settings.conf, which the launcher's Settings card writes
     * (fork src/pw_settings.h), can turn on the driver's hung-submit report
     * (off by default since Mesa patch 0044: it stuttered heavy titles):
     *
     *     gpu_hang_report=1   ->  ORBIS_DUMP_HUNG=1
     *
     * radv.env, read after it, still has the last word. */
    snprintf(path, sizeof(path), "%s/settings.conf", root);
    if ((file = fopen(path, "r"))) {
        while (fgets(line, sizeof(line), file)) {
            char *value;

            if (strncmp(line, "gpu_hang_report=", 16)) continue;
            value = line + 16;
            value[strcspn(value, " \t\r\n#")] = 0;
            if (!strcmp(value, "1") || !strcmp(value, "on") || !strcmp(value, "yes") || !strcmp(value, "true"))
                pw_ps4_setenv("ORBIS_DUMP_HUNG", "1");
            else if (!strcmp(value, "0") || !strcmp(value, "off") || !strcmp(value, "no") || !strcmp(value, "false"))
                pw_ps4_setenv("ORBIS_DUMP_HUNG", "0");
        }
        fclose(file);
    }
    snprintf(path, sizeof(path), "%s/radv.env", root);
    if (!(file = fopen(path, "r"))) return;
    while (fgets(line, sizeof(line), file)) {
        char *equals, *end;
        char *name = line;

        while (*name == ' ' || *name == '\t') name++;
        if (*name == '#' || *name == '\n' || !*name) continue;
        if (!(equals = strchr(name, '='))) continue;
        *equals = 0;
        for (end = equals; end > name && (end[-1] == ' ' || end[-1] == '\t'); end--) end[-1] = 0;
        end = equals + 1;
        for (char *p = end; *p; p++) if (*p == '\n' || *p == '\r') { *p = 0; break; }
        pw_ps4_setenv(name, end);
    }
    fclose(file);
}
