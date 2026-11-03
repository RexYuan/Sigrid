import importlib.util
import json
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('monitor', ROOT/'server.py')
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)

class MonitorTests(unittest.TestCase):
    def test_demo_snapshots(self):
        config = json.loads((ROOT/'config.json').read_text())
        m=monitor.Monitor(config, demo=True)
        for host in config['hosts']:
            m.sample_one(host)
        snap=m.snapshot()
        self.assertEqual(len(snap['hosts']),3)
        self.assertTrue(all(h['online'] for h in snap['hosts']))
        self.assertEqual(sum(len(h['data']['ssds']) for h in snap['hosts']),16)
        self.assertEqual(len(snap['hosts'][2]['data']['ssds']),12)
        self.assertTrue(
            all(len(h['data']['cpu']['readings']) == 1
                for h in snap['hosts'])
        )
        self.assertAlmostEqual(max(s['c'] for s in snap['hosts'][2]['data']['ssds']),46.9)

    def test_offline_not_misreported(self):
        config=json.loads((ROOT/'config.json').read_text())
        m=monitor.Monitor(config, demo=True)
        self.assertFalse(any(h['online'] for h in m.snapshot()['hosts']))
        m.sample_one(config['hosts'][0]);self.assertTrue(m.snapshot()['hosts'][0]['online'])
        with m.lock:
            m.state['faex1']['is_healthy']=False
            m.state['faex1']['last_error']='SSH unavailable'
        self.assertFalse(m.snapshot()['hosts'][0]['online'])
        self.assertEqual(m.snapshot()['hosts'][0]['error'],'SSH unavailable')

    def test_flashstor_fixture(self):
        # Mock sysfs, not the obsolete `sensors` command.
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            hwmons = root / 'hwmon'
            nvmes = root / 'nvme'
            hwmons.mkdir()
            nvmes.mkdir()
            cpu = hwmons / 'hwmon0'
            cpu.mkdir()
            (cpu / 'name').write_text('coretemp\n')
            for i, (label, raw) in enumerate([
                ('Package id 0', 56000), ('Core 0', 49000),
                ('Core 1', 51000)], 1):
                (cpu / f'temp{i}_label').write_text(label + '\n')
                (cpu / f'temp{i}_input').write_text(f'{raw}\n')

            # Reverse PCI order deliberately to test sorting.
            for i, (pci, raw) in enumerate([
                ('05:00.0', 45900), ('04:00.0', 44900)]):
                controller = root / 'devices' / ('0000:' + pci) / 'nvme' / f'nvme{i}'
                hw = controller / 'hwmon' / f'hwmon{i + 1}'
                hw.mkdir(parents=True)
                (controller / 'device').symlink_to(controller.parent.parent)
                (nvmes / f'nvme{i}').symlink_to(controller)
                (hwmons / f'hwmon{i + 1}').symlink_to(hw)
                (hw / 'name').write_text('nvme\n')
                (hw / 'temp1_input').write_text(f'{raw}\n')
                (hw / 'temp2_input').write_text('99900\n')

            env = {**os.environ, 'HWMON_BASE': str(hwmons),
                   'NVME_BASE': str(nvmes)}
            r = subprocess.run(
                ['sh', str(ROOT / 'collect_flashstor.sh')],
                capture_output=True, text=True, check=True, env=env
            )
            data = json.loads(r.stdout)

        self.assertEqual(
            [x['c'] for x in data['cpu']['readings']],
            [56.0, 51.0]
        )
        self.assertEqual(
            [s['c'] for s in data['ssds']], [44.9, 45.9]
        )
        self.assertEqual(
            [s['pci'] for s in data['ssds']],
            ['04:00.0', '05:00.0']
        )
        self.assertEqual(
            [s['device'] for s in data['ssds']],
            ['nvme1', 'nvme0']
        )
        self.assertEqual(data['expected_ssds'], 12)

if __name__=='__main__':
    unittest.main()
