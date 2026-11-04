/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* The DualShock 4 behind prospero-win's pad core.
 *
 * ⚠ THE CORE IS NOT TOUCHED. native/pw_pad_ps5.c reaches the platform only
 * through PwPadPs5Ops, a vtable of ten one-line functions, and
 * pw_pad_ps5_platform_ops() is merely the PS5's filling of it. This file is the
 * PS4's. Everything above it — batching, connect/disconnect generations,
 * intercepted samples, edge tracking, analog centring on loss — is upstream
 * code compiled as-is.
 *
 * That the PS4 exports the SAME EIGHT SYMBOLS (scePadInit/Open/Read/Close/
 * SetVibration, sceUserServiceInitialize/GetForegroundUser/Terminate) is why
 * eight of the ten are one line here too.
 *
 * The tenth is the only real work: ScePadData and the DualSense sample are NOT
 * binary compatible. `connected` is uint8_t here and int32_t there, which moves
 * every field after it, and the accelerometer and gyro are swapped. So the read
 * goes into the PS4's struct and the seven fields the core actually consumes
 * are copied across by name.
 */
#include "pw_pad_ps4.h"
#include <string.h>

#include <orbis/Pad.h>
#include <orbis/UserService.h>
#include <orbis/_types/pad.h>

/* The SDK declares this taking void*, the vtable passes const void*. Cast at
 * the one place that knows both, rather than loosening the vtable. */
static int platform_user_initialize(const void *p) { return sceUserServiceInitialize((void *)p); }
static int platform_foreground_user(int32_t *u)    { return sceUserServiceGetForegroundUser(u); }
static int platform_user_terminate(void)           { return sceUserServiceTerminate(); }
static int platform_pad_init(void)                 { return scePadInit(); }
static int platform_pad_open(int32_t u, int32_t t, int32_t i, const void *p)
{
    return scePadOpen(u, t, i, (void *)p);
}
static int platform_pad_close(int32_t h)           { return scePadClose(h); }

static int platform_pad_set_vibration(int32_t h, const uint8_t motors[2])
{
    /* OrbisPadVibeParam is {lgMotor, smMotor} — two bytes in the same order the
     * core passes them, large first. Named rather than cast so the agreement is
     * checkable by reading. */
    OrbisPadVibeParam param = { .lgMotor = motors[0], .smMotor = motors[1] };
    return scePadSetVibration(h, &param);
}

/* ⚠ THE ONE FUNCTION THAT IS NOT A FORWARD.
 *
 * Fills what read_batch() consumes: buttons, timestamp, connected_count,
 * connected, both sticks, both triggers, and the touch sample used by the
 * shared on-screen-keyboard gesture. The remaining motion and device-unique
 * fields stay zeroed; the core does not use them.
 *
 * The button bits need no translation: the PS4 and PS5 both use Sony's layout,
 * CROSS 0x4000 through TOUCH_PAD 0x100000.
 */
static int platform_pad_read(int32_t handle, PwPadPs5Data *out, int32_t count)
{
    if (count <= 0) return 0;
    if (count > PW_PAD_PS4_BATCH) count = PW_PAD_PS4_BATCH;

    OrbisPadData raw[PW_PAD_PS4_BATCH];
    int got = scePadRead(handle, raw, count);
    if (got <= 0) return got;
    if (got > count) got = count;

    memset(out, 0, (size_t)got * sizeof *out);
    for (int i = 0; i < got; i++) {
        out[i].buttons         = raw[i].buttons;
        out[i].timestamp       = raw[i].timestamp;
        out[i].connected       = raw[i].connected ? 1 : 0;
        out[i].connected_count = raw[i].count;
        out[i].left_stick      = (PwPadPs5Stick){ raw[i].leftStick.x,  raw[i].leftStick.y  };
        out[i].right_stick     = (PwPadPs5Stick){ raw[i].rightStick.x, raw[i].rightStick.y };
        out[i].l2              = raw[i].analogButtons.l2;
        out[i].r2              = raw[i].analogButtons.r2;
        out[i].touch_data.fingers = raw[i].touch.fingers;
        out[i].touch_data.reserved1 = raw[i].touch.pad2;
        for (int finger = 0; finger < 2; finger++) {
            out[i].touch_data.touch[finger].x = raw[i].touch.touch[finger].x;
            out[i].touch_data.touch[finger].y = raw[i].touch.touch[finger].y;
            out[i].touch_data.touch[finger].finger = raw[i].touch.touch[finger].finger;
        }
    }
    return got;
}

int pw_pad_ps4_platform_ops(PwPadPs5Ops *ops)
{
    if (!ops) return PW_ERR_PRECONDITION;
    *ops = (PwPadPs5Ops){
        .user_initialize   = platform_user_initialize,
        .foreground_user   = platform_foreground_user,
        .user_terminate    = platform_user_terminate,
        .pad_init          = platform_pad_init,
        .pad_open          = platform_pad_open,
        .pad_read          = platform_pad_read,
        .pad_close         = platform_pad_close,
        .pad_set_vibration = platform_pad_set_vibration,
    };
    return PW_OK;
}
