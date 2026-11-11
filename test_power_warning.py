import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('power_warning', Path(__file__).with_name('power-warning.py'))
power_warning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(power_warning)

class PowerWarningTests(unittest.TestCase):
    def test_storm_warning_and_cooldown(self):
        detector = power_warning.Detector()
        for n in range(80):
            detector.event(n / 4)
        self.assertEqual(detector.check(20, False, None), 'events')
        self.assertIsNone(detector.check(21, False, None))
        self.assertIsNone(detector.check(60, False, None))

    def test_sustained_discharge_requires_source_and_recovers(self):
        detector = power_warning.Detector()
        self.assertIsNone(detector.check(0, False, -20))
        self.assertIsNone(detector.check(10, True, -10))
        self.assertIsNone(detector.check(65, True, 3))
        self.assertIsNone(detector.check(70, True, -10))
        self.assertEqual(detector.check(130, True, -10), 'discharge')
