/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Optional direct-memory backing for wineserver's private pw_wine_heap copy.
 * Kept off unless PW_WINESERVER_HEAP_DIRECT=1; on fallback the heap retains
 * its ordinary anonymous mapping behavior. */
#include "pw_wine_heap.h"
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

extern int sceKernelAllocateMainDirectMemory(size_t bytes, size_t alignment,
                                             int type, int64_t *offset);
extern int sceKernelMapDirectMemory(void **address, size_t bytes, int protection,
                                   int flags, int64_t offset, size_t alignment);
extern int sceKernelMunmap(void *address, size_t bytes);
extern int sceKernelReleaseDirectMemory(int64_t offset, size_t bytes);
extern int sceKernelAvailableDirectMemorySize(int64_t start, int64_t end,
                                              size_t alignment, int64_t *address,
                                              size_t *bytes);
extern size_t sceKernelGetDirectMemorySize(void);
extern int sceKernelDebugOutText(int channel, const char *text);

enum { PAGE = 0x4000, PROT_CPU_RW = 0x03, MEMORY_WB_ONION = 0,
       SLOT_COUNT = 4096, DIRECT_HEADROOM = 64 * 1024 * 1024 };
typedef struct Block { uintptr_t address; size_t bytes; int64_t offset; } Block;
static Block blocks[SLOT_COUNT];
static uint64_t direct_live, direct_peak, maps, unmaps, refusals;
static int enabled, traced;

static void report(const char *reason)
{
    PwWineHeapStats hs = {0};
    PwWineHeapFailures hf = {0};
    char line[320];
    if (!__atomic_load_n(&traced, __ATOMIC_RELAXED)) return;
    pw_wine_heap_stats(&hs);
    pw_wine_heap_failures(&hf);
    snprintf(line, sizeof(line),
             "wineserver-heap: %s live=%llu mapped=%llu peak=%llu alloc=%llu fail=%llu fallback=%llu direct=%llu direct_peak=%llu maps=%llu unmaps=%llu refusals=%llu\n",
             reason, (unsigned long long)hs.live_bytes,
             (unsigned long long)hs.mapped_bytes,
             (unsigned long long)hs.peak_mapped_bytes,
             (unsigned long long)hs.allocations,
             (unsigned long long)hs.failures,
             (unsigned long long)hf.backing_refusals,
             (unsigned long long)__atomic_load_n(&direct_live, __ATOMIC_RELAXED),
             (unsigned long long)__atomic_load_n(&direct_peak, __ATOMIC_RELAXED),
             (unsigned long long)__atomic_load_n(&maps, __ATOMIC_RELAXED),
             (unsigned long long)__atomic_load_n(&unmaps, __ATOMIC_RELAXED),
             (unsigned long long)__atomic_load_n(&refusals, __ATOMIC_RELAXED));
    sceKernelDebugOutText(0, line);
}

static void *map_direct(void *context, size_t bytes)
{
    size_t span, available = 0, slot;
    int64_t phys = 0, offset = 0;
    void *at = NULL;
    (void)context;
    if (!enabled || bytes > SIZE_MAX - (PAGE - 1)) return NULL;
    span = (bytes + PAGE - 1) & ~(size_t)(PAGE - 1);
    if (sceKernelAvailableDirectMemorySize(0,
            (int64_t)sceKernelGetDirectMemorySize(), PAGE, &phys, &available) ||
        available < span || available - span < DIRECT_HEADROOM ||
        sceKernelAllocateMainDirectMemory(span, PAGE, MEMORY_WB_ONION, &offset))
    {
        __atomic_fetch_add(&refusals, 1, __ATOMIC_RELAXED);
        return NULL;
    }
    if (sceKernelMapDirectMemory(&at, span, PROT_CPU_RW, 0, offset, PAGE) || !at)
    {
        (void)sceKernelReleaseDirectMemory(offset, span);
        __atomic_fetch_add(&refusals, 1, __ATOMIC_RELAXED);
        return NULL;
    }
    for (slot = 0; slot < SLOT_COUNT && blocks[slot].address; ++slot) {}
    if (slot == SLOT_COUNT)
    {
        (void)sceKernelMunmap(at, span);
        (void)sceKernelReleaseDirectMemory(offset, span);
        __atomic_fetch_add(&refusals, 1, __ATOMIC_RELAXED);
        return NULL;
    }
    blocks[slot] = (Block){ (uintptr_t)at, span, offset };
    uint64_t live = __atomic_add_fetch(&direct_live, span, __ATOMIC_RELAXED);
    uint64_t peak = __atomic_load_n(&direct_peak, __ATOMIC_RELAXED);
    while (live > peak && !__atomic_compare_exchange_n(&direct_peak, &peak, live, 0,
            __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {}
    __atomic_fetch_add(&maps, 1, __ATOMIC_RELAXED);
    return at;
}

static int unmap_direct(void *context, void *address, size_t bytes)
{
    (void)context;
    (void)bytes;
    for (size_t i = 0; i < SLOT_COUNT; ++i)
    {
        Block b = blocks[i];
        if (b.address != (uintptr_t)address) continue;
        blocks[i].address = 0;
        (void)sceKernelMunmap((void *)b.address, b.bytes);
        (void)sceKernelReleaseDirectMemory(b.offset, b.bytes);
        __atomic_fetch_sub(&direct_live, b.bytes, __ATOMIC_RELAXED);
        __atomic_fetch_add(&unmaps, 1, __ATOMIC_RELAXED);
        return 0;
    }
    return 1;
}

void pw_wineserver_heap_init(void)
{
    static const PwWineHeapBacking backing = { NULL, map_direct, unmap_direct };
    const char *v = getenv("PW_WINESERVER_HEAP_DIRECT");
    enabled = v && v[0] == '1' && v[1] == '\0';
    v = getenv("PW_WINESERVER_HEAP_TRACE");
    __atomic_store_n(&traced, v && v[0] == '1' && v[1] == '\0', __ATOMIC_RELAXED);
    if (enabled) pw_wine_heap_set_backing(&backing);
    report(enabled ? "initialized-direct" : "initialized-anonymous");
}

void pw_wineserver_heap_report(void)
{
    report("sample");
}
