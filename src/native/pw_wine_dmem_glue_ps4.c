/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* ⚠ A COPY OF prospero-win's wine/ps5/pw_wine_dmem_ps5.c WITH PS4 CONSTANTS.
 *
 * Patch 0600 routes ntdll's anonymous mmap onto direct memory and calls five
 * entry points — __wine_ps5_{dmem_region,mmap,munmap,mprotect,memory_stats} —
 * which live in that file and nowhere else. Without them create-fself refuses:
 *
 *     Failed to build FSELF: missing library for symbol (__wine_ps5_mmap)
 *
 * A .so may leave a symbol undefined; a PRX may not.
 *
 * Almost all of the file is portable logic over pw_wine_dmem's vtable, and it
 * declares its own kernel externs rather than using the SDK headers — which is
 * fortunate, because the OpenOrbis header for sceKernelAllocateMainDirectMemory
 * declares its out-parameter BY VALUE and would silently lose the offset.
 *
 * Only the memory-type constant actually differs, and it matters:
 *   PS5  MEMORY_TYPE 0x0c
 *   PS4  WB_ONION 0x0, WC_GARLIC 0x3, WB_GARLIC 0xA — 0x0c is not a type here
 * A wrong type is not rejected loudly; it is rejected at allocation time and
 * reads as "no direct memory available". */
/* The console side of pw_wine_dmem, linked into ntdll.prx: libkernel's
 * direct memory behind the mmap, munmap and mprotect calls of ntdll's
 * virtual memory manager (patch 0600 routes them here), for the address
 * ranges it reserves up front. Everything else passes straight through.
 *
 * The recipe is the one ps5-xash3d's heap runs on (FW 12.02): main direct
 * memory, mapped read-write at a fixed address over a reservation, then
 * protected with sceKernelMprotect; execute permission is refused at map
 * time but granted by mprotect. A self-check maps, writes, protects and
 * frees one page before the first region is taken; if any step fails, the
 * regions stay ordinary reservations and every call passes through. */
#include "pw_wine_dmem.h"
#include "pw_wine_heap.h"
#include <errno.h>
#include <signal.h>
#include <sys/time.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <pthread.h>

/* ⚠ Which thread is migrating. Needed to tell a concurrency race (migration on
 * one thread, guest fault on another) from a failed migration whose own thread
 * then touches the page -- the two need opposite fixes, and the traces carried
 * no thread id. Printed into the same klog channel as the fault traces so the
 * causal chain sits in ONE stream: klog and ps5log timestamps are skewed by
 * ~0.4 s, which invalidated several cross-stream timing comparisons. */
static unsigned long glue_tid(void)
{
    return (unsigned long)(uintptr_t)pthread_self();
}

extern int sceKernelReserveVirtualRange(void **address, size_t bytes, int flags, size_t alignment);
extern int sceKernelAllocateMainDirectMemory(size_t bytes, size_t alignment, int type, int64_t *offset);
extern int sceKernelMapDirectMemory(void **address, size_t bytes, int protection, int flags,
                                    int64_t offset, size_t alignment);
extern int sceKernelMprotect(const void *address, size_t bytes, int protection);
extern int sceKernelVirtualQuery(const void *address, int flags, void *info, size_t size);
extern int sceKernelDebugOutText(int channel, const char *text);
extern int sceKernelMunmap(void *address, size_t bytes);
extern int sceKernelReleaseDirectMemory(int64_t offset, size_t bytes);
extern int sceKernelAvailableDirectMemorySize(off_t start, off_t end, size_t alignment,
                                              off_t *phys_out, size_t *size_out);
extern size_t sceKernelGetDirectMemorySize(void);

/* Patch 0603 reports the title's direct-memory pool through this Wine hook.
 * Keep the upstream ABI, but use the PS4 libkernel query and types. */
void __wine_ps5_memory_budget(unsigned long long *total, unsigned long long *available)
{
    /* sceKernelAvailableDirectMemorySize reports only the LARGEST free block
     * in the range it is given, so one query over the whole pool undercounts
     * fragmented free memory (archive 1014). Query disjoint 64 MiB ranges
     * and sum their largest blocks: a block can straddle a range boundary
     * and be counted as two smaller pieces, but no byte is counted twice.
     * About pool/64 MiB queries per GlobalMemoryStatusEx. */
    enum { GIB = 1024 * 1024 * 1024, RANGE = 64 * 1024 * 1024, ALIGN = 0x4000 };
    size_t pool = sceKernelGetDirectMemorySize(), free_bytes = 0;
    off_t limit = (off_t)(pool & ~(size_t)(ALIGN - 1));
    int answered = 0;

    for (off_t start = 0; start < limit; start += RANGE)
    {
        off_t end = start + RANGE < limit ? start + RANGE : limit, physical = 0;
        size_t block = 0;

        if (sceKernelAvailableDirectMemorySize(start, end, ALIGN, &physical, &block)) continue;
        answered = 1;
        free_bytes += block;
    }
    *total = pool ? pool : 4ull * GIB;
    *available = answered ? free_bytes : 0;
    if (*available > *total) *available = *total;
}

static void force_exec_trace(const char *format, ...)
{
    char line[256];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    sceKernelDebugOutText(0, line);
}

enum {
    PAGE = 0x4000,
    KERNEL_FIXED = 0x10,
    KERNEL_NO_OVERWRITE = 0x80,
    MEMORY_TYPE = 0x0,        /* ORBIS_KERNEL_WB_ONION: cached, CPU-coherent.
                             * Wine's anonymous memory is read far more than it is
                             * written, so WC_GARLIC (the scanout's type) would work
                             * and be slow in a way nothing reports. */
    CPU_READ_WRITE = 0x03,
    CPU_GPU_READ_WRITE = 0x33,  /* PS4: PROT_CPU_RW (0x3) | PROT_GPU_RW (0x30) */
    RUNS = 32768,
};

/* WINE_PS5_WAIT_WATCHDOG: a direct-memory call slower than 50 ms is
 * logged (prospero-win#250). */
static uint64_t slow_start(void)
{
    static int enabled = -1;
    struct timespec ts;

    if (enabled == -1) enabled = getenv("WINE_PS5_WAIT_WATCHDOG") != NULL;
    if (!enabled) return 0;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}
static void slow_end(uint64_t start, const char *what, size_t bytes)
{
    struct timespec ts;
    uint64_t now;

    if (!start) return;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    now = (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
    if (now - start > 50000)
        fprintf(stderr, "wine-ps5: slow dmem %s bytes=%zu ms=%llu\n", what, bytes,
                (unsigned long long)((now - start) / 1000u));
}

/* Low-volume timing for the Fallout RX-remap investigation. Report an
 * aggregate after each 10,000 mprotect calls. There is no per-page timing
 * output. The atomics are safe while Wine threads protect image pages.
 */
typedef struct PwExecRxMetrics
{
    volatile uint64_t protect_calls, protect_ns;
    volatile uint64_t exec_calls, exec_ns;
    volatile uint64_t query_calls, query_ns;
    volatile uint64_t migrate_calls, migrate_ns, migrate_bytes;
    volatile uint64_t migrate_ok, migrate_fail, scratch_fail, map_fail;
    volatile uint64_t release_fail, adopt_fail;
    volatile uint64_t scratch_ns, copy_ns, release_ns, map_ns, adopt_ns;
} PwExecRxMetrics;
static PwExecRxMetrics exec_rx_metrics;
static volatile uint64_t exec_rx_protect_total, exec_rx_last_report_bucket;

static uint64_t exec_rx_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static void exec_rx_add(volatile uint64_t *counter, uint64_t value)
{
    __atomic_fetch_add(counter, value, __ATOMIC_RELAXED);
}

static uint64_t exec_rx_take(volatile uint64_t *counter)
{
    return __atomic_exchange_n(counter, 0, __ATOMIC_RELAXED);
}

static void exec_rx_report(uint64_t call_no)
{
    uint64_t bucket = call_no / 10000u;
    uint64_t previous = __atomic_load_n(&exec_rx_last_report_bucket, __ATOMIC_RELAXED);
    char line[512];

    if (bucket <= previous ||
        !__atomic_compare_exchange_n(&exec_rx_last_report_bucket, &previous, bucket,
                                     0, __ATOMIC_RELAXED, __ATOMIC_RELAXED))
        return;

    snprintf(line, sizeof(line),
             "wine-ps4: exec-rx-timing through_call=%llu protect=%llu/%llu exec=%llu/%llu query=%llu/%llu migrate=%llu/%llu bytes=%llu ok=%llu fail=%llu scratch_fail=%llu map_fail=%llu release_fail=%llu adopt_fail=%llu scratch_ns=%llu copy_ns=%llu release_ns=%llu map_ns=%llu adopt_ns=%llu\n",
             (unsigned long long)call_no,
             (unsigned long long)exec_rx_take(&exec_rx_metrics.protect_calls),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.protect_ns),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.exec_calls),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.exec_ns),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.query_calls),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.query_ns),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.migrate_calls),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.migrate_ns),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.migrate_bytes),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.migrate_ok),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.migrate_fail),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.scratch_fail),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.map_fail),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.release_fail),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.adopt_fail),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.scratch_ns),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.copy_ns),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.release_ns),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.map_ns),
             (unsigned long long)exec_rx_take(&exec_rx_metrics.adopt_ns));
    sceKernelDebugOutText(0, line);
}

static int exec_rx_virtual_query(const void *address, int flags, void *info,
                                size_t size)
{
    uint64_t started = exec_rx_now_ns();
    int rc = sceKernelVirtualQuery(address, flags, info, size);
    exec_rx_add(&exec_rx_metrics.query_calls, 1);
    exec_rx_add(&exec_rx_metrics.query_ns, exec_rx_now_ns() - started);
    return rc;
}

/* CPU read-write, unless the kernel wants the GPU bits too. */
static int map_protection = CPU_READ_WRITE;

/* Layout used by sceKernelVirtualQuery in the PS4 runtime. Keep the field
 * order and widths explicit here because this diagnostic is answering whether
 * the hardware mapping actually has execute permission. */
typedef struct {
    uintptr_t start, end;
    int64_t offset;
    int32_t protection, memory_type;
    uint8_t flags;
    char name[32];
} PwPs4VirtualQueryInfo;

_Static_assert(offsetof(PwPs4VirtualQueryInfo, offset) == 2 * sizeof(void *),
               "unexpected sceKernelVirtualQuery layout");

/* Keep the recent guest-address mapping operations in a small lock-free ring.
 * A fixed-address trace (package 1057) missed the next Continue fault because
 * the allocator returned a different address. The ring is dumped only when a
 * guest page fault is unresolved, so normal launches produce no per-operation
 * log traffic. */
enum { MAP_HISTORY_SLOTS = 512, MAP_HISTORY_DUMP_LIMIT = 48 };
typedef struct PwMapHistoryEntry
{
    volatile uint64_t sequence;
    volatile uintptr_t address;
    volatile size_t bytes;
    volatile int requested, extra, fd, result;
    volatile int64_t offset;
    volatile uintptr_t caller;
    volatile unsigned long tid;
    const char * volatile op, * volatile path;
} PwMapHistoryEntry;
static PwMapHistoryEntry map_history[MAP_HISTORY_SLOTS];
static volatile uint64_t map_history_next;

static void record_map_history(const char *op, uintptr_t address, size_t bytes,
                               int requested, int extra, int fd, int64_t offset,
                               int result, const char *path, uintptr_t caller,
                               unsigned long tid)
{
    uint64_t n;
    PwMapHistoryEntry *entry;

    /* Wine's 32-bit guest mappings live below 4 GiB. Ignore PRX, stack and
     * other 64-bit host mappings; retaining only guest VA events lowers the
     * chance that busy Unix-side allocator churn evicts the relevant history. */
    if (address >= 0x100000000ULL || !bytes || bytes > 0x100000000ULL) return;
    n = __atomic_fetch_add(&map_history_next, 1, __ATOMIC_RELAXED);
    entry = &map_history[n % MAP_HISTORY_SLOTS];
    __atomic_store_n(&entry->sequence, n * 2 + 1, __ATOMIC_RELEASE);
    __atomic_store_n(&entry->address, address, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->bytes, bytes, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->requested, requested, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->extra, extra, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->fd, fd, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->offset, offset, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->result, result, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->caller, caller, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->tid, tid, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->op, op, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->path, path, __ATOMIC_RELAXED);
    __atomic_store_n(&entry->sequence, n * 2 + 2, __ATOMIC_RELEASE);
}

static volatile unsigned int map_fault_dump_count;
static volatile unsigned int map_fault_hook_count;
static volatile unsigned int map_fault_settled_allowed_count;

