/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Preserve Wine's explicitly supplied kernel stacks in ntdll.
 *
 * The SDK pthread_create interposer raises small stacks to the creator's
 * stack size and builds fresh attributes without copying the stack address.
 * Wine's 1 MiB direct-memory stack thus becomes a new 16 MiB flexible-memory
 * stack. A dozen workers exhaust the pool. Wine installs its own signal
 * stack in ntdll/unix/server.c, so these workers do not need the SDK's
 * alternate-stack trampoline. Calls without a supplied stack keep it.
 */
#include <pthread.h>
#include <pthread_np.h>
#include <stdio.h>

extern int scePthreadCreate(pthread_t *, const pthread_attr_t *,
                           void *(*)(void *), void *, const char *);
extern int sceKernelDebugOutText(int, const char *);
extern int __real_pthread_create(pthread_t *, const pthread_attr_t *,
                                 void *(*)(void *), void *);

#if defined(PW_WINESERVER_STACKSIZE_PASSTHROUGH)
enum {
    PW_WINESERVER_STACK_BYTES = 1024 * 1024,
    PW_WINESERVER_RETRY_STACK_BYTES = 512 * 1024
};

static int create_wineserver_stack(pthread_t *thread, const pthread_attr_t *attr,
                                   void *(*start)(void *), void *arg,
                                   size_t requested)
{
    pthread_attr_t retry;
    pthread_attr_t actual;
    void *actual_stack = NULL;
    size_t actual_bytes = 0;
    char line[240];
    int first_status, retry_status = -1, query = -1, retry_attr_status = -1;

    /* Bypass the SDK's pthread_create interposer: it raises this explicit
     * 1 MiB wineserver request to its 16 MiB floor. Keep the request's other
     * attributes intact on the first attempt. */
    first_status = scePthreadCreate(thread, attr, start, arg, "wine-server");
    if (first_status) {
        int detach = PTHREAD_CREATE_JOINABLE;
        size_t guard = 0;

        retry_attr_status = pthread_attr_init(&retry);
        if (!retry_attr_status) {
            if (attr) {
                (void)pthread_attr_getdetachstate(attr, &detach);
                (void)pthread_attr_getguardsize(attr, &guard);
            }
            (void)pthread_attr_setdetachstate(&retry, detach);
            (void)pthread_attr_setguardsize(&retry, guard);
            retry_attr_status = pthread_attr_setstacksize(
                &retry, PW_WINESERVER_RETRY_STACK_BYTES);
            if (!retry_attr_status)
                retry_status = scePthreadCreate(thread, &retry, start, arg,
                                                "wine-server");
            pthread_attr_destroy(&retry);
        }
    }

    if (!(first_status ? retry_status : first_status) &&
        !pthread_attr_init(&actual)) {
        query = pthread_attr_get_np(*thread, &actual);
        if (!query)
            query = pthread_attr_getstack(&actual, &actual_stack, &actual_bytes);
        pthread_attr_destroy(&actual);
    }

    snprintf(line, sizeof(line),
             "wineserver: stack requested=%zuK direct=%d retry_attr=%d "
             "retry_512K=%d actual=%p+%zuK query=%d\n",
             requested >> 10, first_status, retry_attr_status, retry_status,
             actual_stack, actual_bytes >> 10, query);
    sceKernelDebugOutText(0, line);
    return first_status ? retry_status : first_status;
}
#endif

int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                          void *(*start)(void *), void *arg);

int __wrap_pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                          void *(*start)(void *), void *arg)
{
    void *stack = NULL;
    size_t bytes = 0;
    int stack_status = attr ? pthread_attr_getstack(attr, &stack, &bytes) : -1;
    char line[240];
    pthread_attr_t actual;
    void *actual_stack = NULL;
    size_t actual_bytes = 0;
    int query = -1;
    int status;

    if (!stack_status && stack) {
        status = scePthreadCreate(thread, attr, start, arg, "wine-ps4");
        if (!status && !pthread_attr_init(&actual)) {
            query = pthread_attr_get_np(*thread, &actual);
            if (!query) query = pthread_attr_getstack(&actual, &actual_stack, &actual_bytes);
            pthread_attr_destroy(&actual);
        }
        snprintf(line, sizeof(line), "wine-ps4: supplied stack=%p bytes=%zuK create=%d actual=%p+%zuK query=%d\n",
                 stack, bytes >> 10, status, actual_stack, actual_bytes >> 10, query);
        sceKernelDebugOutText(0, line);
        return status;
    }

#if defined(PW_WINESERVER_STACKSIZE_PASSTHROUGH)
    if (attr && !pthread_attr_getstacksize(attr, &bytes) &&
        bytes == PW_WINESERVER_STACK_BYTES)
        return create_wineserver_stack(thread, attr, start, arg, bytes);
#endif

    if (stack_status)
        return __real_pthread_create(thread, attr, start, arg);
    return __real_pthread_create(thread, attr, start, arg);
}
