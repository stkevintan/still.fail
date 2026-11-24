#!/usr/bin/env python3
"""Exercise screen-linux input on a private X server.

Run with XVFB_BIN=/path/to/Xvfb SCREEN_BIN=/path/to/stillfail-screen-linux
python3 station/side/x11-key-leases.py. No existing display is changed.
"""

import ctypes as c
import json
import os
import select
import shutil
import struct
import subprocess
import time

xvfb = os.environ.get("XVFB_BIN") or shutil.which("Xvfb")
binary = os.environ.get("SCREEN_BIN")
if not xvfb or not binary:
    raise SystemExit("Set XVFB_BIN and SCREEN_BIN to the test binaries")

read_fd, write_fd = os.pipe()
server = subprocess.Popen(
    [xvfb, "-displayfd", str(write_fd), "-screen", "0", "640x480x24", "-nolisten", "tcp"],
    pass_fds=(write_fd,), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
)
os.close(write_fd)
helpers = []
try:
    if not select.select([read_fd], [], [], 10)[0]:
        raise RuntimeError("Xvfb did not start")
    display = ":" + os.read(read_fd, 64).decode().strip()
    os.close(read_fd)
    env = dict(os.environ, DISPLAY=display)
    env.pop("WAYLAND_DISPLAY", None)
    x = c.CDLL("libX11.so.6")
    ptr, ulong, uint = c.c_void_p, c.c_ulong, c.c_uint
    intptr = c.POINTER(c.c_int)

    def signature(name, result, args):
        func = getattr(x, name)
        func.restype, func.argtypes = result, args

    for sig in [
        ("XOpenDisplay", ptr, [c.c_char_p]), ("XCloseDisplay", c.c_int, [ptr]),
        ("XDisplayKeycodes", c.c_int, [ptr, intptr, intptr]),
        ("XGetKeyboardMapping", c.POINTER(ulong), [ptr, c.c_ubyte, c.c_int, intptr]),
        ("XChangeKeyboardMapping", c.c_int, [ptr, c.c_int, c.c_int, c.POINTER(ulong), c.c_int]),
        ("XFree", c.c_int, [ptr]), ("XDefaultScreen", c.c_int, [ptr]),
        ("XRootWindow", ulong, [ptr, c.c_int]),
        ("XCreateSimpleWindow", ulong, [ptr, ulong, c.c_int, c.c_int, uint, uint, uint, ulong, ulong]),
        ("XSelectInput", c.c_int, [ptr, ulong, c.c_long]), ("XMapWindow", c.c_int, [ptr, ulong]),
        ("XSetInputFocus", c.c_int, [ptr, ulong, c.c_int, ulong]), ("XSync", c.c_int, [ptr, c.c_int]),
        ("XPending", c.c_int, [ptr]), ("XNextEvent", c.c_int, [ptr, ptr]),
        ("XConnectionNumber", c.c_int, [ptr]), ("XRefreshKeyboardMapping", c.c_int, [ptr]),
        ("XLookupString", c.c_int, [ptr, c.c_char_p, c.c_int, c.POINTER(ulong), ptr]),
    ]:
        signature(*sig)
    d = x.XOpenDisplay(display.encode())
    if not d:
        raise RuntimeError("Could not open the private display")
    low, high, width = c.c_int(), c.c_int(), c.c_int()
    x.XDisplayKeycodes(d, c.byref(low), c.byref(high))

    def mapping():
        values = x.XGetKeyboardMapping(d, low.value, high.value - low.value + 1, c.byref(width))
        result = {
            key: [int(values[(key - low.value) * width.value + i]) for i in range(width.value)]
            for key in range(low.value, high.value + 1)
        }
        x.XFree(values)
        return result

    screen = x.XDefaultScreen(d)
    window = x.XCreateSimpleWindow(d, x.XRootWindow(d, screen), 0, 0, 200, 100, 0, 0, 0xffffff)
    x.XSelectInput(d, window, (1 << 0) | (1 << 1))
    x.XMapWindow(d, window)
    x.XSetInputFocus(d, window, 1, 0)
    x.XSync(d, 0)
    initial = mapping()
    spare = [key for key, row in initial.items() if not any(row)]
    if len(spare) < 2:
        raise RuntimeError("The private X server needs at least two spare keycodes")

    def start():
        proc = subprocess.Popen([binary, "view"], env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        helpers.append(proc)
        proc.stdin.write(b'{"codec":"jpeg","maxWidth":640,"maxHeight":480}\n')
        proc.stdin.flush()
        if not select.select([proc.stdout], [], [], 10)[0]:
            raise RuntimeError("The screen helper did not start")
        kind, length = struct.unpack(">BI", proc.stdout.read(5))
        info = json.loads(proc.stdout.read(length))
        if kind != 1 or info.get("error"):
            raise RuntimeError(f"Screen helper refused the display: {info}")
        return proc

    event = c.create_string_buffer(192)

    def send(proc, text):
        payload = json.dumps({"op": "text", "text": text}, ensure_ascii=False).encode()
        proc.stdin.write(struct.pack(">BI", 3, len(payload)) + payload)
        proc.stdin.flush()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if not x.XPending(d):
                select.select([x.XConnectionNumber(d)], [], [], max(0, deadline - time.monotonic()))
                continue
            x.XNextEvent(d, event)
            kind = c.c_int.from_buffer(event).value
            if kind == 34:
                x.XRefreshKeyboardMapping(event)
            elif kind == 2:
                symbol = ulong()
                out = c.create_string_buffer(32)
                x.XLookupString(event, out, len(out), c.byref(symbol), None)
                return symbol.value
        raise AssertionError("The focused X11 window did not receive a key press")

    def stop(proc, killed=False):
        if killed:
            proc.kill()
        else:
            proc.stdin.close()
        proc.wait(timeout=5)
        if killed:
            proc.stdin.close()
        proc.stdout.close()
        error = proc.stderr.read().decode("utf8", "replace")
        proc.stderr.close()
        helpers.remove(proc)
        if not killed and (proc.returncode or error):
            raise RuntimeError(f"Screen helper failed: {proc.returncode}, {error}")

    # A killed view must not consume another spare keycode on every reconnect.
    for i in range(len(spare) + 1):
        proc = start()
        assert send(proc, "a") == ord("a")
        stop(proc, killed=True)
    current = mapping()
    assert sum(not any(row) for row in current.values()) == len(spare) - 1
    proc = start()
    assert send(proc, "中") == 0x01004e2d
    stop(proc)
    assert mapping() == initial
    print("abandoned keycodes recovered after repeated view deaths")

    # Two live views must not claim the same spare or restore each other's mapping.
    first, second = start(), start()
    assert send(first, "a") == ord("a")
    assert send(second, "b") == ord("b")
    stop(first, killed=True)
    third = start()
    assert send(third, "c") == ord("c")
    assert send(second, "b") == ord("b")
    stop(third)
    stop(second)
    assert mapping() == initial
    print("live views keep separate keycodes")

    # A change made by another X11 client must survive recovery of an abandoned lease.
    proc = start()
    assert send(proc, "a") == ord("a")
    current = mapping()
    changed = [key for key in spare if current[key] != initial[key]]
    assert len(changed) == 1
    replacement = (ulong * width.value)(*[0xffbe] * width.value)
    x.XChangeKeyboardMapping(d, changed[0], width.value, replacement, 1)
    x.XSync(d, 0)
    expected = mapping()[changed[0]]
    stop(proc, killed=True)
    proc = start()
    assert send(proc, "b") == ord("b")
    stop(proc)
    assert mapping()[changed[0]] == expected
    print("recovery preserves another client's keymap changes")
    x.XCloseDisplay(d)
finally:
    for proc in helpers:
        proc.kill()
        proc.wait(timeout=3)
    server.terminate()
    server.wait(timeout=5)