static void dump_map_history_for_fault(uintptr_t fault, unsigned int access,
                                       const char *phase)
{
    const uintptr_t page_start = fault & ~(uintptr_t)(PAGE - 1);
    const uintptr_t page_end = page_start + PAGE;
    PwPs4VirtualQueryInfo info;
    uint64_t end, begin, i;
    unsigned int emitted = 0;
    int query_rc;
    char line[288];

    memset(&info, 0, sizeof(info));
    query_rc = sceKernelVirtualQuery((const void *)fault, 1, &info, sizeof(info));
    snprintf(line, sizeof(line),
             "wine-ps4: map-fault-history build=1069 phase=%s fault=%p access=%u page=%p-%p query=%d range=%p-%p kprot=%#x type=%#x\n",
             phase, (void *)fault, access, (void *)page_start, (void *)page_end,
             query_rc, (void *)info.start, (void *)info.end,
             info.protection, info.memory_type);
    sceKernelDebugOutText(0, line);

    end = __atomic_load_n(&map_history_next, __ATOMIC_ACQUIRE);
    begin = end > MAP_HISTORY_SLOTS ? end - MAP_HISTORY_SLOTS : 0;
    for (i = begin; i < end && emitted < MAP_HISTORY_DUMP_LIMIT; ++i)
    {
        PwMapHistoryEntry *entry = &map_history[i % MAP_HISTORY_SLOTS];
        uint64_t expected = i * 2 + 2;
        uintptr_t address;
        size_t bytes;
        int requested, extra, fd, result;
        int64_t offset;
        uintptr_t caller;
        unsigned long tid;
        const char *op, *path;
        uint64_t first = __atomic_load_n(&entry->sequence, __ATOMIC_ACQUIRE);

        if (first != expected) continue;
        address = __atomic_load_n(&entry->address, __ATOMIC_RELAXED);
        bytes = __atomic_load_n(&entry->bytes, __ATOMIC_RELAXED);
        requested = __atomic_load_n(&entry->requested, __ATOMIC_RELAXED);
        extra = __atomic_load_n(&entry->extra, __ATOMIC_RELAXED);
        fd = __atomic_load_n(&entry->fd, __ATOMIC_RELAXED);
        offset = __atomic_load_n(&entry->offset, __ATOMIC_RELAXED);
        result = __atomic_load_n(&entry->result, __ATOMIC_RELAXED);
        caller = __atomic_load_n(&entry->caller, __ATOMIC_RELAXED);
        tid = __atomic_load_n(&entry->tid, __ATOMIC_RELAXED);
        op = __atomic_load_n(&entry->op, __ATOMIC_RELAXED);
        path = __atomic_load_n(&entry->path, __ATOMIC_RELAXED);
        if (__atomic_load_n(&entry->sequence, __ATOMIC_ACQUIRE) != first) continue;
        if (!bytes || bytes > UINTPTR_MAX - address ||
            address >= page_end || address + bytes <= page_start) continue;
        snprintf(line, sizeof(line),
                 "wine-ps4: map-fault-history event=%llu op=%s addr=%p bytes=%zu req=%#x extra=%#x fd=%d off=%lld rc=%d path=%s caller=%p tid=%lx\n",
                 (unsigned long long)i, op ? op : "?", (void *)address,
                 bytes, requested, extra, fd, (long long)offset, result,
                 path ? path : "?", (void *)caller, tid);
        sceKernelDebugOutText(0, line);
        ++emitted;
    }
    snprintf(line, sizeof(line),
             "wine-ps4: map-fault-history end fault=%p events=%u retained=%llu\n",
             (void *)fault, emitted, (unsigned long long)(end - begin));
    sceKernelDebugOutText(0, line);
}

static void capture_map_history_for_fault(uintptr_t fault, unsigned int access,
                                          const char *phase)
{
    PwPs4VirtualQueryInfo info;
    unsigned int capture;
    int query_rc;
    char line[256];

    /* Ignore the low guest stack and capture only faults where the kernel's
     * effective mapping cannot satisfy the guest access. In 1060, three
     * ordinary low stack faults and an unrelated early heap reservation
     * consumed the process-wide trace budget before Continue reached the
     * faulting heap page. */
    if (fault < 0x01000000u || fault >= 0x70000000u ||
        (access != 0 && access != 1)) return;

    memset(&info, 0, sizeof(info));
    query_rc = sceKernelVirtualQuery((const void *)fault, 1, &info, sizeof(info));
    if (!query_rc && (uintptr_t)info.start <= fault &&
        (uintptr_t)info.end > fault &&
        ((access == 0 && (info.protection & PROT_READ)) ||
         (access == 1 && (info.protection & PROT_WRITE))))
    {
        /* A CPU not-present fault can survive an apparently writable kernel
         * mapping. Retain a few settled write cases so their map/unmap history
         * is available before Wine reports the guest exception. Completed
         * migration retries have their own trace and can be very frequent. */
        if (access == 1 && phase && !strcmp(phase, "settled") &&
            __atomic_add_fetch(&map_fault_settled_allowed_count, 1,
                               __ATOMIC_RELAXED) <= 8)
            dump_map_history_for_fault(fault, access, "settled-kernel-allows");
        unsigned int n = __atomic_add_fetch(&map_fault_hook_count, 1, __ATOMIC_RELAXED);
        if (n <= 64)
        {
            snprintf(line, sizeof(line),
                     "wine-ps4: map-fault-probe build=1070 n=%u addr=%p access=%u phase=%s query=%d range=%p-%p kprot=%#x result=kernel-allows\n",
                     n, (void *)fault, access, phase, query_rc,
                     (void *)info.start, (void *)info.end, info.protection);
            sceKernelDebugOutText(0, line);
        }
        return;
    }

    capture = __atomic_add_fetch(&map_fault_dump_count, 1, __ATOMIC_RELAXED);
    if (capture <= 64)
        dump_map_history_for_fault(fault, access, phase);
    else
    {
        unsigned int n = __atomic_add_fetch(&map_fault_hook_count, 1, __ATOMIC_RELAXED);
        if (n <= 64)
        {
            snprintf(line, sizeof(line),
                     "wine-ps4: map-fault-probe build=1070 n=%u addr=%p access=%u phase=%s query=%d range=%p-%p kprot=%#x result=budget-exhausted captures=%u\n",
                     n, (void *)fault, access, phase, query_rc,
                     (void *)info.start, (void *)info.end, info.protection, capture);
            sceKernelDebugOutText(0, line);
        }
    }
}

/* Keep exact-range mapping traces for the 1057 allocator page and the
 * Fallout NV object page seen in 1058/1071, in addition to the generic
 * on-fault ring above. These traces are bounded and only emit operations
 * intersecting one of the watched 16 KiB pages. */
enum { OBJECT_TRACE_LIMIT = 256 };
static const uintptr_t object_trace_pages[][2] = {
    { 0x3009c000u, 0x300a0000u },
    { 0x32130000u, 0x32134000u },
};
static volatile unsigned object_mapping_trace_count;

static void trace_object_mapping(const char *op, uintptr_t address, size_t bytes,
                                 int requested, int result, const char *path)
{
    PwPs4VirtualQueryInfo info;
    uintptr_t end, sample = 0;
    unsigned n;
    unsigned int i;
    int query_rc;
    char line[320];

    record_map_history(op, address, bytes, requested, 0, -1, 0, result,
                       path, 0, 0);

    if (!bytes || bytes > UINTPTR_MAX - address)
        return;
    end = address + bytes;
    for (i = 0; i < sizeof(object_trace_pages) / sizeof(object_trace_pages[0]); ++i)
    {
        if (address < object_trace_pages[i][1] && end > object_trace_pages[i][0])
        {
            sample = address < object_trace_pages[i][0] ? object_trace_pages[i][0] : address;
            break;
        }
    }
    if (!sample) return;
    n = __atomic_fetch_add(&object_mapping_trace_count, 1, __ATOMIC_RELAXED);
    if (n >= OBJECT_TRACE_LIMIT) return;

    memset(&info, 0, sizeof(info));
    query_rc = sceKernelVirtualQuery((const void *)sample, 1, &info, sizeof(info));
    if (!query_rc) info.name[sizeof(info.name) - 1] = '\0';
    snprintf(line, sizeof(line),
             "wine-ps4: object-map-trace n=%u op=%s addr=%p bytes=%zu req=%#x rc=%d path=%s sample=%p query=%d range=%p-%p kprot=%#x type=%#x flags=%#x name=%s\n",
             n + 1, op, (void *)address, bytes, requested, result, path,
             (void *)sample, query_rc, (void *)info.start, (void *)info.end,
             info.protection, info.memory_type, info.flags,
             query_rc == 0 ? info.name : "?");
    sceKernelDebugOutText(0, line);
}

/* Add the ntdll-facing VM API calls to the same bounded ring as their
 * low-level direct-memory operations. The kernel map trace alone cannot tell
 * whether a remap came from guest mmap/munmap/mprotect or from executable
 * migration. Caller and thread ID let the next fault trace answer that. */
static void trace_vm_api(const char *op, uintptr_t address, size_t bytes,
                         int protection, int flags, int fd, int64_t offset,
                         int result, const char *path, uintptr_t caller)
{
    record_map_history(op, address, bytes, protection, flags, fd, offset,
                       result, path, caller, glue_tid());
}

/* Native WoW64 reached a PE32 image page that Wine described as executable,
 * but the CPU reported a present instruction-fetch protection fault. Use
 * libkernel's protection entry point first for executable mappings, as the
 * direct-memory path already does. Keep mprotect as a compatibility fallback
 * and record the result for low guest addresses in a bounded trace. */
static int ps4_host_mprotect(void *address, size_t bytes, int protection)
{
    static unsigned logged;
    static unsigned fault_page_rwx_tested;
    static unsigned fault_page_host_protect_logged;
    int kernel_rc, libc_rc;

    if (!(protection & PROT_EXEC))
    {
        int rc = mprotect(address, bytes, protection);
        uintptr_t start = (uintptr_t)address;
        uintptr_t end = start + bytes;

        trace_object_mapping("host-mprotect", start, bytes, protection, rc,
                             "libc-mprotect");

        if (start <= 0x004a8330u && end > 0x004a8330u &&
            __atomic_fetch_add(&fault_page_host_protect_logged, 1, __ATOMIC_RELAXED) < 32)
        {
            PwPs4VirtualQueryInfo info;
            int query_rc;
            char line[256];

            memset(&info, 0, sizeof(info));
            query_rc = sceKernelVirtualQuery((const void *)0x004a8330u, 1,
                                             &info, sizeof(info));
            if (query_rc == 0) info.name[sizeof(info.name) - 1] = '\0';
            snprintf(line, sizeof(line),
                     "wine-ps4: fault-page host-mprotect addr=%p bytes=%zu prot=%#x rc=%d query=%d range=%p-%p effective=%#x name=%s\n",
                     address, bytes, protection, rc, query_rc,
                     (void *)info.start, (void *)info.end, info.protection,
                     query_rc == 0 ? info.name : "?");
            sceKernelDebugOutText(0, line);
        }
        return rc;
    }

    kernel_rc = sceKernelMprotect(address, bytes, protection);
    libc_rc = kernel_rc ? mprotect(address, bytes, protection) : 0;
    trace_object_mapping("host-mprotect", (uintptr_t)address, bytes,
                         protection, kernel_rc ? libc_rc : kernel_rc,
                         kernel_rc ? "sce-failed-libc-fallback" : "sce");

    /* The 0948 raw frame reports an instruction-fetch protection fault at
     * 0x004a8330 even though this mprotect range covers the image. Ask the
     * kernel for that exact page's effective mapping after the call. */
    if ((uintptr_t)address <= 0x004a8330u &&
        (uintptr_t)address + bytes > 0x004a8330u)
    {
        PwPs4VirtualQueryInfo info;
        int query_rc, rwx_rc = -1, final_query_rc;
        int32_t before_prot;
        memset(&info, 0, sizeof(info));
        query_rc = sceKernelVirtualQuery((const void *)0x004a8330u, 1,
                                         &info, sizeof(info));
        before_prot = query_rc == 0 ? info.protection : -1;
        if (query_rc == 0 && !(info.protection & PROT_EXEC) &&
            !__atomic_exchange_n(&fault_page_rwx_tested, 1, __ATOMIC_RELAXED))
        {
            /* 0949 showed RX requested successfully while the kernel still
             * reported read-only. Test whether this direct-memory image page
             * needs W permission present when execute is granted. Keep the
             * experiment to the one 16 KiB page containing the fault. */
            rwx_rc = sceKernelMprotect((const void *)0x004a8000u, PAGE,
                                       PROT_READ | PROT_WRITE | PROT_EXEC);
            memset(&info, 0, sizeof(info));
            final_query_rc = sceKernelVirtualQuery((const void *)0x004a8330u, 1,
                                                   &info, sizeof(info));
        }
        else
        {
            final_query_rc = query_rc;
        }
        if (query_rc == 0) info.name[sizeof(info.name) - 1] = '\0';
        {
            char line[256];
            snprintf(line, sizeof(line),
                     "wine-ps4: fault-page query addr=0x004a8330 mprotect=%d/%d query=%d before=%#x rwx=%d final=%d range=%p-%p prot=%#x type=%#x flags=%#x name=%s\n",
                     kernel_rc, libc_rc, query_rc, before_prot, rwx_rc,
                     final_query_rc, (void *)info.start, (void *)info.end,
                     info.protection, info.memory_type, info.flags,
                     final_query_rc == 0 ? info.name : "?");
            sceKernelDebugOutText(0, line);
        }
    }

    if ((uintptr_t)address < 0x100000000ULL && __atomic_fetch_add(&logged, 1, __ATOMIC_RELAXED) < 32)
    {
        char line[192];
        snprintf(line, sizeof(line),
                 "wine-ps4: exec mprotect addr=%p bytes=%zu prot=%#x sce=%d libc=%d\n",
                 address, bytes, protection, kernel_rc, libc_rc);
        /* stderr is not captured on this title (dup2 onto fd 1/2 returns
         * EPERM), so send this bounded result through the live klog stream. */
        sceKernelDebugOutText(0, line);
    }
    return kernel_rc ? libc_rc : 0;
}

static int reserve(void *context, uintptr_t address, size_t bytes)
{
    void *at = (void *)address;
    uint64_t t0 = slow_start();
    int kernel_rc, rc;
    (void)context;
    kernel_rc = sceKernelReserveVirtualRange(&at, bytes,
                                             KERNEL_FIXED | KERNEL_NO_OVERWRITE,
                                             PAGE);
    rc = kernel_rc || at != (void *)address;
    trace_object_mapping("reserve", address, bytes,
                         KERNEL_FIXED | KERNEL_NO_OVERWRITE, kernel_rc,
                         at == (void *)address ? "sce" : "sce-wrong-address");
    slow_end(t0, "reserve", bytes);
    return rc;
}
static int allocate(void *context, size_t bytes, int64_t *offset)
{
    uint64_t t0 = slow_start();
    int rc;
    (void)context;
    rc = sceKernelAllocateMainDirectMemory(bytes, PAGE, MEMORY_TYPE, offset) != 0;
    slow_end(t0, "allocate", bytes);
    return rc;
}
static int map(void *context, uintptr_t address, size_t bytes, int64_t offset)
{
    void *at = (void *)address;
    uint64_t t0 = slow_start();
    int rc, first_rc;
    (void)context;
    first_rc = sceKernelMapDirectMemory(&at, bytes, map_protection,
                                        KERNEL_FIXED, offset, PAGE);
    rc = first_rc;
    trace_object_mapping("map-dmem", address, bytes, map_protection, first_rc,
                         at == (void *)address ? "sce" : "sce-wrong-address");
    slow_end(t0, "map", bytes);
    if (rc && map_protection == CPU_READ_WRITE) {
        /* Refused CPU-only: the GPU bits, and keep them if they work. */
        at = (void *)address;
        rc = sceKernelMapDirectMemory(&at, bytes, CPU_GPU_READ_WRITE, KERNEL_FIXED, offset, PAGE);
        trace_object_mapping("map-dmem-fallback", address, bytes,
                             CPU_GPU_READ_WRITE, rc,
                             at == (void *)address ? "sce" : "sce-wrong-address");
        if (!rc) map_protection = CPU_GPU_READ_WRITE;
    }
    return rc || at != (void *)address;
}
static int protect(void *context, uintptr_t address, size_t bytes, unsigned protection)
{
    uint64_t t0 = slow_start();
    int rc;
    (void)context;
    rc = ps4_host_mprotect((void *)address, bytes, (int)protection) != 0;
    slow_end(t0, "protect", bytes);
    return rc;
}
static int unmap(void *context, uintptr_t address, size_t bytes)
{
    uint64_t t0 = slow_start();
    int rc;
    (void)context;
    rc = sceKernelMunmap((void *)address, bytes) != 0;
    trace_object_mapping("dmem-unmap", address, bytes, 0, rc, "sce");
    slow_end(t0, "unmap", bytes);
    return rc;
}
static int release(void *context, int64_t offset, size_t bytes)
{
    uint64_t t0 = slow_start();
    int rc;
    (void)context;
    rc = sceKernelReleaseDirectMemory(offset, bytes) != 0;
    slow_end(t0, "release", bytes);
    return rc;
}

