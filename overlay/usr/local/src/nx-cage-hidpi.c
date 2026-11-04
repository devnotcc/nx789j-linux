/*
 * LD_PRELOAD for nx-cage (wlroots nested on KWin): render the nested window at an integer
 * buffer scale (NX_HIDPI_SCALE, e.g. 2) instead of 1. wlroots' Wayland backend has no HiDPI
 * support: its window is always buffer pixels = logical pixels, so on the phone's 2.5x screen
 * KWin stretches it and everything inside (the Windows VM) is blurry. With this:
 *  - every wl_surface of the process gets wl_surface.set_buffer_scale(S) before its first commit
 *  - xdg_toplevel.configure sizes (logical) are multiplied by S, so wlroots makes its output
 *    S times larger in pixels; xdg_surface.set_window_geometry is divided by S
 *  - pointer and touch positions (logical) are multiplied by S (wlroots expects buffer pixels)
 * Build: gcc -O2 -shared -fPIC -o /usr/local/lib/nx-cage-hidpi.so nx-cage-hidpi.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client-core.h>
#include <wayland-client-protocol.h>

#define WL_CLOSURE_MAX_ARGS 20

static int S;
static int scale(void)
{
	if (!S) {
		const char *e = getenv("NX_HIDPI_SCALE");
		S = e ? atoi(e) : 1;
		if (S < 1 || S > 4)
			S = 1;
	}
	return S;
}

/* ---- requests ---- */
typedef struct wl_proxy *(*marshal_array_fn)(struct wl_proxy *, uint32_t, const struct wl_interface *,
					     uint32_t, uint32_t, union wl_argument *);
static marshal_array_fn real_marshal_array;

#define MAX_SURF 64
static struct wl_proxy *scaled[MAX_SURF];

static int is_class(struct wl_proxy *p, const char *name)
{
	const char *c = wl_proxy_get_class(p);
	return c && strcmp(c, name) == 0;
}

static void before_request(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args)
{
	int s = scale();
	if (s == 1)
		return;
	if (opcode == 6 && is_class(proxy, "wl_surface")) { /* commit */
		int i, freeslot = -1;
		for (i = 0; i < MAX_SURF; i++) {
			if (scaled[i] == proxy)
				return;
			if (!scaled[i] && freeslot < 0)
				freeslot = i;
		}
		if (freeslot >= 0 && wl_proxy_get_version(proxy) >= 3) {
			union wl_argument a[1];
			a[0].i = s;
			real_marshal_array(proxy, 8, NULL, wl_proxy_get_version(proxy), 0, a); /* set_buffer_scale */
			scaled[freeslot] = proxy;
		}
	} else if (opcode == 0 && is_class(proxy, "wl_surface")) {
		/* destroy: forget it (the address may be reused) */
		int i;
		for (i = 0; i < MAX_SURF; i++)
			if (scaled[i] == proxy)
				scaled[i] = NULL;
	} else if (opcode == 3 && is_class(proxy, "xdg_surface")) { /* set_window_geometry */
		args[0].i /= s; args[1].i /= s; args[2].i /= s; args[3].i /= s;
	}
}

/* parse the varargs like libwayland does, so the call can go to the _array variant */
static void va_to_args(const char *sig, union wl_argument *args, int max, va_list ap)
{
	int n = 0;
	for (; *sig && n < max; sig++) {
		switch (*sig) {
		case 'i': args[n++].i = va_arg(ap, int32_t); break;
		case 'u': args[n++].u = va_arg(ap, uint32_t); break;
		case 'f': args[n++].f = va_arg(ap, wl_fixed_t); break;
		case 's': args[n++].s = va_arg(ap, const char *); break;
		case 'o': args[n++].o = va_arg(ap, struct wl_object *); break;
		case 'n': args[n++].o = va_arg(ap, struct wl_object *); break;
		case 'a': args[n++].a = va_arg(ap, struct wl_array *); break;
		case 'h': args[n++].h = va_arg(ap, int32_t); break;
		default: break; /* '?' and version digits */
		}
	}
}

struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *proxy, uint32_t opcode,
					const struct wl_interface *interface, uint32_t version,
					uint32_t flags, ...)
{
	union wl_argument args[WL_CLOSURE_MAX_ARGS];
	/* struct wl_proxy starts with struct wl_object, whose first member is the interface */
	const struct wl_interface *pi = *(const struct wl_interface **)proxy;
	va_list ap;
	if (!real_marshal_array)
		real_marshal_array = (marshal_array_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_array_flags");
	memset(args, 0, sizeof(args));
	va_start(ap, flags);
	va_to_args(pi->methods[opcode].signature, args, WL_CLOSURE_MAX_ARGS, ap);
	va_end(ap);
	before_request(proxy, opcode, args);
	return real_marshal_array(proxy, opcode, interface, version, flags, args);
}

/* ---- events ---- */
#define MAX_L 16
static struct { struct wl_proxy *p; const void *orig; } lis[MAX_L];
static const void *orig_of(void *proxy)
{
	int i;
	for (i = 0; i < MAX_L; i++)
		if (lis[i].p == proxy)
			return lis[i].orig;
	return NULL;
}

static void p_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y)
{
	const struct wl_pointer_listener *o = orig_of(p);
	o->enter(d, p, serial, s, x * scale(), y * scale());
}
static void p_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y)
{
	const struct wl_pointer_listener *o = orig_of(p);
	o->motion(d, p, t, x * scale(), y * scale());
}
static void t_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, struct wl_surface *s, int32_t id,
		   wl_fixed_t x, wl_fixed_t y)
{
	const struct wl_touch_listener *o = orig_of(t);
	o->down(d, t, serial, time, s, id, x * scale(), y * scale());
}
static void t_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
	const struct wl_touch_listener *o = orig_of(t);
	o->motion(d, t, time, id, x * scale(), y * scale());
}
typedef void (*tl_configure_fn)(void *, void *, int32_t, int32_t, struct wl_array *);
typedef void (*tl_bounds_fn)(void *, void *, int32_t, int32_t);
static void tl_configure(void *d, void *tl, int32_t w, int32_t h, struct wl_array *states)
{
	void *const *o = orig_of(tl);
	((tl_configure_fn)o[0])(d, tl, w * scale(), h * scale(), states);
}
static void tl_bounds(void *d, void *tl, int32_t w, int32_t h)
{
	void *const *o = orig_of(tl);
	((tl_bounds_fn)o[2])(d, tl, w * scale(), h * scale());
}

typedef int (*add_listener_fn)(struct wl_proxy *, void (**)(void), void *);
int wl_proxy_add_listener(struct wl_proxy *proxy, void (**implementation)(void), void *data)
{
	static add_listener_fn real;
	void (**impl)(void) = implementation;
	int n = 0, i;
	if (!real)
		real = (add_listener_fn)dlsym(RTLD_NEXT, "wl_proxy_add_listener");
	if (scale() > 1) {
		if (is_class(proxy, "wl_pointer"))
			n = wl_pointer_interface.event_count;
		else if (is_class(proxy, "wl_touch"))
			n = wl_touch_interface.event_count;
		else if (is_class(proxy, "xdg_toplevel"))
			n = 4; /* configure, close, configure_bounds, wm_capabilities */
	}
	for (i = 0; n && i < MAX_L; i++)
		if (!lis[i].p || lis[i].p == proxy)
			break;
	if (n && i < MAX_L) {
		void (**copy)(void) = malloc(sizeof(void (*)(void)) * n);
		memcpy(copy, implementation, sizeof(void (*)(void)) * n);
		lis[i].p = proxy;
		lis[i].orig = implementation;
		if (is_class(proxy, "wl_pointer")) {
			copy[0] = (void (*)(void))p_enter;
			copy[2] = (void (*)(void))p_motion;
		} else if (is_class(proxy, "wl_touch")) {
			copy[0] = (void (*)(void))t_down;
			copy[2] = (void (*)(void))t_motion;
		} else {
			copy[0] = (void (*)(void))tl_configure;
			if (implementation[2])
				copy[2] = (void (*)(void))tl_bounds;
		}
		impl = copy;
	}
	return real(proxy, impl, data);
}
