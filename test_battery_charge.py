import importlib.machinery
import importlib.util
import json
import copy
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent


def load(name, file):
    loader = importlib.machinery.SourceFileLoader(name, str(HERE / file))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load('helper', 'set-charge-limit.py')
installer = load('installer', 'install.py')
client = load('client', 'battery-charge')


class ChargeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.config = root / 'charge.conf'
        self.threshold = root / 'threshold'
        self.original = '# retain tuning\nSTOP_CHARGE_THRESH_BAT0=80\nOTHER=1\n'
        self.config.write_text(self.original)
        self.threshold.write_text('80\n')
        for name, value in [('CONFIG', self.config), ('THRESHOLD', self.threshold)]:
            p = patch.object(helper, name, value)
            p.start()
            self.addCleanup(p.stop)

    def test_both_modes_persist_and_apply(self):
        def apply(command, check):
            limit = self.config.read_text().split('STOP_CHARGE_THRESH_BAT0=')[1].splitlines()[0]
            self.threshold.write_text(limit)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(helper.subprocess, 'run', side_effect=apply):
            for limit in ('100', '80'):
                helper.set_limit(limit)
                self.assertEqual(self.threshold.read_text(), limit)
                self.assertEqual(self.config.read_text(), self.original.replace('=80', '=' + limit))

    def test_failed_apply_restores_config_and_runtime(self):
        def fail(command, check):
            if check:
                self.threshold.write_text('100')  # partial hardware write before failure
                raise subprocess.CalledProcessError(1, command)
            self.assertEqual(command, ['/usr/bin/tlp', 'setcharge', '80', '80'])
            self.threshold.write_text('80')
        with patch.object(helper.subprocess, 'run', side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                helper.set_limit('100')
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.threshold.read_text(), '80')

    def test_discarded_hardware_write_is_failure(self):
        with patch.object(helper.subprocess, 'run') as run:
            with self.assertRaises(RuntimeError):
                helper.set_limit('100')
            self.assertEqual(run.call_count, 2)
        self.assertEqual(self.config.read_text(), self.original)

    def test_invalid_or_ambiguous_config_does_not_run_tlp(self):
        with patch.object(helper.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                helper.set_limit('99; reboot')
            self.config.write_text(self.original + 'STOP_CHARGE_THRESH_BAT0=100\n')
            with self.assertRaises(ValueError):
                helper.set_limit('100')
            run.assert_not_called()

    def test_cancel_authentication_does_not_retry_or_notify(self):
        with patch.object(client.sys, 'argv', ['battery-charge', '100']), \
             patch.object(client.subprocess, 'run', return_value=subprocess.CompletedProcess([], 126)) as run:
            self.assertEqual(client.main(), 126)
            run.assert_called_once_with(['/usr/bin/pkexec', '/usr/local/libexec/dotfiles-set-charge-limit', '100'])

    def test_status_uses_sensor_labels_and_distinguishes_zero_from_missing(self):
        root = self.threshold.parent
        battery = root / 'macsmc-battery'
        adapter = root / 'macsmc-ac'
        battery.mkdir()
        adapter.mkdir()
        (adapter / 'online').write_text('1')
        (adapter / 'input_power_limit').write_text('65000000')
        hwmon = root / 'hwmon'
        sensors = hwmon / 'hwmon7'
        sensors.mkdir(parents=True)
        for name, value in {
            'name': 'macsmc_hwmon',
            'power9_label': 'AC Input Power',
            'power9_input': '14200000',
            'power3_label': 'Total System Power',
        }.items():
            (sensors / name).write_text(value)
        (battery / 'capacity').write_text('76')
        (battery / 'status').write_text('Not charging')
        (battery / 'power_now').write_text('0')
        with patch.multiple(client, BATTERY=battery, HWMON=hwmon, THRESHOLD=self.threshold):
            reading = client.status()
            self.assertEqual(reading['text'], '80% cap')
            self.assertEqual(reading['limit'], '80')
            self.assertEqual(reading['chargerLimitWatts'], 65.0)
            self.assertEqual(reading['chargerWatts'], 14.2)
            for line in ('Battery 76% · Home cap 80%', 'Charger input  14.2 W',
                         'System draw  Unavailable', 'Battery charge  0.0 W', 'Not charging'):
                self.assertIn(line, reading['tooltip'].splitlines())
            (battery / 'status').write_text('Discharging')
            (battery / 'power_now').write_text('-8750000')
            (adapter / 'online').write_text('0')
            self.assertIn('Battery discharge  8.8 W', client.status()['tooltip'].splitlines())
            self.assertIsNone(client.status()['chargerLimitWatts'])

    def test_app_counters_deduplicate_gpu_descriptors(self):
        proc = self.threshold.parent / 'proc'
        for pid in ('101', '102'):
            process = proc / pid
            (process / 'fd').mkdir(parents=True)
            (process / 'fdinfo').mkdir()
            (process / 'stat').write_text(f'{pid} (worker (gpu)) S ' + ' '.join(['10'] * 19))
            (process / 'exe').symlink_to('/usr/bin/browser')
            for fd in ('1', '2'):
                (process / 'fd' / fd).symlink_to('/dev/dri/renderD128')
                (process / 'fdinfo' / fd).write_text(
                    'drm-driver:\taurora\ndrm-client-id:\t9\ndrm-engine-fragment:\t500 ns\n'
                )
        with patch.object(client, 'PROC', proc):
            processes, clients = client.app_counters()
        self.assertEqual(len(processes), 2)
        self.assertEqual(list(clients.values()), [('browser', {'drm-engine-fragment': 500})])

    def test_app_activity_groups_workers_and_uses_the_busiest_gpu_engine(self):
        previous = (
            {('1', 0): ('browser', 10), ('2', 0): ('browser', 20), ('3', 0): ('old', 10)},
            {1: ('browser', {'vertex': 100, 'fragment': 100}), 2: ('browser', {'fragment': 200})},
        )
        current = (
            {('1', 0): ('browser', 35), ('2', 0): ('browser', 45), ('3', 1): ('new', 100)},
            {1: ('browser', {'vertex': 300_000_100, 'fragment': 250_000_100}),
             2: ('browser', {'fragment': 200_000_200})},
        )
        with patch.object(client.os, 'sysconf', return_value=100):
            self.assertEqual(client.app_activity(previous, current, 1), [
                {'name': 'browser', 'cpu': 50, 'gpu': 45},
            ])

    def test_toggle_chooses_opposite_hardware_limit(self):
        for current, target in [('80', '100'), ('100', '80')]:
            self.threshold.write_text(current)
            with patch.object(client, 'THRESHOLD', self.threshold), \
                 patch.object(client.sys, 'argv', ['battery-charge', 'toggle']), \
                 patch.object(client.subprocess, 'run', return_value=subprocess.CompletedProcess([], 126)) as run:
                self.assertEqual(client.main(), 126)
                run.assert_called_once_with(['/usr/bin/pkexec', '/usr/local/libexec/dotfiles-set-charge-limit', target])

    def test_toggle_unreadable_or_unsupported_limit_never_authenticates(self):
        for value in ('99', None):
            if value is None:
                self.threshold.unlink()
            else:
                self.threshold.write_text(value)
            with patch.object(client, 'THRESHOLD', self.threshold), \
                 patch.object(client.sys, 'argv', ['battery-charge', 'toggle']), \
                 patch.object(client.subprocess, 'run') as run:
                self.assertEqual(client.main(), 1)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][0], '/usr/bin/notify-send')

    def test_widget_moves_to_indicators_without_disturbing_other_entries(self):
        layout = {'left': [{'id': 'menu'}], 'center': [], 'right': [
            {'id': 'omarchy.indicators', 'alwaysShow': False}, {'id': 'omarchy.clock'},
            {'id': 'omarchy.power', 'showPercentage': False},
            {'id': 'muness.battery-charge', 'type': 'qml'}]}
        before = copy.deepcopy(layout)
        module = {'id': 'muness.battery-charge', 'type': 'qml'}
        installer.place_widget(layout, module)
        self.assertEqual(layout['right'][0], module)
        self.assertEqual(layout['right'][1:], before['right'][:-1])
        once = copy.deepcopy(layout)
        installer.place_widget(layout, module)
        self.assertEqual(layout, once)
        self.assertEqual(layout['left'], before['left'])

    def test_widget_placement_falls_back_to_clock_then_center(self):
        module = {'id': 'muness.battery-charge', 'type': 'qml'}
        layout = {'right': [{'id': 'omarchy.clock'}]}
        installer.place_widget(layout, module)
        self.assertEqual(layout['right'], [module, {'id': 'omarchy.clock'}])
        layout = {'right': [{'id': 'omarchy.power'}]}
        installer.place_widget(layout, module)
        self.assertEqual(layout['center'], [module])
        self.assertEqual(layout['right'], [{'id': 'omarchy.power'}])

    def test_menu_preserves_user_content_and_is_idempotent(self):
        for original in ('{}\n', '{\n // user notes\n "custom": {"label": "Custom"}\n}\n'):
            once = installer.extend_menu(original, Path('/home/user name/.local/bin/battery-charge'))
            self.assertEqual(once, installer.extend_menu(once, Path('/home/user name/.local/bin/battery-charge')))
            self.assertEqual(once.count('"battery-charge.home"'), 1)
            if 'user notes' in original:
                self.assertIn('// user notes', once)
                self.assertIn('"custom": {"label": "Custom"}', once)
            stripped = '\n'.join(line for line in once.splitlines() if not line.strip().startswith('//'))
            import re
            data = json.loads(re.sub(r',\s*}', '}', stripped))
            self.assertIn("'/home/user name/.local/bin/battery-charge'", data['battery-charge.travel']['action'])


if __name__ == '__main__':
    unittest.main()