static const PwWineDmemOps ops = { NULL, PAGE, reserve, allocate, map, protect, unmap, release };
static PwWineDmem dmem;

/* Signal-side coordination for executable direct-memory migration. The
 * migration replaces a direct-memory mapping with a flexible mapping; on
 * PS4, readers can fault in the short interval between releasing the first
 * mapping and installing/restoring the second. A fault handler cannot take
 * the dmem manager's lock (the migrating thread may hold it), so publish a
 * small lock-free range table instead. */
#define EXEC_MIGRATION_SLOTS 64
#define EXEC_MIGRATION_FREE 0
#define EXEC_MIGRATION_ACTIVE 1
#define EXEC_MIGRATION_INIT 2
#define EXEC_MIGRATION_RECENT_NS 250000000LL
typedef struct PwExecMigration
{
    volatile unsigned int state;
    uintptr_t start, end;
} PwExecMigration;
static PwExecMigration exec_migrations[EXEC_MIGRATION_SLOTS];
static volatile unsigned int exec_migration_active_count;
static volatile unsigned int exec_migration_claim_lock;

typedef struct PwRecentExecMigration
{
    volatile uint64_t sequence;
    volatile uintptr_t start, end;
    volatile uint64_t completed_ns;
    volatile unsigned int retry_claimed;
} PwRecentExecMigration;
static PwRecentExecMigration recent_exec_migrations[EXEC_MIGRATION_SLOTS];
static volatile uint64_t recent_exec_migration_next;

static int exec_migration_begin(uintptr_t start, size_t bytes)
{
    const uintptr_t end = start + bytes;
    struct timespec began, now;

    if (!bytes || end < start || clock_gettime(CLOCK_MONOTONIC, &began)) return -1;
    for (;;)
    {
        unsigned int slot = EXEC_MIGRATION_SLOTS;
        int overlap = 0;

        while (__atomic_exchange_n(&exec_migration_claim_lock, 1, __ATOMIC_ACQUIRE))
            __asm__ volatile("pause" ::: "memory");

        for (unsigned int i = 0; i < EXEC_MIGRATION_SLOTS; ++i)
        {
            PwExecMigration *entry = &exec_migrations[i];
            unsigned int state = __atomic_load_n(&entry->state, __ATOMIC_ACQUIRE);

            if (state == EXEC_MIGRATION_FREE)
            {
                if (slot == EXEC_MIGRATION_SLOTS) slot = i;
                continue;
            }
            /* INIT has no stable interval yet. Conservatively wait until the
             * claimant publishes its range before admitting another remap. */
            if (state == EXEC_MIGRATION_INIT ||
                (start < entry->end && entry->start < end))
            {
                overlap = 1;
                break;
            }
        }

        if (!overlap && slot < EXEC_MIGRATION_SLOTS)
        {
            PwExecMigration *entry = &exec_migrations[slot];
            __atomic_store_n(&entry->state, EXEC_MIGRATION_INIT, __ATOMIC_RELEASE);
            entry->start = start;
            entry->end = end;
            __atomic_add_fetch(&exec_migration_active_count, 1, __ATOMIC_RELEASE);
            __atomic_store_n(&entry->state, EXEC_MIGRATION_ACTIVE, __ATOMIC_RELEASE);
            __atomic_store_n(&exec_migration_claim_lock, 0, __ATOMIC_RELEASE);
            return (int)slot;
        }

        __atomic_store_n(&exec_migration_claim_lock, 0, __ATOMIC_RELEASE);
        if (!overlap || clock_gettime(CLOCK_MONOTONIC, &now) ||
            (now.tv_sec - began.tv_sec) * 1000000000LL + now.tv_nsec - began.tv_nsec >= 250000000LL)
            return -1;
        __asm__ volatile("pause" ::: "memory");
    }
}

static void exec_migration_end(int slot)
{
    if (slot >= 0)
    {
        PwExecMigration *active = &exec_migrations[slot];
        struct timespec now;
        if (!clock_gettime(CLOCK_MONOTONIC, &now))
        {
            uint64_t n = __atomic_fetch_add(&recent_exec_migration_next, 1,
                                            __ATOMIC_RELAXED);
            PwRecentExecMigration *recent =
                &recent_exec_migrations[n % EXEC_MIGRATION_SLOTS];
            __atomic_store_n(&recent->sequence, n * 2 + 1, __ATOMIC_RELEASE);
            __atomic_store_n(&recent->start, active->start, __ATOMIC_RELAXED);
            __atomic_store_n(&recent->end, active->end, __ATOMIC_RELAXED);
            __atomic_store_n(&recent->completed_ns,
                             (uint64_t)now.tv_sec * 1000000000ULL + now.tv_nsec,
                             __ATOMIC_RELAXED);
            __atomic_store_n(&recent->retry_claimed, 0, __ATOMIC_RELAXED);
            __atomic_store_n(&recent->sequence, n * 2 + 2, __ATOMIC_RELEASE);
        }
        __atomic_store_n(&exec_migrations[slot].state, EXEC_MIGRATION_FREE,
                         __ATOMIC_RELEASE);
        __atomic_sub_fetch(&exec_migration_active_count, 1, __ATOMIC_RELEASE);
    }
}

/* Claim one retry per access type for the most recent completed migration
 * covering fault. A migration can leave both a write fault (while the page is
 * frozen read-only) and a later read fault (while the host mapping settles).
 * Keep those independent so the first access does not consume the other's
 * single bounded retry. A repeated fault of the same type is still handed
 * back to Wine instead of retrying forever. */
static int claim_recent_migration_fault(const void *address, unsigned int access)
{
    struct timespec now;
    uint64_t now_ns, end, begin, i;
    uintptr_t fault = (uintptr_t)address;

    if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    now_ns = (uint64_t)now.tv_sec * 1000000000ULL + now.tv_nsec;
    end = __atomic_load_n(&recent_exec_migration_next, __ATOMIC_ACQUIRE);
    begin = end > EXEC_MIGRATION_SLOTS ? end - EXEC_MIGRATION_SLOTS : 0;
    for (i = end; i > begin; --i)
    {
        uint64_t n = i - 1;
        PwRecentExecMigration *entry =
            &recent_exec_migrations[n % EXEC_MIGRATION_SLOTS];
        uint64_t expected = n * 2 + 2;
        uintptr_t start, finish;
        uint64_t completed;
        unsigned int access_bit;
        unsigned int claimed;

        if (access != 0 && access != 1) return 0;
        access_bit = 1u << access;

        if (__atomic_load_n(&entry->sequence, __ATOMIC_ACQUIRE) != expected)
            continue;
        start = __atomic_load_n(&entry->start, __ATOMIC_RELAXED);
        finish = __atomic_load_n(&entry->end, __ATOMIC_RELAXED);
        completed = __atomic_load_n(&entry->completed_ns, __ATOMIC_RELAXED);
        if (__atomic_load_n(&entry->sequence, __ATOMIC_ACQUIRE) != expected)
            continue;
        if (fault < start || fault >= finish || now_ns < completed ||
            now_ns - completed > EXEC_MIGRATION_RECENT_NS)
            continue;
        claimed = __atomic_fetch_or(&entry->retry_claimed, access_bit,
                                    __ATOMIC_ACQ_REL);
        if (claimed & access_bit)
            return 0;
        if (__atomic_load_n(&entry->sequence, __ATOMIC_ACQUIRE) != expected)
            return 0;
        return 1;
    }
    return 0;
}

/* Called from ntdll's SIGSEGV handler. Wait only when this address is inside
 * a migration already in progress, and only recover if the requested access
 * is valid after the migration settles. Uses no mutex or allocation on the
 * signal path; bounded logs are emitted only for guest data-space read/write
 * faults. */
