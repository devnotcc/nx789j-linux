"use strict";
// Pixel shift: about every INTERVAL the whole picture (panels, wallpaper, windows) moves to the next
// point of a small orbit around its real position, as phones do against OLED burn-in. Done as
// a translation of every window; fullscreen windows (games, video) are left alone so that they
// can still be scanned out directly. Input is not shifted: the offset is at most 3 panel pixels.
var INTERVAL = 150 * 1000;      // ms between steps
var STEP = 1.2;                 // logical pixels per orbit unit (x2 display scale = about 2-3 panel pixels)
var ORBIT = [[0, 0], [1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]];
var pos = 0;

function target() {
    return { value1: ORBIT[pos][0] * STEP, value2: ORBIT[pos][1] * STEP };
}

function shift(w) {
    if (w.deleted) return;
    // only the phone's own (OLED) screen: on a monitor the sub-pixel offset would just blur text
    var onPhone = !w.screen || String(w.screen.name).indexOf("DSI") === 0;
    // a running animation makes KWin paint the window even while it is minimised (it would stay
    // on the screen as a frozen picture): minimised windows get no shift until they come back
    if (w.fullScreen || w.minimized || !onPhone) {
        if (w.nxShift !== undefined) { cancel(w.nxShift); w.nxShift = undefined; }
        return;
    }
    if (w.nxShift !== undefined && retarget(w.nxShift, target(), 2000)) return;
    w.nxShift = set({ window: w, duration: 2000, keepAlive: false, curve: QEasingCurve.InOutQuad,
                      animations: [{ type: Effect.Translation, to: target() }] });
}

function all() {
    effects.stackingOrder.forEach(shift);
}

// Scripted effects have no timer, and a running animation as a clock would keep the screen
// repainting. The orbit advances on window events instead (a window opens, closes or gets
// focus), at most once per INTERVAL; with nothing happening at all the screen times out anyway.
var last = Date.now();
function tick() {
    if (Date.now() - last < INTERVAL) return;
    last = Date.now();
    pos = (pos + 1) % ORBIT.length;
    all();
}

function watch(w) {
    w.windowFullScreenChanged.connect(function () { shift(w); });
    if (w.minimizedChanged) w.minimizedChanged.connect(function () { shift(w); });
}
effects.windowAdded.connect(function (w) { watch(w); shift(w); tick(); });
// a shift still attached to a closed window would keep its last picture on the screen
effects.windowClosed.connect(function (w) {
    if (w.nxShift !== undefined) { cancel(w.nxShift); w.nxShift = undefined; }
    tick();
});
// (also catches minimise/restore where the window has no minimizedChanged signal: minimising
// activates another window)
effects.windowActivated.connect(function () {
    tick();
    effects.stackingOrder.forEach(function (w) {
        if (!w.deleted && w.minimized === (w.nxShift !== undefined)) shift(w);
    });
});
effects.stackingOrder.forEach(watch);
all();
