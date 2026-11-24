#!/usr/bin/env python3
"""Virtual Xbox 360 controllers for a Linux desktop's view (linux-gamepad.ts), through /dev/uinput.

Reads a controller's whole state a line (JSON: index 0..3, connected, buttons as the W3C Standard Gamepad's 17 bits,
lx ly rx ry -1..1, lt rt 0..1) and keeps one uinput device a slot, made as its first state comes and destroyed as it
is let go of (connected false) or stdin ends. Says {"ready": true} once /dev/uinput opened, else {"error": why} and ends
(the view then drives the desktop with it instead). Standard library only.
"""
import fcntl
import json
import os
import struct
import sys

EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045567
UI_DEV_SETUP, UI_ABS_SETUP = 0x405C5503, 0x401C5504
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
BUS_USB = 0x03
VENDOR, PRODUCT, VERSION = 0x045E, 0x028E, 0x0110

# The W3C Standard Gamepad's buttons (their bits) as the Linux xpad driver says an Xbox 360 controller's; 6 and 7 are
# the triggers (ABS_Z, ABS_RZ) and 12..15 the d-pad (ABS_HAT0X, ABS_HAT0Y).
BUTTONS = {0: 0x130, 1: 0x131, 2: 0x133, 3: 0x134, 4: 0x136, 5: 0x137, 8: 0x13A, 9: 0x13B, 10: 0x13D, 11: 0x13E, 16: 0x13C}
ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, ABS_HAT0X, ABS_HAT0Y = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x11
AXES = [(ABS_X, -32768, 32767, 16, 128), (ABS_Y, -32768, 32767, 16, 128), (ABS_RX, -32768, 32767, 16, 128),
        (ABS_RY, -32768, 32767, 16, 128), (ABS_Z, 0, 255, 0, 0), (ABS_RZ, 0, 255, 0, 0),
        (ABS_HAT0X, -1, 1, 0, 0), (ABS_HAT0Y, -1, 1, 0, 0)]
EVENT = struct.Struct("llHHi")


def say(**values):
    sys.stdout.write(json.dumps(values) + "\n")
    sys.stdout.flush()


def stick(v):
    v = min(1.0, max(-1.0, float(v)))
    return int(round(v * 32767)) if v >= 0 else int(round(v * 32768))


def trigger(v):
    return int(round(min(1.0, max(0.0, float(v))) * 255))


def values_of(pad):
    """What a state is as the device's keys and axes: {(type, code): value}."""
    buttons = int(pad.get("buttons", 0)) & 0x1FFFF
    out = {(EV_KEY, code): 1 if buttons & (1 << bit) else 0 for bit, code in BUTTONS.items()}
    out[(EV_ABS, ABS_X)] = stick(pad.get("lx", 0))
    out[(EV_ABS, ABS_Y)] = stick(pad.get("ly", 0))
    out[(EV_ABS, ABS_RX)] = stick(pad.get("rx", 0))
    out[(EV_ABS, ABS_RY)] = stick(pad.get("ry", 0))
    out[(EV_ABS, ABS_Z)] = trigger(pad.get("lt", 0))
    out[(EV_ABS, ABS_RZ)] = trigger(pad.get("rt", 0))
    out[(EV_ABS, ABS_HAT0X)] = (1 if buttons & (1 << 15) else 0) - (1 if buttons & (1 << 14) else 0)
    out[(EV_ABS, ABS_HAT0Y)] = (1 if buttons & (1 << 13) else 0) - (1 if buttons & (1 << 12) else 0)
    return out


RESTING = values_of({})


class Pad:
    def __init__(self, index):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_ABS)
        for code in BUTTONS.values():
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        for code, low, high, fuzz, flat in AXES:
            fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)
            # struct uinput_abs_setup: code, (padding), struct input_absinfo {value, minimum, maximum, fuzz, flat, resolution}
            fcntl.ioctl(self.fd, UI_ABS_SETUP, struct.pack("HxxIiiiii", code, 0, low, high, fuzz, flat, 0))
        name = ("still.fail Controller %d (Xbox 360)" % (index + 1)).encode()[:79]
        # struct uinput_setup: struct input_id {bustype, vendor, product, version}, name[80], ff_effects_max
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", BUS_USB, VENDOR, PRODUCT, VERSION, name, 0))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        self.last = dict(RESTING)

    def emit(self, values):
        events = [EVENT.pack(0, 0, kind, code, value) for (kind, code), value in values.items() if self.last.get((kind, code)) != value]
        if not events:
            return
        events.append(EVENT.pack(0, 0, EV_SYN, SYN_REPORT, 0))
        os.write(self.fd, b"".join(events))
        self.last.update(values)

    def close(self):
        try:
            self.emit(dict(RESTING))
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        except OSError:
            pass
        os.close(self.fd)


def main():
    try:
        os.close(os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK))
    except OSError as error:
        say(error=type(error).__name__ + ": " + (error.strerror or ""))
        return
    say(ready=True)
    pads = {}
    try:
        for line in sys.stdin:
            try:
                pad = json.loads(line)
                index = int(pad.get("index", -1))
            except (ValueError, TypeError, AttributeError):
                continue
            if not 0 <= index <= 3:
                continue
            if pad.get("connected") is False:
                if index in pads:
                    pads.pop(index).close()
                continue
            try:
                if index not in pads:
                    pads[index] = Pad(index)
                pads[index].emit(values_of(pad))
            except OSError as error:
                say(error=type(error).__name__ + ": " + (error.strerror or ""))
                return
    finally:
        for pad in pads.values():
            pad.close()


if __name__ == "__main__":
    main()