int __wine_ps5_wait_for_exec_migration(const void *address, unsigned int access,
                                      unsigned int page_fault_error)
{
    struct PwVirtualQueryInfo
    {
        void *start, *end;
        int64_t offset;
        int32_t protection, memory_type;
        uint8_t flags;
        char name[32];
    } info;
    const uintptr_t fault = (uintptr_t)address;
    const int64_t timeout_ns = 250000000;
    struct timespec began, now;
    int waited = 0;
    int probe_logged = 0;
    uintptr_t matched_start = 0, matched_end = 0;
    unsigned int matched_state = EXEC_MIGRATION_FREE;
    static volatile unsigned int fault_probe_count;
    static volatile unsigned int map_hook_count;

    if (fault >= 0x01000000u && fault < 0x70000000u &&
        (access == 0 || access == 1))
    {
        unsigned int n = __atomic_add_fetch(&map_hook_count, 1, __ATOMIC_RELAXED);
        if (n <= 64)
        {
            char line[192];
            snprintf(line, sizeof(line),
                     "wine-ps4: map-fault-hook build=1070 n=%u addr=%p access=%u active=%u\n",
                     n, (void *)fault, access,
                     __atomic_load_n(&exec_migration_active_count, __ATOMIC_ACQUIRE));
            sceKernelDebugOutText(0, line);
        }
    }

    if (clock_gettime(CLOCK_MONOTONIC, &began)) return 0;
    for (;;)
    {
        unsigned int i;
        int active = 0;
        for (i = 0; i < EXEC_MIGRATION_SLOTS; ++i)
        {
            PwExecMigration *entry = &exec_migrations[i];
            unsigned int state = __atomic_load_n(&entry->state, __ATOMIC_ACQUIRE);
            if (state == EXEC_MIGRATION_INIT ||
                (state == EXEC_MIGRATION_ACTIVE && fault >= entry->start && fault < entry->end))
            {
                active = 1;
                waited = 1;
                if (state == EXEC_MIGRATION_ACTIVE)
                {
                    matched_start = entry->start;
                    matched_end = entry->end;
                }
                matched_state = state;
                break;
            }
        }
        if (!active)
        {
            /* Trace only unresolved guest data-space reads/writes. This distinguishes
             * a stale/unbacked object from an RX migration overlap without
             * adding work to mprotect or allocation. */
            if (fault >= 0x10000 && fault < 0x70000000)
            {
                /* A completed RX migration can race either a guest load or
                 * store. The page may be fully restored by the time the
                 * signal handler runs, so permit the same bounded retry for
                 * reads and writes, but only when a recent migration record
                 * matches and the kernel confirms the requested access. */
                int recent = (access == 0 || access == 1) ?
                             claim_recent_migration_fault(address, access) : 0;

                /* Keep a trace budget for missing/inaccessible guest heap
                 * pages. Exclude low stack guard pages: they consumed all
                 * four 1060 slots before the Continue fault. */
                capture_map_history_for_fault(fault, access,
                                              recent ? "recent-migration" : "settled");

                if (recent)
                {
                    int query_rc;
                    memset(&info, 0, sizeof(info));
                    query_rc = sceKernelVirtualQuery(address, 1, &info, sizeof(info));
                    if (!query_rc && (uintptr_t)info.start <= fault &&
                        (uintptr_t)info.end > fault &&
                        ((access == 0 && (info.protection & PROT_READ)) ||
                         (access == 1 && (info.protection & PROT_WRITE)) ||
                         (access == 8 && (info.protection & PROT_EXEC))))
                    {
                        static volatile unsigned int late_retry_count;
                        unsigned int retry = __atomic_add_fetch(&late_retry_count, 1,
                                                                 __ATOMIC_RELAXED);
                        if (retry <= 32)
                        {
                            char line[192];
                            snprintf(line, sizeof(line),
                                     "wine-ps4: exec-migrate-late-retry build=1064 n=%u addr=%p access=%u query=%d range=%p-%p prot=%#x\n",
                                     retry, address, access, query_rc, info.start,
                                     info.end, (unsigned)info.protection);
                            sceKernelDebugOutText(0, line);
                        }
                        return 1;
                    }
                }

                /* A present x86 user write fault means the CPU found a mapped
                 * page but rejected the store. If libkernel independently
                 * reports that the containing PS4 page is committed and
                 * writable, reapply that exact permission once for this page.
                 * This is a bounded recovery for a stale hardware translation;
                 * it does not turn unmapped or read-only faults into success. */
                if (!recent && access == 1 && (page_fault_error & 7) == 7)
                {
                    static uintptr_t retried_pages[32];
                    static volatile unsigned int protection_retry_count;
                    uintptr_t page = fault & ~(uintptr_t)(PAGE - 1);
                    unsigned int slot = (unsigned int)((page >> 14) % 32), i;
                    int claimed = 0, query_rc, sce_rc = -1, libc_rc = -1, verify_rc;
                    int protection = 0, verify_protection = 0;
                    char line[256];

                    for (i = 0; i < 32; ++i)
                    {
                        uintptr_t current;
                        unsigned int at = (slot + i) % 32;
                        current = __atomic_load_n(&retried_pages[at], __ATOMIC_RELAXED);
                        if (current == page) break;
                        if (!current && __atomic_compare_exchange_n(&retried_pages[at],
                                                                     &current, page, 0,
                                                                     __ATOMIC_RELAXED,
                                                                     __ATOMIC_RELAXED))
                        {
                            claimed = 1;
                            break;
                        }
                    }
                    if (claimed && __atomic_add_fetch(&protection_retry_count, 1,
                                                       __ATOMIC_RELAXED) <= 32)
                    {
                        memset(&info, 0, sizeof(info));
                        query_rc = sceKernelVirtualQuery(address, 1, &info, sizeof(info));
                        if (!query_rc && (uintptr_t)info.start <= page &&
                            (uintptr_t)info.end >= page + PAGE &&
                            (info.protection & PROT_WRITE) &&
                            !(info.protection & PROT_EXEC))
                        {
                            protection = info.protection;
                            sce_rc = sceKernelMprotect((const void *)page, PAGE, protection);
                            if (sce_rc) libc_rc = mprotect((void *)page, PAGE, protection);
                            memset(&info, 0, sizeof(info));
                            verify_rc = sceKernelVirtualQuery(address, 1, &info, sizeof(info));
                            verify_protection = verify_rc ? 0 : info.protection;
                            snprintf(line, sizeof(line),
                                     "wine-ps4: present-write-protect-retry build=1079 addr=%p page=%p access=%u pferr=%#x query=%d prot=%#x sce=%d libc=%d verify=%d after=%#x\n",
                                     address, (void *)page, access, page_fault_error,
                                     query_rc, protection, sce_rc, libc_rc, verify_rc,
                                     verify_protection);
                            sceKernelDebugOutText(0, line);
                            if (!verify_rc && (verify_protection & PROT_WRITE)) return 1;
                        }
                        else
                        {
                            snprintf(line, sizeof(line),
                                     "wine-ps4: present-write-protect-retry build=1079 addr=%p page=%p access=%u pferr=%#x query=%d range=%p-%p prot=%#x result=declined\n",
                                     address, (void *)page, access, page_fault_error,
                                     query_rc, info.start, info.end,
                                     (unsigned)info.protection);
                            sceKernelDebugOutText(0, line);
                        }
                    }
                }

                /* A non-present user read can race a direct-memory remap in
                 * the same way as the write case above. The first fault-time
                 * query may observe no permissions, while a follow-up query
                 * sees the page restored. If the current PS4 mapping now
                 * covers the full host page and allows reads, retry this
                 * instruction once for that page. Do not create or widen a
                 * mapping here: unresolved faults continue to Wine. */
                if (!recent && access == 0 && (page_fault_error & 7) == 4)
                {
                    static uintptr_t retried_read_pages[32];
                    static volatile unsigned int read_retry_count;
                    uintptr_t page = fault & ~(uintptr_t)(PAGE - 1);
                    unsigned int slot = (unsigned int)((page >> 14) % 32), i;
                    int claimed = 0, query_rc;

                    for (i = 0; i < 32; ++i)
                    {
                        uintptr_t current;
                        unsigned int at = (slot + i) % 32;
                        current = __atomic_load_n(&retried_read_pages[at], __ATOMIC_RELAXED);
                        if (current == page) break;
                        if (!current && __atomic_compare_exchange_n(&retried_read_pages[at],
                                                                     &current, page, 0,
                                                                     __ATOMIC_RELAXED,
                                                                     __ATOMIC_RELAXED))
                        {
                            claimed = 1;
                            break;
                        }
                    }
                    if (claimed && __atomic_add_fetch(&read_retry_count, 1,
                                                       __ATOMIC_RELAXED) <= 32)
                    {
                        char line[224];
                        memset(&info, 0, sizeof(info));
                        query_rc = sceKernelVirtualQuery(address, 1, &info, sizeof(info));
                        if (!query_rc && (uintptr_t)info.start <= page &&
                            (uintptr_t)info.end >= page + PAGE &&
                            (info.protection & PROT_READ))
                        {
                            snprintf(line, sizeof(line),
                                     "wine-ps4: nonpresent-read-retry build=1080 addr=%p page=%p pferr=%#x query=%d range=%p-%p prot=%#x\n",
                                     address, (void *)page, page_fault_error, query_rc,
                                     info.start, info.end, (unsigned)info.protection);
                            sceKernelDebugOutText(0, line);
                            return 1;
                        }
                        snprintf(line, sizeof(line),
                                 "wine-ps4: nonpresent-read-retry build=1080 addr=%p page=%p pferr=%#x query=%d range=%p-%p prot=%#x result=declined\n",
                                 address, (void *)page, page_fault_error, query_rc,
                                 info.start, info.end, (unsigned)info.protection);
                        sceKernelDebugOutText(0, line);
                    }
                }

                /* A non-present user write can also race a direct-memory
                 * remap. Run 1082 faulted with x86 PF error 0x6 (user write,
                 * not present) at a store into a full 16 KiB page that the
                 * kernel immediately reported as RW. Retry that instruction
                 * once only when the kernel query covers the complete host
                 * page, confirms write permission, and the page is not
                 * executable. Do not create or widen a mapping here. */
                if (!recent && access == 1 && (page_fault_error & 7) == 6)
                {
                    static uintptr_t retried_write_pages[32];
                    static volatile unsigned int write_retry_count;
                    uintptr_t page = fault & ~(uintptr_t)(PAGE - 1);
                    unsigned int slot = (unsigned int)((page >> 14) % 32), i;
                    int claimed = 0, query_rc;

                    for (i = 0; i < 32; ++i)
                    {
                        uintptr_t current;
                        unsigned int at = (slot + i) % 32;
                        current = __atomic_load_n(&retried_write_pages[at], __ATOMIC_RELAXED);
                        if (current == page) break;
                        if (!current && __atomic_compare_exchange_n(&retried_write_pages[at],
                                                                     &current, page, 0,
                                                                     __ATOMIC_RELAXED,
                                                                     __ATOMIC_RELAXED))
                        {
                            claimed = 1;
                            break;
                        }
                    }
                    if (claimed && __atomic_add_fetch(&write_retry_count, 1,
                                                       __ATOMIC_RELAXED) <= 32)
                    {
                        char line[240];
                        memset(&info, 0, sizeof(info));
                        query_rc = sceKernelVirtualQuery(address, 1, &info, sizeof(info));
                        if (!query_rc && (uintptr_t)info.start <= page &&
                            (uintptr_t)info.end >= page + PAGE &&
                            (info.protection & PROT_WRITE) &&
                            !(info.protection & PROT_EXEC))
                        {
                            snprintf(line, sizeof(line),
                                     "wine-ps4: nonpresent-write-retry build=1083 addr=%p page=%p pferr=%#x query=%d range=%p-%p prot=%#x\n",
                                     address, (void *)page, page_fault_error, query_rc,
                                     info.start, info.end, (unsigned)info.protection);
                            sceKernelDebugOutText(0, line);
                            return 1;
                        }
                        snprintf(line, sizeof(line),
                                 "wine-ps4: nonpresent-write-retry build=1083 addr=%p page=%p pferr=%#x query=%d range=%p-%p prot=%#x result=declined\n",
                                 address, (void *)page, page_fault_error, query_rc,
                                 info.start, info.end, (unsigned)info.protection);
                        sceKernelDebugOutText(0, line);
                    }
                }

                /* Some native WoW64 write faults arrive with an x86 error
                 * code that does not match either the present (0x7) or
                 * non-present (0x6) cases above. The 1083 run's guest fault
                 * was a write into a page that the kernel independently
                 * reported as committed RW, and the generic map probe
                 * confirmed the complete 16 KiB page. If the specific
                 * handlers above did not recover it, allow one final retry
                 * only when the kernel confirms the whole host page is RW
                 * and NX. Never create or widen a mapping here. */
                if (!recent && access == 1)
                {
                    static uintptr_t retried_mapped_write_pages[32];
                    static volatile unsigned int mapped_write_retry_count;
                    uintptr_t page = fault & ~(uintptr_t)(PAGE - 1);
                    unsigned int slot = (unsigned int)((page >> 14) % 32), i;
                    int claimed = 0, query_rc;

                    for (i = 0; i < 32; ++i)
                    {
                        uintptr_t current;
                        unsigned int at = (slot + i) % 32;
                        current = __atomic_load_n(&retried_mapped_write_pages[at],
                                                  __ATOMIC_RELAXED);
                        if (current == page) break;
                        if (!current && __atomic_compare_exchange_n(&retried_mapped_write_pages[at],
                                                                     &current, page, 0,
                                                                     __ATOMIC_RELAXED,
                                                                     __ATOMIC_RELAXED))
                        {
                            claimed = 1;
                            break;
                        }
                    }
                    if (claimed && __atomic_add_fetch(&mapped_write_retry_count, 1,
                                                       __ATOMIC_RELAXED) <= 32)
                    {
                        char line[240];
                        memset(&info, 0, sizeof(info));
                        query_rc = sceKernelVirtualQuery(address, 1, &info, sizeof(info));
                        if (!query_rc && (uintptr_t)info.start <= page &&
                            (uintptr_t)info.end >= page + PAGE &&
                            (info.protection & PROT_WRITE) &&
                            !(info.protection & PROT_EXEC))
                        {
                            snprintf(line, sizeof(line),
                                     "wine-ps4: mapped-write-retry build=1084 addr=%p page=%p access=%u pferr=%#x query=%d range=%p-%p prot=%#x\n",
                                     address, (void *)page, access, page_fault_error,
                                     query_rc, info.start, info.end, (unsigned)info.protection);
                            sceKernelDebugOutText(0, line);
                            return 1;
                        }
                        snprintf(line, sizeof(line),
                                 "wine-ps4: mapped-write-retry build=1084 addr=%p page=%p access=%u pferr=%#x query=%d range=%p-%p prot=%#x result=declined\n",
                                 address, (void *)page, access, page_fault_error,
                                 query_rc, info.start, info.end, (unsigned)info.protection);
                        sceKernelDebugOutText(0, line);
                    }
                }
                unsigned int n = __atomic_add_fetch(&fault_probe_count, 1, __ATOMIC_RELAXED);
                if (n <= 32 && (access == 0 || access == 1))
                {
                    char line[192];
                    unsigned int active_count = __atomic_load_n(&exec_migration_active_count,
                                                                 __ATOMIC_ACQUIRE);
                    snprintf(line, sizeof(line),
                             "wine-ps4: exec-migrate-fault build=1064 n=%u addr=%p access=%u match=0 active=%u\n",
                             n, address, access, active_count);
                    sceKernelDebugOutText(0, line);
                }
            }
            break;
        }
        if (!probe_logged && (access == 0 || access == 1) &&
            fault >= 0x10000000 && fault < 0x70000000)
        {
            unsigned int n = __atomic_add_fetch(&fault_probe_count, 1, __ATOMIC_RELAXED);
            if (n <= 32)
            {
                char line[192];
                unsigned int active_count = __atomic_load_n(&exec_migration_active_count,
                                                             __ATOMIC_ACQUIRE);
                snprintf(line, sizeof(line),
                         "wine-ps4: exec-migrate-fault build=1064 n=%u addr=%p access=%u match=1 state=%u range=%p-%p active=%u\n",
                         n, address, access, matched_state, (void *)matched_start,
                         (void *)matched_end, active_count);
                sceKernelDebugOutText(0, line);
            }
            probe_logged = 1;
        }
        if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
        if ((now.tv_sec - began.tv_sec) * 1000000000LL + now.tv_nsec - began.tv_nsec >= timeout_ns)
        {
            capture_map_history_for_fault(fault, access, "migration-wait-timeout");
            if (probe_logged)
            {
                char line[192];
                snprintf(line, sizeof(line),
                         "wine-ps4: exec-migrate-fault build=1064 addr=%p wait=timeout range=%p-%p\n",
                         address, (void *)matched_start, (void *)matched_end);
                sceKernelDebugOutText(0, line);
            }
            return 0;
        }
        __asm__ volatile("pause" ::: "memory");
    }
    if (!waited) return 0;

    memset(&info, 0, sizeof(info));
    {
        int query_rc = sceKernelVirtualQuery(address, 1, &info, sizeof(info));
        if (query_rc || (uintptr_t)info.start > fault || (uintptr_t)info.end <= fault)
        {
            if (probe_logged)
            {
                char line[192];
                snprintf(line, sizeof(line),
                         "wine-ps4: exec-migrate-fault build=1064 addr=%p wait=settled query=%d range=%p-%p prot=%#x\n",
                         address, query_rc, info.start, info.end, (unsigned)info.protection);
                sceKernelDebugOutText(0, line);
            }
            return 0;
        }
    }
        return 0;
    if (access == 1) return !!(info.protection & PROT_WRITE);
    if (access == 8) return !!(info.protection & PROT_EXEC);
    if (info.protection & PROT_READ)
    {
        static volatile unsigned int recovered;
        unsigned int n = __atomic_add_fetch(&recovered, 1, __ATOMIC_RELAXED);
        if (n <= 32 || !(n & (n - 1)))
        {
            char line[192];
            snprintf(line, sizeof(line),
                     "wine-ps4: exec-migrate read-fault-recovered n=%u addr=%p prot=%#x\n",
                     n, address, info.protection);
            sceKernelDebugOutText(0, line);
        }
        return 1;
    }
    return 0;
}
static PwWineDmemRun runs[RUNS];
/* 0 before the self-check, 1 in use, -1 refused: every call passes. */
static int state;

/* Wine's Unix heap also consumes flexible memory, including allocations made
 * by Mesa. Keep at least 64 MiB of the largest direct-memory block available
 * for ntdll and other runtime users. If the query or allocation fails, the
 * generic heap falls back to its existing anonymous mmap path. */
enum { HEAP_SLOTS = 1 << 17, HEAP_DIRECT_HEADROOM = 64 * 1024 * 1024 };
typedef struct HeapBlock { uintptr_t address; size_t bytes; int64_t offset; } HeapBlock;
static HeapBlock heap_blocks[HEAP_SLOTS];
static unsigned heap_block_count;
static int heap_direct_fallback_logged;

static size_t heap_slot(uintptr_t address)
{
    return (size_t)((address / PAGE) * UINT64_C(0x9e3779b97f4a7c15) >> 47) & (HEAP_SLOTS - 1);
}

static void heap_log_fallback(size_t bytes, size_t available, const char *why)
{
    char line[192];

    if (__atomic_exchange_n(&heap_direct_fallback_logged, 1, __ATOMIC_RELAXED)) return;
    snprintf(line, sizeof(line),
             "wine-ps4: direct heap fallback reason=%s request=%zu available=%zu reserve=%u\n",
             why, bytes, available, (unsigned)HEAP_DIRECT_HEADROOM);
    sceKernelDebugOutText(0, line);
}

