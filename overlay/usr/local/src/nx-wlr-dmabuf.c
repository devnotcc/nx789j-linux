/* LD_PRELOAD shim for wlroots compositors on the NX789J (used by VM mode).
 *
 * wlroots sanity-checks every client dmabuf by importing it on the display device with
 * drmPrimeFDToHandle(). The vendor display driver only accepts its own buffers, so memory-backed
 * (udmabuf) buffers such as the Windows VM's frames fail with EINVAL and the client falls back to
 * copying each frame through shared memory, although the GPU can texture from them directly.
 * This makes the check pass with a placeholder handle; real imports are untouched.
 *
 * build: gcc -shared -fPIC -O2 -o /usr/local/lib/nx-wlr-dmabuf.so nx-wlr-dmabuf.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>

#define FAKE_BASE 0x7ff00000u

int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle)
{
	static int (*real)(int, int, uint32_t *);
	static uint32_t next;
	if (!real)
		real = dlsym(RTLD_NEXT, "drmPrimeFDToHandle");
	int ret = real(fd, prime_fd, handle);
	if (ret != 0 && (errno == EINVAL || errno == ENOTTY || errno == EOPNOTSUPP)) {
		*handle = FAKE_BASE + (next++ & 0xffff);
		return 0;
	}
	return ret;
}

int drmCloseBufferHandle(int fd, uint32_t handle)
{
	static int (*real)(int, uint32_t);
	if (handle >= FAKE_BASE && handle < FAKE_BASE + 0x10000)
		return 0;
	if (!real)
		real = dlsym(RTLD_NEXT, "drmCloseBufferHandle");
	return real(fd, handle);
}
