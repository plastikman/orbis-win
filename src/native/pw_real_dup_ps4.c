/* __real_dup for the relocatable Wine PRX.
 *
 * prospero-win's pw_wine_cwd_libc.c wraps dup with --wrap=dup and calls
 * __real_dup first, expecting EPERM on this kernel before falling back to
 * fcntl(F_DUPFD). With a SHARED libc PRX (PW_SHARED_LIBC=1) the linker cannot
 * resolve __real_dup to a definition -- dup lives in the libc module, not in
 * this link -- so create-fself stops with
 *     Failed to build FSELF: missing library for symbol (__real_dup)
 * and no relocatable package can be built.
 *
 * Supplying the refusal directly is what the console does anyway: GoldHEN's
 * kernel refuses dup, dup2, F_DUPFD and sceKernelRdup. The wrapper's own
 * comment says "EPERM here", so this is the documented path, not a shortcut.
 */
#include <errno.h>

int __real_dup(int fd);

int __real_dup(int fd)
{
    (void)fd;
    errno = EPERM;
    return -1;
}