static void *heap_map(void *context, size_t bytes)
{
    size_t span, available = 0, slot;
    off_t phys = 0;
    int64_t offset;
    void *at = NULL;
    (void)context;

    if (getenv("WINE_PS5_HEAP_FLEXIBLE")) return NULL;
    if (bytes > SIZE_MAX - (PAGE - 1)) return NULL;
    span = (bytes + PAGE - 1) & ~(size_t)(PAGE - 1);
    if (heap_block_count >= HEAP_SLOTS / 2) {
        heap_log_fallback(span, available, "table-full");
        return NULL;
    }
    if (sceKernelAvailableDirectMemorySize(0, (off_t)sceKernelGetDirectMemorySize(),
                                          PAGE, &phys, &available) ||
        available < span || available - span < HEAP_DIRECT_HEADROOM) {
        heap_log_fallback(span, available, "headroom");
        return NULL;
    }
    if (allocate(NULL, span, &offset)) {
        heap_log_fallback(span, available, "allocate");
        return NULL;
    }
    if (sceKernelMapDirectMemory(&at, span, map_protection, 0, offset, PAGE) || !at) {
        (void)release(NULL, offset, span);
        heap_log_fallback(span, available, "map");
        return NULL;
    }
    for (slot = heap_slot((uintptr_t)at); heap_blocks[slot].address;
         slot = (slot + 1) & (HEAP_SLOTS - 1)) {}
    heap_blocks[slot] = (HeapBlock){ (uintptr_t)at, span, offset };
    heap_block_count++;
    return at;
}

static int heap_unmap(void *context, void *address, size_t bytes)
{
    size_t slot, hole, next;
    (void)context;
    (void)bytes;
    for (slot = heap_slot((uintptr_t)address); heap_blocks[slot].address;
         slot = (slot + 1) & (HEAP_SLOTS - 1)) {
        HeapBlock block = heap_blocks[slot];
        if (block.address != (uintptr_t)address) continue;
        (void)sceKernelMunmap((void *)block.address, block.bytes);
        (void)sceKernelReleaseDirectMemory(block.offset, block.bytes);
        heap_block_count--;
        heap_blocks[slot].address = 0;
        for (hole = slot, next = (slot + 1) & (HEAP_SLOTS - 1);
             heap_blocks[next].address; next = (next + 1) & (HEAP_SLOTS - 1)) {
            size_t home = heap_slot(heap_blocks[next].address);
            if (((next - home) & (HEAP_SLOTS - 1)) >= ((next - hole) & (HEAP_SLOTS - 1))) {
                heap_blocks[hole] = heap_blocks[next];
                heap_blocks[next].address = 0;
                hole = next;
            }
        }
        return 0;
    }
    return 1;
}

static void heap_use_direct_memory(void)
{
    static const PwWineHeapBacking heap_backing = { NULL, heap_map, heap_unmap };
    if (!getenv("WINE_PS5_HEAP_FLEXIBLE")) {
        pw_wine_heap_set_backing(&heap_backing);
        sceKernelDebugOutText(0, "wine-ps4: Unix heap prefers direct memory; 64 MiB headroom guard active\n");
    }
}

/* Freeze guest writes before snapshotting a live direct-memory range. PS4
 * can accept an mprotect call while leaving the effective permissions
 * unchanged, so do not treat the return code alone as proof. The caller has
 * already published the range in exec_migrations; guest write faults wait
 * there until migration and final protection are complete. */
static int freeze_exec_range_readonly(uintptr_t address, size_t bytes)
{
    uintptr_t probes[2] = { address, address + bytes - 1 };

    if (ps4_host_mprotect((void *)address, bytes, PROT_READ)) return -1;
    for (unsigned i = 0; i < 2; ++i)
    {
        PwPs4VirtualQueryInfo info;
        uintptr_t probe = probes[i];
        memset(&info, 0, sizeof(info));
        if (sceKernelVirtualQuery((const void *)probe, 1, &info, sizeof(info)) ||
            (uintptr_t)info.start > probe || (uintptr_t)info.end <= probe ||
            !(info.protection & PROT_READ) || (info.protection & PROT_WRITE))
        {
            (void)ps4_host_mprotect((void *)address, bytes,
                                    PROT_READ | PROT_WRITE);
            return -1;
        }
    }
    return 0;
}

static void thaw_exec_range(uintptr_t address, size_t bytes)
{
    (void)ps4_host_mprotect((void *)address, bytes,
                            PROT_READ | PROT_WRITE);
}

/* A direct-memory RX request can return success without changing the effective
 * permission. Move that allocation granule to flexible memory, preserving its
 * contents, only when the kernel query confirms RX did not take. */
/* Defined with __wine_ps5_mmap below; the migrations place the same kind of large fixed
 * anonymous mapping and hit the same shadow-memory limit. */
static void *mmap_fixed_anon_chunked(void *address, size_t bytes, int protection, int flags);

static int migrate_exec_page_to_flex_impl(uintptr_t page)
{
    /* ⚠ NOT ON THE STACK. This runs inside the SIGSEGV handler, on the
     * thread's 64 KiB signal stack (struct thread_data sits at its bottom).
     * A 16 KiB array here, inlined into __wine_ps5_mprotect, made one fault
     * cost about 20 KiB of it; two nested faults more and the frames ran
     * through thread_data (teb=0, tid=0) and off the block: Titan Quest's
     * main thread wedged on Create with rsp=0xfffffff40 (2026-11-06; the
     * same signature as ABI-v3 10142-10148). Use mmap scratch, as the range
     * migration below already does. */
    uint8_t *saved;
    void *mapped;
    int release_rc, adopt_rc, migration_slot;

    if (pw_wine_dmem_backed(&dmem, page, PAGE) != PAGE) return 0;
    migration_slot = exec_migration_begin(page, PAGE);
    if (migration_slot < 0) return -1;

    /* Another thread may have completed this exact migration before we
     * acquired the overlap claim. Recheck backing under the claim. */
    if (pw_wine_dmem_backed(&dmem, page, PAGE) != PAGE)
    {
        exec_migration_end(migration_slot);
        return 0;
    }

    saved = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (saved == MAP_FAILED)
    {
        exec_migration_end(migration_slot);
        return -1;
    }
    if (freeze_exec_range_readonly(page, PAGE))
    {
        (void)munmap(saved, PAGE);
        exec_migration_end(migration_slot);
        return -1;
    }
    memcpy(saved, (const void *)page, PAGE);
    release_rc = pw_wine_dmem_replace(&dmem, page, PAGE, 0);
    if (release_rc)
    {
        exec_rx_add(&exec_rx_metrics.release_fail, 1);
        thaw_exec_range(page, PAGE);
        (void)munmap(saved, PAGE);
        exec_migration_end(migration_slot);
        return -1;
    }

    mapped = mmap((void *)page, PAGE, PROT_READ | PROT_WRITE,
                  MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapped == MAP_FAILED || mapped != (void *)page)
    {
        exec_rx_add(&exec_rx_metrics.map_fail, 1);
        if (mapped != MAP_FAILED) (void)munmap(mapped, PAGE);
        if (!pw_wine_dmem_replace(&dmem, page, PAGE, PROT_READ | PROT_WRITE))
            memcpy((void *)page, saved, PAGE);
        (void)munmap(saved, PAGE);
        exec_migration_end(migration_slot);
        return -1;
    }

    memcpy(mapped, saved, PAGE);
    adopt_rc = pw_wine_dmem_adopt(&dmem, page, PAGE);
    if (adopt_rc)
    {
        exec_rx_add(&exec_rx_metrics.adopt_fail, 1);
        (void)munmap(mapped, PAGE);
        if (!pw_wine_dmem_replace(&dmem, page, PAGE, PROT_READ | PROT_WRITE))
            memcpy((void *)page, saved, PAGE);
        (void)munmap(saved, PAGE);
        exec_migration_end(migration_slot);
        return -1;
    }

    (void)munmap(saved, PAGE);
    exec_migration_end(migration_slot);
    return 0;
}

static int migrate_exec_page_to_flex(uintptr_t page)
{
    uint64_t started = exec_rx_now_ns();
    int rc = migrate_exec_page_to_flex_impl(page);
    exec_rx_add(&exec_rx_metrics.migrate_calls, 1);
    exec_rx_add(&exec_rx_metrics.migrate_ns, exec_rx_now_ns() - started);
    exec_rx_add(&exec_rx_metrics.migrate_bytes, PAGE);
    exec_rx_add(rc ? &exec_rx_metrics.migrate_fail : &exec_rx_metrics.migrate_ok, 1);
    return rc;
}

/* Move a contiguous direct-memory span to flexible memory in one operation.
 * The per-page version above is retained only for mixed/sparse mappings where
 * a queried range is not wholly backed by direct memory. */
static int migrate_exec_range_to_flex_impl(uintptr_t address, size_t bytes)
{
    void *saved, *mapped;
    int release_rc, adopt_rc, migration_slot;
    uint64_t started;

    if (!bytes || address % PAGE || bytes % PAGE)
        return -1;
    migration_slot = exec_migration_begin(address, bytes);
    if (migration_slot < 0) return -1;

    /* The pre-claim backing check is only a fast path. A concurrent
     * overlapping migration may have completed while this thread waited. */
    if (pw_wine_dmem_backed(&dmem, address, bytes) != bytes)
    {
        exec_migration_end(migration_slot);
        return 0;
    }

    started = exec_rx_now_ns();
    saved = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANON, -1, 0);
    exec_rx_add(&exec_rx_metrics.scratch_ns, exec_rx_now_ns() - started);
    if (saved == MAP_FAILED)
    {
        exec_rx_add(&exec_rx_metrics.scratch_fail, 1);
        exec_migration_end(migration_slot);
        return -1;
    }
    if (freeze_exec_range_readonly(address, bytes))
    {
        munmap(saved, bytes);
        exec_migration_end(migration_slot);
        return -1;
    }
    started = exec_rx_now_ns();
    memcpy(saved, (const void *)address, bytes);
    exec_rx_add(&exec_rx_metrics.copy_ns, exec_rx_now_ns() - started);

    started = exec_rx_now_ns();
    release_rc = pw_wine_dmem_replace(&dmem, address, bytes, 0);
    exec_rx_add(&exec_rx_metrics.release_ns, exec_rx_now_ns() - started);
    if (release_rc)
    {
        exec_rx_add(&exec_rx_metrics.release_fail, 1);
        thaw_exec_range(address, bytes);
        munmap(saved, bytes);
        exec_migration_end(migration_slot);
        return -1;
    }

    started = exec_rx_now_ns();
    mapped = mmap((void *)address, bytes, PROT_READ | PROT_WRITE,
                  MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    exec_rx_add(&exec_rx_metrics.map_ns, exec_rx_now_ns() - started);
    if (mapped == MAP_FAILED || mapped != (void *)address)
    {
        int restore_rc;
        exec_rx_add(&exec_rx_metrics.map_fail, 1);
        if (mapped != MAP_FAILED) (void)munmap(mapped, bytes);
        /* ⚠ restore_rc was discarded before. A hole in committed memory only
         * persists when this restore fails, so it is the one value that says
         * whether a failed migration left damage behind. */
        restore_rc = pw_wine_dmem_replace(&dmem, address, bytes,
                                         PROT_READ | PROT_WRITE);
        if (!restore_rc) memcpy((void *)address, saved, bytes);
        munmap(saved, bytes);
        exec_migration_end(migration_slot);
        return -1;
    }

    started = exec_rx_now_ns();
    memcpy(mapped, saved, bytes);
    exec_rx_add(&exec_rx_metrics.copy_ns, exec_rx_now_ns() - started);
    started = exec_rx_now_ns();
    adopt_rc = pw_wine_dmem_adopt(&dmem, address, bytes);
    exec_rx_add(&exec_rx_metrics.adopt_ns, exec_rx_now_ns() - started);
    if (adopt_rc)
    {
        exec_rx_add(&exec_rx_metrics.adopt_fail, 1);
        (void)munmap(mapped, bytes);
        if (!pw_wine_dmem_replace(&dmem, address, bytes,
                                  PROT_READ | PROT_WRITE))
            memcpy((void *)address, saved, bytes);
        munmap(saved, bytes);
        exec_migration_end(migration_slot);
        return -1;
    }
    munmap(saved, bytes);

    exec_migration_end(migration_slot);
    return 0;
}

static int migrate_exec_range_to_flex(uintptr_t address, size_t bytes)
{
    uint64_t started = exec_rx_now_ns();
    int rc = migrate_exec_range_to_flex_impl(address, bytes);
    exec_rx_add(&exec_rx_metrics.migrate_calls, 1);
    exec_rx_add(&exec_rx_metrics.migrate_ns, exec_rx_now_ns() - started);
    exec_rx_add(&exec_rx_metrics.migrate_bytes, bytes);
    exec_rx_add(rc ? &exec_rx_metrics.migrate_fail : &exec_rx_metrics.migrate_ok, 1);
    return rc;
}

/* Apply RX at the PS4 direct-memory granule, then query what the kernel
 * actually installed. If a fully direct-backed page remains non-executable,
 * migrate it to flexible memory and retry. */
