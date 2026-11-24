#!/usr/bin/python3
"""A controller's state as the virtual Xbox 360 controller's keys and axes, and no /dev/uinput said so, not an error."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

path = Path(__file__).resolve().parents[1] / "assets/screens/linux-gamepad.py"
spec = importlib.util.spec_from_file_location("linux_gamepad_test", path)
pad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pad)


class Values(unittest.TestCase):
    def test_a_state_is_its_buttons_sticks_triggers_and_hat(self):
        v = pad.values_of({"buttons": (1 << 0) | (1 << 12) | (1 << 15) | (1 << 16), "lx": 1, "ly": -1, "rx": -0.5, "ry": 2, "lt": 0.5, "rt": -3})
        self.assertEqual(v[(pad.EV_KEY, 0x130)], 1)
        self.assertEqual(v[(pad.EV_KEY, 0x13C)], 1)
        self.assertEqual(v[(pad.EV_KEY, 0x131)], 0)
        self.assertEqual((v[(pad.EV_ABS, pad.ABS_X)], v[(pad.EV_ABS, pad.ABS_Y)]), (32767, -32768))
        self.assertEqual((v[(pad.EV_ABS, pad.ABS_RX)], v[(pad.EV_ABS, pad.ABS_RY)]), (-16384, 32767))
        self.assertEqual((v[(pad.EV_ABS, pad.ABS_Z)], v[(pad.EV_ABS, pad.ABS_RZ)]), (128, 0))
        self.assertEqual((v[(pad.EV_ABS, pad.ABS_HAT0X)], v[(pad.EV_ABS, pad.ABS_HAT0Y)]), (1, -1))

    def test_at_rest_everything_is_zero(self):
        self.assertTrue(all(value == 0 for value in pad.RESTING.values()))
        self.assertEqual(pad.EVENT.size, 24)


class NoUinput(unittest.TestCase):
    def test_no_dev_uinput_is_said_and_it_ends(self):
        out = io.StringIO()
        with mock.patch.object(pad.os, "open", side_effect=PermissionError(13, "Permission denied")), mock.patch.object(sys, "stdout", out):
            pad.main()
        said = json.loads(out.getvalue())
        self.assertIn("PermissionError", said["error"])


if __name__ == "__main__":
    unittest.main()