static int protect_exec_page(unsigned int call, uintptr_t page, int protection)
{
    PwPs4VirtualQueryInfo info;
    int protect_rc, query_rc, migrate_rc = -2, retry_rc = -2;
    int host_retry_rc = -2;
    int effective = -1;
    size_t dmem_bytes;
    char line[256];

    /* The native 32-bit guest image lives below 4 GiB. Higher addresses are
     * Wine's 64-bit host runtime, including stacks; keep their existing
     * protection path and never replace those mappings with flexible memory. */
    if (page >= 0x100000000ULL)
        return pw_wine_dmem_protect(&dmem, page, PAGE,
                                    (unsigned)protection & 7);

    protect_rc = pw_wine_dmem_protect(&dmem, page, PAGE,
                                      (unsigned)protection & 7);
    memset(&info, 0, sizeof(info));
    query_rc = exec_rx_virtual_query((const void *)page, 1, &info, sizeof(info));
    if (!query_rc) effective = info.protection;
    dmem_bytes = pw_wine_dmem_backed(&dmem, page, PAGE);

    /* A caller-backed mapping can report success from libkernel while the
     * effective protection still omits execute. In that case retry through
     * libc's mprotect wrapper once and verify the kernel's final mapping. */
    if (!query_rc && !(effective & PROT_EXEC) && !dmem_bytes)
    {
        host_retry_rc = mprotect((void *)page, PAGE, protection);
        memset(&info, 0, sizeof(info));
        query_rc = exec_rx_virtual_query((const void *)page, 1, &info, sizeof(info));
        effective = query_rc ? -1 : info.protection;
    }

    if (!query_rc && !(effective & PROT_EXEC) && dmem_bytes == PAGE)
    {
        migrate_rc = migrate_exec_page_to_flex(page);
        if (!migrate_rc)
        {
            retry_rc = pw_wine_dmem_protect(&dmem, page, PAGE,
                                            (unsigned)protection & 7);
            memset(&info, 0, sizeof(info));
            query_rc = exec_rx_virtual_query((const void *)page, 1,
                                             &info, sizeof(info));
            if (!query_rc) effective = info.protection;
        }
    }

    if (protect_rc || query_rc || !(effective & PROT_EXEC) || migrate_rc != -2 ||
        host_retry_rc != -2)
    {
        snprintf(line, sizeof(line),
                 "wine-ps4: exec-protect-verify build=0975 call=%u page=%p dmem-before=%zu protect=%d query=%d effective=%#x host-retry=%d migrate=%d retry=%d\n",
                 call, (void *)page, dmem_bytes, protect_rc, query_rc,
                 effective, host_retry_rc, migrate_rc, retry_rc);
        sceKernelDebugOutText(0, line);
    }

    if ((protect_rc && retry_rc) || query_rc || !(effective & PROT_EXEC))
        return -1;
    return 0;
}

/* A single executable mprotect can cover a very large guest range (for
 * example, a reservation with sparse committed pages).  Migrating every
 * direct-memory granule in that request is both slow and can consume the
 * title's flexible-memory pool.  Keep the fallback bounded to ordinary
 * image-sized requests; larger ranges keep the original dmem protection
 * behavior and are logged for diagnosis. */
/* Bound on a single exec-range migration. 0 disables exec migration entirely:
 * exec_migration_allowed goes false for every nonzero request, so
 * protect_exec_range() (and the per-page fallback inside it) never runs and
 * PROT_EXEC on dmem-backed memory falls back to plain pw_wine_dmem_protect().
 * Overridable at compile time for scoped A/B tests via PW_PRX_EXTRA_CFLAGS. */
#ifndef PW_PS4_EXEC_MIGRATE_MAX_BYTES
#define PW_PS4_EXEC_MIGRATE_MAX_BYTES (16u * 1024u * 1024u)
#endif

/* 1 forces the per-page migration loop (protect_exec_page, one PAGE at a time)
 * instead of migrating a whole dmem-backed span in one go. Same end state, but
 * the window in which the range is unmapped shrinks from up to 16 MiB to 16 KiB.
 * migrate_exec_range_to_flex() snapshots, unmaps, re-mmaps and copies back with
 * no lock held, so a concurrent write inside that window is silently reverted;
 * this bounds the exposure. Scoped A/B via PW_PRX_EXTRA_CFLAGS. */
#ifndef PW_PS4_EXEC_MIGRATE_PER_PAGE_ONLY
#define PW_PS4_EXEC_MIGRATE_PER_PAGE_ONLY 0
#endif

/* ⚠ The console's debug runtime shadows flexible memory from a pool this
 * title cannot grow, and the pool is exhausted by TOTAL bytes, not by the
 * size of one request. Measured 2026-11-12 with Hollow Knight, the first
 * 64-bit game to run here: a 5.5 MiB image marked executable migrates as one
 * range, and the replacement mapping dies with
 * 0xa0020327 (SYSTEM_DEBUG_RUNTIME_SHADOW_MEMORY_ALLOC_ERROR). Splitting that
 * request into 256 KiB pieces did not help -- seven pieces (1.75 MiB) landed
 * and the eighth failed, which is what proves the limit is cumulative.
 *
 * 32-bit games never reached this: WoW64 maps their images low and in smaller
 * pieces. The PS5 has no such limit, so this is a PS4-only constraint.
 *
 * So do not migrate a large range eagerly. Above this size the range falls to
 * the per-page path below, which migrates a page at a time and leaves any
 * page that never needs PROT_EXEC in direct memory. */
#ifndef PW_PS4_EXEC_MIGRATE_RANGE_MAX
#define PW_PS4_EXEC_MIGRATE_RANGE_MAX (256u * 1024u)
#endif

static uintptr_t page_down(const void *address) { return (uintptr_t)address & ~(uintptr_t)(PAGE - 1); }
static size_t page_span(const void *address, size_t bytes)
{
    return (((uintptr_t)address + bytes + PAGE - 1) & ~(uintptr_t)(PAGE - 1)) - page_down(address);
}

/* Protect one contiguous image range, querying mapping boundaries instead of
 * probing every 16 KiB page. A fully direct-backed, non-executable mapping is
 * moved as a range; only mixed/sparse mappings fall back to page granularity. */
static int protect_exec_range(unsigned int call, uintptr_t address, size_t bytes,
                              int protection)
{
    uintptr_t at = address, end = address + bytes;
    char line[224];

    if (address % PAGE || bytes % PAGE || end < address) return -1;
    if (pw_wine_dmem_protect(&dmem, address, bytes,
                             (unsigned)protection & 7))
    {
        snprintf(line, sizeof(line),
                 "wine-ps4: exec-range batch-protect failed call=%u addr=%p bytes=%zu\n",
                 call, (void *)address, bytes);
        sceKernelDebugOutText(0, line);
    }

    while (at < end)
    {
        PwPs4VirtualQueryInfo info;
        uintptr_t next;
        size_t span, backed;
        int query_rc, effective = -1;

        memset(&info, 0, sizeof(info));
        query_rc = exec_rx_virtual_query((const void *)at, 1, &info, sizeof(info));
        if (!query_rc) effective = info.protection;
        next = !query_rc && info.end > at ? info.end : at + PAGE;
        if (next > end) next = end;
        if (next <= at) return -1;
        span = next - at;

        if (!query_rc && (effective & PROT_EXEC))
        {
            at = next;
            continue;
        }

        backed = pw_wine_dmem_backed(&dmem, at, span);
        if (!query_rc && backed == span && !PW_PS4_EXEC_MIGRATE_PER_PAGE_ONLY &&
            span <= PW_PS4_EXEC_MIGRATE_RANGE_MAX)
        {
            int migrate_rc = migrate_exec_range_to_flex(at, span);
            int retry_rc = migrate_rc ? -1 :
                pw_wine_dmem_protect(&dmem, at, span,
                                     (unsigned)protection & 7);

            memset(&info, 0, sizeof(info));
            query_rc = exec_rx_virtual_query((const void *)at, 1,
                                             &info, sizeof(info));
            effective = query_rc ? -1 : info.protection;
            if (migrate_rc || retry_rc || query_rc || !(effective & PROT_EXEC))
                return -1;
            at = next;
            continue;
        }

        if (span > PW_PS4_EXEC_MIGRATE_RANGE_MAX) {
            char line[180];
            snprintf(line, sizeof(line),
                     "wine-ps4: exec-range-per-page addr=%p span=%#zx prot=%#x backed=%#zx\n",
                     (void *)at, span, protection, backed);
            sceKernelDebugOutText(0, line);
        }

        /* A query failure or a mixture of direct and caller-backed pages
         * cannot safely be replaced as one allocation. Preserve the proven
         * per-page behavior only for this exceptional case. */
        for (uintptr_t page = at; page < next; page += PAGE)
            if (protect_exec_page(call, page, protection)) return -1;
        at = next;
    }
    return 0;
}

/* One page through every step, inside the first region, before any use. */
static int self_check(uintptr_t address)
{
    volatile uint8_t *bytes = (volatile uint8_t *)address;
    int ok = !pw_wine_dmem_replace(&dmem, address, PAGE, PW_WINE_DMEM_READ | PW_WINE_DMEM_WRITE);

    if (ok) {
        PwPs4VirtualQueryInfo info;
        int protect_rc, query_rc;
        char line[256];

        bytes[0] = 0x5a;
        bytes[PAGE - 1] = 0xa5;
        protect_rc = pw_wine_dmem_protect(&dmem, address, PAGE,
                                          PW_WINE_DMEM_READ | PW_WINE_DMEM_EXEC);
        memset(&info, 0, sizeof(info));
        query_rc = sceKernelVirtualQuery((const void *)address, 1, &info, sizeof(info));
        if (!query_rc) info.name[sizeof(info.name) - 1] = '\0';
        snprintf(line, sizeof(line),
                 "wine-ps4: dmem-exec-selfcheck build=0971 addr=%p mprotect=%d query=%d range=%p-%p prot=%#x type=%#x flags=%#x\n",
                 (void *)address, protect_rc, query_rc, (void *)info.start,
                 (void *)info.end, info.protection, info.memory_type, info.flags);
        sceKernelDebugOutText(0, line);
        ok = !protect_rc && bytes[0] == 0x5a && bytes[PAGE - 1] == 0xa5 &&
             !pw_wine_dmem_protect(&dmem, address, PAGE,
                                   PW_WINE_DMEM_READ | PW_WINE_DMEM_WRITE);
    }
    return !pw_wine_dmem_replace(&dmem, address, PAGE, 0) && ok;
}

/* Wine's PE metadata says RX for this image, but the kernel reports the
 * instruction-fetch pages as read-only. Record the effective mapping directly
 * after each executable protection operation, including whether Wine routed
 * the page through its direct-memory allocator. */
static void trace_oblivion_rx_result(unsigned int call, uintptr_t caller,
                                     uintptr_t address, size_t bytes,
                                     int protection, const char *route, int rc)
{
    static unsigned logs;
    static const uintptr_t samples[] = { 0x0049e000u, 0x004a6000u, 0x004a8000u };
    uintptr_t start = (uintptr_t)address, end = start + bytes;

    if (!(protection & PROT_EXEC) || start >= 0x004ac000u || end <= 0x00400000u ||
        __atomic_fetch_add(&logs, 1, __ATOMIC_RELAXED) >= 24) return;

    for (unsigned i = 0; i < sizeof(samples) / sizeof(samples[0]); i++)
    {
        PwPs4VirtualQueryInfo info;
        uintptr_t sample = samples[i];
        int query_rc;
        char line[256];

        if (sample < start || sample >= end) continue;
        memset(&info, 0, sizeof(info));
        query_rc = sceKernelVirtualQuery((const void *)sample, 1, &info, sizeof(info));
        if (!query_rc) info.name[sizeof(info.name) - 1] = '\0';
        snprintf(line, sizeof(line),
                 "wine-ps4: image-rx-result build=0971 call=%u caller=%p request=%p+%zu prot=%#x route=%s rc=%d sample=%p dmem=%zu query=%d mapping=%p-%p effective=%#x type=%#x flags=%#x\n",
                 call, (void *)caller, (void *)address, bytes, protection, route, rc,
                 (void *)sample, pw_wine_dmem_backed(&dmem, sample, PAGE),
                 query_rc, (void *)info.start, (void *)info.end,
                 info.protection, info.memory_type, info.flags);
        sceKernelDebugOutText(0, line);
    }
}

/* Observe, but never repair, the affected image pages on the existing Wine
 * memory-stat heartbeat. This distinguishes a page that never becomes RX from
 * one whose effective protection changes between samples. */
static void watch_oblivion_rx_pages(unsigned int sample)
{
    static const uintptr_t pages[] = { 0x0049e000u, 0x004a6000u, 0x004a8000u };
    static int initialized[sizeof(pages) / sizeof(pages[0])];
    static int last_query[sizeof(pages) / sizeof(pages[0])];
    static int last_protection[sizeof(pages) / sizeof(pages[0])];
    static uintptr_t last_start[sizeof(pages) / sizeof(pages[0])];
    static uintptr_t last_end[sizeof(pages) / sizeof(pages[0])];

    for (unsigned i = 0; i < sizeof(pages) / sizeof(pages[0]); i++)
    {
        PwPs4VirtualQueryInfo info;
        int query_rc;
        char line[256];

        memset(&info, 0, sizeof(info));
        query_rc = sceKernelVirtualQuery((const void *)pages[i], 1, &info, sizeof(info));
        if (!query_rc) info.name[sizeof(info.name) - 1] = '\0';
        if (initialized[i] && query_rc == last_query[i] &&
            (query_rc || (info.protection == last_protection[i] &&
                          info.start == last_start[i] && info.end == last_end[i])))
            continue;

        snprintf(line, sizeof(line),
                 "wine-ps4: image-rx-watch build=0971 sample=%u page=%p dmem=%zu query=%d mapping=%p-%p effective=%#x type=%#x flags=%#x\n",
                 sample, (void *)pages[i], pw_wine_dmem_backed(&dmem, pages[i], PAGE),
                 query_rc, (void *)info.start, (void *)info.end,
                 info.protection, info.memory_type, info.flags);
        sceKernelDebugOutText(0, line);
        initialized[i] = 1;
        last_query[i] = query_rc;
        last_protection[i] = info.protection;
        last_start[i] = info.start;
        last_end[i] = info.end;
    }
}

/* ntdll's reserved area [base, +size), already reserved: backed by direct
 * memory from now on. ntdll also gives each reservation it makes at a fixed
 * address outside those areas: the console does not back a bare reservation
 * when it is protected, so committing one would leave it without memory.
 * Such a region is dropped again when it is unmapped. */
/* ⚠ A SILENT hang needs a sampler, not another event log. Hollow Knight (2026-11-12) brings the
 * GPU up, compiles two pipelines, starts 41 threads and migrates 17 executable ranges, all without
 * an error -- and then every layer goes quiet for minutes. Nothing in this file logs on a thread
 * that is simply blocked, so there was nothing to read.
 *
 * This thread says, once every two seconds, whether the title is still alive and what the exec
 * machinery is holding. A heartbeat that stops tells you when the process died; one that continues
 * with active=0 says the block is somewhere else entirely; one stuck with active>0 names a
 * migration that never finished. Costs one line per two seconds. */
/* ---- 64-bit guest thread sampler --------------------------------------
 *
 * Hollow Knight, the first 64-bit title here, wedges with every host-side layer provably
 * healthy: Wine's loop ticks at 60 Hz, 353 migrations succeeded with none active, 320 MB
 * flexible memory free, the GPU compiled its pipelines -- and the guest's own counters
 * (mmap=281 mprotect=1782 images=48) are FROZEN with frames_put=0. The guest is spinning in
 * user code, making no syscalls and taking no faults, so nothing in this port ever sees it.
 *
 * PW_EXCEPTION32 answers this for 32-bit guests, but it is #ifdef __i386__ and fault-driven;
 * a thread that never faults produces nothing. So interrupt it instead: ITIMER_PROF charges
 * CPU time, so SIGPROF lands on whichever thread is actually burning it -- exactly the one
 * worth sampling -- and the handler reads mc_rip/mc_rsp out of the ucontext.
 *
 * ⚠ The sample count is reported by the heartbeat on purpose. If it stays 0 the console did
 * not deliver the timer signal, and the absence of samples says nothing about the guest.
 * Measure the instrument before trusting its silence. */
#include "../freebsd-compat/machine/fbsd_mcontext.h"

#define PW_GUEST_SAMPLE_OFFSET 64        /* mcontext within ucontext, measured (fault_probe) */
#define PW_GUEST_SAMPLE_MAX    400       /* bounded: a wedge would otherwise log forever */

static volatile unsigned int guest_samples;
static volatile unsigned int guest_sample_logged;

static void guest_sample_handler(int sig, siginfo_t *info, void *uc)
{
    const struct pw_fbsd_mcontext *mc;
    char line[160];
    unsigned int n;

    (void)sig; (void)info;
    if (!uc) return;
    n = __atomic_add_fetch(&guest_samples, 1, __ATOMIC_RELEASE);
    if (n > PW_GUEST_SAMPLE_MAX) return;
    mc = (const struct pw_fbsd_mcontext *)((const char *)uc + PW_GUEST_SAMPLE_OFFSET);
    /* mc_len is the console's 1152, not FreeBSD 9's 800: it validates the offset is right. */
    if (mc->mc_len != 1152) {
        if (__atomic_fetch_add(&guest_sample_logged, 1, __ATOMIC_RELEASE)) return;
        snprintf(line, sizeof(line), "wine-ps4: guest-sample bad mcontext len=%lld at uc+%d\n",
                 (long long)mc->mc_len, PW_GUEST_SAMPLE_OFFSET);
        sceKernelDebugOutText(0, line);
        return;
    }
    snprintf(line, sizeof(line),
             "wine-ps4: guest-sample %u tid=%lu rip=%llx rsp=%llx rbp=%llx trapno=%u cs=%llx\n",
             n, glue_tid(), (unsigned long long)mc->mc_rip, (unsigned long long)mc->mc_rsp,
             (unsigned long long)mc->mc_rbp, (unsigned)mc->mc_trapno,
             (unsigned long long)mc->mc_cs);
    sceKernelDebugOutText(0, line);

    /* libkernel is Sony's and carries no symbols, so a RIP inside it names nothing. The return
     * addresses above it do: they point back into ntdll/the app PRX, which this port builds and
     * can symbolize. Walk a bounded window of the stack and print the words -- one caller is
     * enough to say WHICH wait the thread is parked in. Only for the first few samples: a wedged
     * thread repeats the same stack forever and flooding klog buys nothing. */
    if (n <= 3) {
        const uint64_t *sp = (const uint64_t *)(uintptr_t)mc->mc_rsp;
        char words[200];
        int used = 0, i;

        for (i = 0; i < 12 && used < (int)sizeof(words) - 24; i++) {
            /* Only plausible code pointers: the PRX text range starts at 0x800000000 here. */
            uint64_t w = sp[i];
            if (w < 0x800000000ull || w > 0x900000000ull) continue;
            used += snprintf(words + used, sizeof(words) - used, " %llx", (unsigned long long)w);
        }
        snprintf(line, sizeof(line), "wine-ps4: guest-stack %u tid=%lu callers:%s\n",
                 n, glue_tid(), used ? words : " none");
        sceKernelDebugOutText(0, line);
    }
}

/* The sampler's RIPs mean nothing without knowing which module each address is in, and the
 * module list is only printed by the console's fatal handler -- which never runs for a hang.
 * Print it once at startup instead. Offsets, not the SDK struct, because pw_wine_dl_ps4.c
 * already measured the layout and declaring our own shape collides with libkernel.h:
 *     size_t size 0x00 | char name[256] 0x08 | segmentInfo[4] 0x108 (16B each) | count 0x148 */
typedef int32_t PwOrbisModule;
extern int32_t sceKernelGetModuleList(PwOrbisModule *array, size_t size, size_t *available);
extern int32_t sceKernelGetModuleInfo(PwOrbisModule handle, void *info);

static void guest_log_module_map(void)
{
    PwOrbisModule handles[128];
    size_t count = 0, i;
    char line[320];

    if (sceKernelGetModuleList(handles, sizeof(handles) / sizeof(handles[0]), &count)) return;
    for (i = 0; i < count; i++) {
        unsigned char info[0x160];
        uint64_t base;
        uint32_t size;

        memset(info, 0, sizeof(info));
        *(size_t *)(void *)info = sizeof(info);
        if (sceKernelGetModuleInfo(handles[i], info)) continue;
        memcpy(&base, info + 0x108, sizeof(base));
        memcpy(&size, info + 0x110, sizeof(size));
        snprintf(line, sizeof(line), "wine-ps4: module %.72s base=%llx size=%x\n",
                 (const char *)(info + 0x08), (unsigned long long)base, size);
        sceKernelDebugOutText(0, line);
    }
}

/* Returns 0 when both the handler and the timer were accepted. */
static int guest_sampler_start(void)
{
    struct sigaction sa;
    struct itimerval it;
    char line[160];
    int act_rc, timer_rc;

    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = guest_sample_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    act_rc = sigaction(SIGALRM, &sa, NULL);

    /* ⚠ ITIMER_REAL, not ITIMER_PROF. PROF charges CPU time, so it only ever lands on the
     * busiest thread -- with Hollow Knight that was this port's own pw_present_scale loop
     * running at 60 Hz on frames_put=0, while the thread we actually wanted sat BLOCKED and
     * burned nothing. Wall clock delivers regardless of who is running. tid= on each sample
     * says which thread answered, so "one thread, never moving" is distinguishable from
     * "every thread, busy". */
    it.it_interval.tv_sec = 0; it.it_interval.tv_usec = 100000;   /* 10 Hz */
    it.it_value = it.it_interval;
    timer_rc = setitimer(ITIMER_REAL, &it, NULL);

    snprintf(line, sizeof(line), "wine-ps4: guest-sampler sigaction=%d setitimer=%d errno=%d\n",
             act_rc, timer_rc, errno);
    sceKernelDebugOutText(0, line);
    guest_log_module_map();
    return act_rc || timer_rc;
}

static void *exec_heartbeat(void *unused)
{
    unsigned long long beat = 0;
    char line[240];

    (void)unused;
    for (;;) {
        struct timespec nap = { 2, 0 };
        nanosleep(&nap, NULL);
        snprintf(line, sizeof(line),
                 "wine-ps4: heartbeat %llu guest_samples=%u migrations_active=%u migrate_ok=%llu "
                 "migrate_fail=%llu map_fail=%llu scratch_fail=%llu release_fail=%llu adopt_fail=%llu\n",
                 ++beat, __atomic_load_n(&guest_samples, __ATOMIC_ACQUIRE),
                 __atomic_load_n(&exec_migration_active_count, __ATOMIC_ACQUIRE),
                 (unsigned long long)__atomic_load_n(&exec_rx_metrics.migrate_ok, __ATOMIC_ACQUIRE),
                 (unsigned long long)__atomic_load_n(&exec_rx_metrics.migrate_fail, __ATOMIC_ACQUIRE),
                 (unsigned long long)__atomic_load_n(&exec_rx_metrics.map_fail, __ATOMIC_ACQUIRE),
                 (unsigned long long)__atomic_load_n(&exec_rx_metrics.scratch_fail, __ATOMIC_ACQUIRE),
                 (unsigned long long)__atomic_load_n(&exec_rx_metrics.release_fail, __ATOMIC_ACQUIRE),
                 (unsigned long long)__atomic_load_n(&exec_rx_metrics.adopt_fail, __ATOMIC_ACQUIRE));
        sceKernelDebugOutText(0, line);
    }
    return NULL;
}

void __wine_ps5_dmem_region(void *base, size_t size)
{
    int add_rc;
    if (!state && pw_wine_dmem_init(&dmem, &ops, runs, RUNS, 1)) state = -1;
    if (state < 0) return;
    add_rc = pw_wine_dmem_add_region(&dmem, (uintptr_t)base, size, 1);
    trace_object_mapping("register-region", (uintptr_t)base, size, 1,
                         add_rc, "wine-dmem-region");
    if (add_rc) {
        fprintf(stderr, "wine-ps5: no direct memory region for %p, %zu bytes\n", base, size);
        return;
    }
    if (!state) {
        state = self_check((uintptr_t)base) ? 1 : -1;
        fprintf(stderr, "wine-ps5: direct memory %s for anonymous memory (region %p, %zu MiB)\n",
                state > 0 ? "in use" : "refused", base, size >> 20);
        if (state > 0) {
            static int beating;
            heap_use_direct_memory();
            if (!beating) {
                pthread_t beat;
                pthread_attr_t attr;
                if (!pthread_attr_init(&attr)) {
                    (void)pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
                    beating = !pthread_create(&beat, &attr, exec_heartbeat, NULL);
                    if (beating) (void)guest_sampler_start();
                    pthread_attr_destroy(&attr);
                }
            }
        }
    }
}

/* ⚠ A fixed anonymous mapping large enough to need a big shadow-memory block
 * kills the process inside libkernel's mmap with
 * 0xa0020327 (SYSTEM_DEBUG_RUNTIME_SHADOW_MEMORY_ALLOC_ERROR). Hollow Knight
 * dies about eight seconds into launch on a 0x570000 request at
 * 0x6ffffb404000 with flags 0x1012, and 1062 died the same way on 0xc0000 at
 * 0x6ffffff30000 (docs/HANDOFF-2026-10-26.md, recorded there as "the full
 * flexible-mapping fallback is not viable on this PS4 runtime"). Per-page
 * (16 KiB) flexible mappings do work, so the limit is per request, not a
 * global pool.
 *
 * Two things follow. First, trace_vm_api only fills a ring buffer that a
 * fault handler later dumps, so a request that never returns is never
 * recorded: say it to klog BEFORE the call, or the next crash is as blind as
 * the last. Second, ask for it in pieces the runtime can shadow. */
enum { PW_SHADOW_SAFE_CHUNK = 0x40000 };   /* 256 KiB: 16x the page that is known to work */

static void trace_big_fixed_anon(const char *stage, uintptr_t address, size_t bytes,
                                 int protection, int flags, uintptr_t caller, int rc)
{
    char line[200];
    snprintf(line, sizeof(line),
             "wine-ps4: big-fixed-anon %s addr=%p bytes=%#zx prot=%#x flags=%#x caller=%p rc=%d\n",
             stage, (void *)address, bytes, protection, flags, (void *)caller, rc);
    sceKernelDebugOutText(0, line);
}

/* mmap a large fixed anonymous range in shadow-sized pieces. All or nothing:
 * a failed piece unmaps the ones already placed, so the caller still sees a
 * single failed mapping rather than a half-built one. */
static void *mmap_fixed_anon_chunked(void *address, size_t bytes, int protection, int flags)
{
    uintptr_t at = (uintptr_t)address, end = at + bytes;
    uintptr_t cursor = at;

    while (cursor < end) {
        size_t piece = end - cursor;
        void *mapped;

        if (piece > PW_SHADOW_SAFE_CHUNK) piece = PW_SHADOW_SAFE_CHUNK;
        mapped = mmap((void *)cursor, piece, protection, flags, -1, 0);
        if (mapped == MAP_FAILED || mapped != (void *)cursor) {
            if (mapped != MAP_FAILED) (void)munmap(mapped, piece);
            if (cursor > at) (void)munmap((void *)at, cursor - at);
            errno = ENOMEM;
            return MAP_FAILED;
        }
        cursor += piece;
    }
    return address;
}

void *__wine_ps5_mmap(void *address, size_t bytes, int protection, int flags, int fd, off_t offset)
{
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    uintptr_t at = page_down(address), end = at + page_span(address, bytes);
    size_t piece;
    int status = 0;

    if (state <= 0 || !(flags & MAP_FIXED) || (uintptr_t)address != at ||
        (!pw_wine_dmem_split(&dmem, at, end - at, &piece) && piece == end - at))
    {
        const int big_fixed_anon = (flags & MAP_FIXED) && (flags & MAP_ANON) &&
                                   fd < 0 && bytes > PW_SHADOW_SAFE_CHUNK;
        void *mapped;

        if (big_fixed_anon) {
            trace_big_fixed_anon("begin", (uintptr_t)address, bytes, protection, flags, caller, 0);
            mapped = mmap_fixed_anon_chunked(address, bytes, protection, flags);
            trace_big_fixed_anon("end", (uintptr_t)address, bytes, protection, flags, caller,
                                 mapped == MAP_FAILED ? -1 : 0);
        } else {
            mapped = mmap(address, bytes, protection, flags, fd, offset);
        }
        trace_object_mapping("mmap", (uintptr_t)address, bytes, protection,
                             mapped == MAP_FAILED ? -1 : 0, "host-pass");
        trace_vm_api("api-mmap", (uintptr_t)address, bytes, protection, flags,
                     fd, offset, mapped == MAP_FAILED ? -1 : 0, "host-pass", caller);
        return mapped;
    }
    if (!(flags & MAP_ANON)) {
        void *mapped;

        /* A private file view (an image section) is read into direct
         * memory instead: ntdll falls back to pread when mmap reports
         * ENODEV. On the console a fixed file mapping over a reservation
         * does not give the requested pages. */
        if (!(flags & MAP_SHARED)) {
            errno = ENODEV;
            trace_vm_api("api-mmap", (uintptr_t)address, bytes, protection, flags,
                         fd, offset, -1, "private-file-refused", caller);
            return MAP_FAILED;
        }
        /* Shared memory stays a file mapping, over what is there, as
         * before direct memory; only the exact address is accepted. */
        mapped = mmap(address, bytes, protection, flags, fd, offset);
        trace_object_mapping("mmap-file", (uintptr_t)address, bytes,
                             protection, mapped == MAP_FAILED ? -1 : 0,
                             "host-file");
        if (mapped == MAP_FAILED) {
            trace_vm_api("api-mmap", (uintptr_t)address, bytes, protection, flags,
                         fd, offset, -1, "shared-file", caller);
            return MAP_FAILED;
        }
        if (mapped != address) {
            munmap(mapped, bytes);
            errno = ENOMEM;
            trace_vm_api("api-mmap", (uintptr_t)address, bytes, protection, flags,
                         fd, offset, -1, "shared-file-wrong-address", caller);
            return MAP_FAILED;
        }
        for (; at < end; at += piece)
            if (pw_wine_dmem_split(&dmem, at, end - at, &piece)) (void)pw_wine_dmem_adopt(&dmem, at, piece);
        trace_vm_api("api-mmap", (uintptr_t)address, bytes, protection, flags,
                     fd, offset, 0, "shared-file", caller);
        return address;
    }
    for (; at < end; at += piece)
        if (pw_wine_dmem_split(&dmem, at, end - at, &piece))
            status |= pw_wine_dmem_replace(&dmem, at, piece, (unsigned)protection & 7);
        else
        {
            void *mapped = mmap((void *)at, piece, protection, flags, -1, 0);
            trace_object_mapping("mmap-piece", at, piece, protection,
                                 mapped == MAP_FAILED ? -1 : 0, "host-piece");
            if (mapped == MAP_FAILED) status = -1;
        }
    trace_object_mapping("mmap-result", (uintptr_t)address, bytes, protection,
                         status, "wine-dmem-wrapper");
    trace_vm_api("api-mmap", (uintptr_t)address, bytes, protection, flags,
                 fd, offset, status ? -1 : 0, "wine-dmem-wrapper", caller);
    if (!status) return address;
    errno = ENOMEM;
    return MAP_FAILED;
}

/* Owned pages give their direct memory back, then their address space. */
int __wine_ps5_munmap(void *address, size_t bytes)
{
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    uintptr_t at = page_down(address), end = at + page_span(address, bytes);
    size_t piece;
    int status = 0;

    if (state <= 0)
    {
        int rc = munmap(address, bytes);
        trace_object_mapping("munmap", (uintptr_t)address, bytes, 0, rc,
                             "host-pass");
        trace_vm_api("api-munmap", (uintptr_t)address, bytes, 0, 0, -1, 0,
                     rc, "host-pass", caller);
        return rc;
    }
    for (; at < end; at += piece)
        if (pw_wine_dmem_split(&dmem, at, end - at, &piece))
        {
            int replace_rc = pw_wine_dmem_replace(&dmem, at, piece, 0);
            int unmap_rc = sceKernelMunmap((void *)at, piece);
            trace_object_mapping("munmap-dmem", at, piece, 0, unmap_rc,
                                 replace_rc ? "replace-failed" : "sce");
            status |= replace_rc | unmap_rc;
        }
        else
        {
            int rc = munmap((void *)at, piece);
            trace_object_mapping("munmap-host-piece", at, piece, 0, rc, "host");
            status |= rc;
        }
    trace_object_mapping("munmap-result", (uintptr_t)address, bytes, 0,
                         status, "wine-dmem-wrapper");
    pw_wine_dmem_remove_regions(&dmem, page_down(address), page_span(address, bytes));
    if (status) errno = EINVAL;
    trace_vm_api("api-munmap", (uintptr_t)address, bytes, 0, 0, -1, 0,
                 status ? -1 : 0, "wine-dmem-wrapper", caller);
    return status ? -1 : 0;
}

static int ps4_mprotect_impl(void *address, size_t bytes, int protection)
{
    static unsigned trace_calls;
    static unsigned trace_fault_page_calls;
    static unsigned exec_range_logs;
    uintptr_t at = page_down(address), end = at + page_span(address, bytes);
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    size_t piece;
    int status = 0;
    unsigned call = __atomic_fetch_add(&trace_calls, 1, __ATOMIC_RELAXED) + 1;
    uintptr_t start = (uintptr_t)address;
    int trace_force_exec = start < 0x1000110000ULL && end > 0x1000000000ULL;
    int fault_page = start <= 0x004a8330u && bytes > 0x004a8330u - start;
    int trace = call <= 16 || trace_force_exec;
    int exec_migration_allowed = bytes <= PW_PS4_EXEC_MIGRATE_MAX_BYTES;

    if ((protection & PROT_EXEC) && start < 0x100000000ULL &&
        (bytes >= 1024u * 1024u || call <= 16) &&
        __atomic_fetch_add(&exec_range_logs, 1, __ATOMIC_RELAXED) < 64)
    {
        char line[256];
        snprintf(line, sizeof(line),
                 "wine-ps4: exec-range build=0974 call=%u addr=%p bytes=%zu prot=%#x caller=%p fallback=%s\n",
                 call, address, bytes, protection, (void *)caller,
                 exec_migration_allowed ? "bounded" : "skip-large");
        sceKernelDebugOutText(0, line);
    }

    if (fault_page && __atomic_fetch_add(&trace_fault_page_calls, 1, __ATOMIC_RELAXED) < 32)
        trace = 1;
    if (trace)
    {
        char line[224];
        snprintf(line, sizeof(line),
                 "wine-ps4: mprotect-trace build=0971 enter call=%u addr=%p bytes=%zu prot=%#x state=%d fault_page=%d\n",
                 call, address, bytes, protection, state, fault_page);
        sceKernelDebugOutText(0, line);
    }

    /* Keep the original target-range dispatch marker alongside the build ID. */
    if (fault_page)
    {
        char line[192];
        snprintf(line, sizeof(line),
                 "wine-ps4: fault mprotect dispatch addr=%p bytes=%zu prot=%#x state=%d\n",
                 address, bytes, protection, state);
        sceKernelDebugOutText(0, line);
    }

    if (state <= 0)
    {
        status = ps4_host_mprotect(address, bytes, protection);
        trace_oblivion_rx_result(call, caller, (uintptr_t)address, bytes,
                                 protection, "host", status);
        if (trace)
        {
            char line[160];
            snprintf(line, sizeof(line),
                     "wine-ps4: mprotect-trace build=0971 leave call=%u rc=%d path=host\n",
                     call, status);
            sceKernelDebugOutText(0, line);
        }
        return status;
    }
    for (; at < end; at += piece)
    {
        int backed;
        if (trace_force_exec)
            force_exec_trace("wine-ps4: force-exec mprotect split begin addr=%p remaining=%zu prot=%#x\n",
                             (void *)at, (size_t)(end - at), protection);
        backed = pw_wine_dmem_split(&dmem, at, end - at, &piece);
        if (trace_force_exec)
            force_exec_trace("wine-ps4: force-exec mprotect split result addr=%p bytes=%zu backed=%d\n",
                             (void *)at, piece, backed);
        if (backed)
        {
            int rc = 0;

            if (trace_force_exec)
                force_exec_trace("wine-ps4: force-exec dmem protect begin addr=%p bytes=%zu prot=%#x\n",
                                 (void *)at, piece, protection);
            if ((protection & PROT_EXEC) && exec_migration_allowed)
                rc = protect_exec_range(call, at, piece, protection);
            else
                rc = pw_wine_dmem_protect(&dmem, at, piece,
                                          (unsigned)protection & 7);
            if (trace_force_exec)
                force_exec_trace("wine-ps4: force-exec dmem protect result addr=%p bytes=%zu rc=%d\n",
                                 (void *)at, piece, rc);
            trace_oblivion_rx_result(call, caller, at, piece, protection, "dmem", rc);
            status |= rc;
        }
        else
        {
            if (trace_force_exec)
                force_exec_trace("wine-ps4: force-exec host protect begin addr=%p bytes=%zu prot=%#x\n",
                                 (void *)at, piece, protection);
            int rc = ps4_host_mprotect((void *)at, piece, protection);
            if (trace_force_exec)
                force_exec_trace("wine-ps4: force-exec host protect result addr=%p bytes=%zu rc=%d\n",
                                 (void *)at, piece, rc);
            trace_oblivion_rx_result(call, caller, at, piece, protection, "host", rc);
            status |= rc;
        }
    }
    if (status) errno = ENOMEM;
    status = status ? -1 : 0;
    if (trace)
    {
        char line[160];
        snprintf(line, sizeof(line),
                 "wine-ps4: mprotect-trace build=0971 leave call=%u rc=%d path=dmem\n",
                 call, status);
        sceKernelDebugOutText(0, line);
    }
    return status;
}

int __wine_ps5_mprotect(void *address, size_t bytes, int protection)
{
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    uint64_t started = exec_rx_now_ns();
    int rc = ps4_mprotect_impl(address, bytes, protection);
    uint64_t elapsed = exec_rx_now_ns() - started;
    uint64_t call_no = __atomic_add_fetch(&exec_rx_protect_total, 1, __ATOMIC_RELAXED);
    exec_rx_add(&exec_rx_metrics.protect_calls, 1);
    exec_rx_add(&exec_rx_metrics.protect_ns, elapsed);
    if (protection & PROT_EXEC)
    {
        exec_rx_add(&exec_rx_metrics.exec_calls, 1);
        exec_rx_add(&exec_rx_metrics.exec_ns, elapsed);
    }
    trace_vm_api("api-mprotect", (uintptr_t)address, bytes, protection, 0,
                 -1, 0, rc, "wine-dmem-wrapper", caller);
    exec_rx_report(call_no);
    return rc;
}

/* For the title's log, as __wine_virtual_stats: direct memory backed now and
 * at most, its runs and refused calls, the heap's mapped and peak mapped
 * bytes, then the direct memory backed below 4 GiB now and at most. Returns
 * how many counters there are. */
unsigned int __wine_ps5_memory_stats(uint64_t *out, unsigned int count)
{
    static unsigned int page_watch_sample, page_watch_logs;
    static int page_watch_initialized, page_watch_query, page_watch_protection;
    static uintptr_t page_watch_start, page_watch_end;
    PwWineDmemStats dmem_stats = { 0 };
    PwWineHeapStats heap_stats;
    PwWineHeapFailures heap_failures = { 0 };
    uint64_t values[14];

    if (state > 0) pw_wine_dmem_stats(&dmem, &dmem_stats);
    pw_wine_heap_stats(&heap_stats);
    pw_wine_heap_failures(&heap_failures);
    values[0] = dmem_stats.backed_bytes;
    values[1] = dmem_stats.peak_backed_bytes;
    values[2] = dmem_stats.runs;
    values[3] = dmem_stats.failures;
    values[4] = heap_stats.mapped_bytes;
    values[5] = heap_stats.peak_mapped_bytes;
    values[6] = dmem_stats.low_backed_bytes;
    values[7] = dmem_stats.peak_low_backed_bytes;
    values[8] = heap_stats.failures;
    values[9] = heap_failures.last_failed_bytes;
    values[10] = heap_failures.last_failure_reason;
    values[11] = heap_failures.backing_refusals;
    values[12] = heap_failures.last_map_bytes;
    values[13] = heap_failures.last_map_errno;
    for (unsigned int i = 0; i < count && i < 14; i++) out[i] = values[i];

    watch_oblivion_rx_pages(++page_watch_sample);

    /* The 0967 run found the page containing Oblivion's entry path already
     * read-only at the first sample, although Wine's PE metadata requests RX.
     * Repair only that exact 16-KiB anonymous mapping from this existing
     * heartbeat. This also distinguishes a false-success kernel mprotect from
     * an effective protection update without another thread or per-frame
     * queries. */
    {
        static unsigned int repair_attempts;
        PwPs4VirtualQueryInfo info;
        unsigned int sample = page_watch_sample;
        int query, protection = -1;
        uintptr_t start = 0, end = 0;

        memset(&info, 0, sizeof(info));
        query = sceKernelVirtualQuery((const void *)0x004a8330u, 1, &info, sizeof(info));
        if (!query)
        {
            protection = info.protection;
            start = info.start;
            end = info.end;
            info.name[sizeof(info.name) - 1] = '\0';
        }

        if (!query && start == 0x004a8000u && end == 0x004ac000u &&
            (protection & PROT_READ) && !(protection & PROT_EXEC) &&
            repair_attempts < 8)
        {
            int attempt = ++repair_attempts;
            int before = protection;
            int sce_rc, libc_rc = -999, verify_rc;
            int verify_protection = -1;
            char line[256];

            sce_rc = sceKernelMprotect((const void *)0x004a8000u, PAGE,
                                       PROT_READ | PROT_EXEC);
            memset(&info, 0, sizeof(info));
            verify_rc = sceKernelVirtualQuery((const void *)0x004a8330u, 1,
                                              &info, sizeof(info));
            if (!verify_rc)
            {
                info.name[sizeof(info.name) - 1] = '\0';
                verify_protection = info.protection;
            }
            if (verify_rc || !(verify_protection & PROT_EXEC))
            {
                libc_rc = mprotect((void *)0x004a8000u, PAGE,
                                   PROT_READ | PROT_EXEC);
                memset(&info, 0, sizeof(info));
                verify_rc = sceKernelVirtualQuery((const void *)0x004a8330u, 1,
                                                  &info, sizeof(info));
                if (!verify_rc)
                {
                    info.name[sizeof(info.name) - 1] = '\0';
                    verify_protection = info.protection;
                }
                else verify_protection = -1;
            }
            snprintf(line, sizeof(line),
                     "wine-ps4: fault-page-rx-repair build=0968 attempt=%u before=%#x sce=%d libc=%d verify=%d after=%#x\n",
                     attempt, before, sce_rc, libc_rc, verify_rc,
                     verify_protection);
            sceKernelDebugOutText(0, line);
            query = verify_rc;
            protection = verify_protection;
            if (!query)
            {
                start = info.start;
                end = info.end;
            }
        }
        if ((!page_watch_initialized || query != page_watch_query ||
             protection != page_watch_protection || start != page_watch_start ||
             end != page_watch_end) && page_watch_logs < 32)
        {
            char line[256];
            snprintf(line, sizeof(line),
                     "wine-ps4: fault-page-prot-watch build=0968 sample=%u query=%d range=%p-%p prot=%#x type=%#x flags=%#x name=%s\n",
                     sample, query, (void *)start, (void *)end, protection,
                     query ? 0 : info.memory_type, query ? 0 : info.flags,
                     query ? "?" : info.name);
            sceKernelDebugOutText(0, line);
            page_watch_logs++;
        }
        page_watch_initialized = 1;
        page_watch_query = query;
        page_watch_protection = protection;
        page_watch_start = start;
        page_watch_end = end;
    }
    return 14;
}
