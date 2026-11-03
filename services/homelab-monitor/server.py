#!/usr/bin/env python3
"""Homelab Monitor: no database, no agents, no third-party Python packages.

On the central MS-01, fetch one-shot JSON from two SSH hosts and from
local Linux sysfs. Serve the latest IN-MEMORY snapshot to the browser.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
STATIC = ROOT / 'static'
LOG = logging.getLogger('homelab-monitor')

DEMO = {
    'faex1': {'name':'FAEX1','cpu':{'name':'AMD Ryzen AI Max+ 395','readings':[{'label':'Tctl','c':37.4}]},
              'gpu':{'name':'AMD Radeon 8060S','readings':[{'label':'Edge','c':35.0}]},
              'ssds':[{'id':'a','name':'Samsung 990 PRO 2 TB — Ubuntu','device':'nvme1','pci':None,'c':35.9},
                      {'id':'b','name':'Samsung 990 PRO 2 TB — Windows','device':'nvme0','pci':None,'c':35.9},
                      {'id':'c','name':'Intel Optane P5800X 1.6 TB — Data','device':'nvme2','pci':None,'c':29.9}], 'expected_ssds':3},
    'ms01': {'name':'MS-01','cpu':{'name':'Intel Core i9-13900H','readings':[{'label':'Package','c':47.0}]},
             'gpu':{'name':'NVIDIA RTX 2000E Ada','readings':[{'label':'GPU core','c':43.0}]},
             'ssds':[{'id':'p','name':'Samsung PM9A3 15.36 TB — Ubuntu','device':'nvme0','pci':None,'c':41.9}], 'expected_ssds':1},
    'flashstor':{'name':'FLASHSTOR 12 PRO','cpu':{'name':'Intel Celeron N5105','readings':[{'label':'Package','c':56.0}]},
                 'gpu':None,'ssds':[{'id':str(i),'name':'Crucial P3 Plus 4 TB','device':f'nvme{i}','pci':['04:00.0','05:00.0','06:00.0','07:00.0','0a:00.0','0b:00.0','0c:00.0','0d:00.0','10:00.0','11:00.0','12:00.0','13:00.0'][i], 'c':v}
                                   for i,v in enumerate([44.9,45.9,41.9,39.9,46.9,45.9,42.9,41.9,44.9,43.9,38.9,38.9])], 'expected_ssds':12}
}

class Monitor:
    def __init__(self, config, demo=False):
        self.config = config
        self.demo = demo
        self.interval = float(config.get('interval_seconds', 5))
        if not 2 <= self.interval <= 60:
            raise ValueError('interval_seconds must be between 2 and 60')
        self.hosts = config['hosts']
        ids = [h['id'] for h in self.hosts]
        if len(set(ids)) != len(ids):
            raise ValueError('Duplicate host ids')
        for h in self.hosts:
            if h['id'] not in ('faex1', 'ms01', 'flashstor'):
                raise ValueError('Host id must be faex1, ms01, or flashstor')
            if h.get('transport') not in ('local', 'ssh'):
                raise ValueError('Invalid transport')
            if h['transport'] == 'ssh' and not h.get('ssh_target'):
                raise ValueError('Missing ssh_target for ' + h['id'])
        self.lock = threading.Lock()
        self.state = {h['id']: {'data': None, 'last_ok_at': None, 'last_attempt_at': None,
                                'last_error': 'Waiting for first sample', 'is_healthy': False}
                      for h in self.hosts}
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.cycle_condition = threading.Condition()
        self.cycle_revision = 0

    def collect(self, host):
        host_id = host['id']
        if self.demo:
            return dict(DEMO[host_id])
        if host['transport'] == 'ssh':
            ssh_target = host['ssh_target']
            # SSH aliases may be configured through ~/.ssh/config. No shell interpolation locally.
            # Strict host-key verification is intentional: connect once manually first.
            ssh_options = ['-o','BatchMode=yes','-o','ConnectTimeout=3',
                           '-o','ServerAliveInterval=2','-o','ServerAliveCountMax=1','-T']
            if host_id == 'flashstor':
                code = (ROOT / 'collect_flashstor.sh').read_text(encoding='utf-8')
                cmd = ['ssh', *ssh_options, ssh_target, 'sh', '-s']
            else:
                code = (ROOT / 'collect_linux.py').read_text(encoding='utf-8')
                cmd = ['ssh', *ssh_options, ssh_target, 'python3', '-', '--profile', host_id]
            result = subprocess.run(cmd, input=code, text=True, capture_output=True,
                                    timeout=8, check=False)
        else:
            if host_id == 'flashstor':
                cmd = ['sh', str(ROOT / 'collect_flashstor.sh')]
            else:
                cmd = [sys.executable, str(ROOT / 'collect_linux.py'), '--profile', host_id]
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=8, check=False)
        if result.returncode:
            msg = result.stderr.strip() or f'Collector returned exit code {result.returncode}'
            raise RuntimeError(msg[-300:])
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError('Collector did not return valid JSON') from exc
        if data.get('name') is None or not isinstance(data.get('ssds'), list) or not isinstance(data.get('cpu'), dict):
            raise RuntimeError('Collector returned unexpected data')
        if len(result.stdout) > 100_000:
            raise RuntimeError('Collector returned too much data')
        return data

    def sample_one(self, host):
        now = time.time()
        try:
            data = self.collect(host)
            with self.lock:
                self.state[host['id']] = {'data': data, 'last_ok_at': time.time(),
                                          'last_attempt_at': now, 'last_error': None,
                                          'is_healthy': True}
        except Exception as exc:
            LOG.warning('%s: %s', host['id'], exc)
            with self.lock:
                old = self.state[host['id']]
                self.state[host['id']] = {**old, 'last_attempt_at': now,
                                          'last_error': str(exc), 'is_healthy': False}

    def loop(self):
        with ThreadPoolExecutor(max_workers=len(self.hosts)) as pool:
            while not self.stop.is_set():
                started = time.monotonic()
                futures = [pool.submit(self.sample_one, h) for h in self.hosts]
                for f in as_completed(futures):
                    f.result()
                with self.cycle_condition:
                    self.cycle_revision += 1
                    self.cycle_condition.notify_all()
                    self.wake.clear()
                self.wake.wait(max(0, self.interval - (time.monotonic() - started)))

    def refresh(self, timeout=12):
        with self.cycle_condition:
            revision = self.cycle_revision
            self.wake.set()
            if not self.cycle_condition.wait_for(
                    lambda: self.cycle_revision > revision, timeout=timeout):
                raise TimeoutError('Sensor refresh timed out')
        return self.snapshot()

    def snapshot(self):
        now = time.time()
        with self.lock:
            hosts = []
            for host in self.hosts:
                info = self.state[host['id']]
                age = now - info['last_ok_at'] if info['last_ok_at'] is not None else None
                online = info['is_healthy'] and age is not None and age <= self.interval + 14
                hosts.append({'id': host['id'], 'label':host.get('label',host['id']),
                              'online': online, 'age_seconds':round(age,1) if age is not None else None,
                              'error':info['last_error'] if not online else None,
                              'data':info['data']})
        return {'server_time':now, 'interval_seconds':self.interval,
                'demo':self.demo, 'hosts':hosts}

class Handler(BaseHTTPRequestHandler):
    monitor = None
    def log_message(self, fmt, *args):
        LOG.debug('%s - %s', self.address_string(), fmt % args)

    def send(self, status, content_type, body):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if urlsplit(self.path).path != '/api/refresh':
            return self.send(404, 'text/plain', b'Not found')
        origin = self.headers.get('Origin')
        if origin and urlsplit(origin).netloc != self.headers.get('Host'):
            return self.send(403, 'text/plain', b'Forbidden')
        try:
            payload = self.monitor.refresh()
        except TimeoutError:
            return self.send(504, 'text/plain', b'Sensor refresh timed out')
        body = json.dumps(
            payload, ensure_ascii=False, allow_nan=False
        ).encode()
        self.send(200, 'application/json; charset=utf-8', body)

    def do_GET(self):
        route = urlsplit(self.path).path
        if route == '/api/live':
            body = json.dumps(self.monitor.snapshot(), ensure_ascii=False, allow_nan=False).encode('utf-8')
            return self.send(200, 'application/json; charset=utf-8', body)
        static = {'/':('index.html','text/html; charset=utf-8'),
                  '/index.html':('index.html','text/html; charset=utf-8'),
                  '/style.css':('style.css','text/css; charset=utf-8'),
                  '/app.js':('app.js','text/javascript; charset=utf-8'),
                  '/favicon.svg':('favicon.svg','image/svg+xml'),
                  '/manifest.webmanifest':('manifest.webmanifest','application/manifest+json'),
                  '/sw.js':('sw.js','text/javascript; charset=utf-8'),
                  '/apple-touch-icon.png':('apple-touch-icon.png','image/png'),
                  '/icon-192.png':('icon-192.png','image/png'),
                  '/icon-512.png':('icon-512.png','image/png')}
        if route in static:
            name, mime = static[route]
            return self.send(200, mime, (STATIC/name).read_bytes())
        return self.send(404, 'text/plain; charset=utf-8', b'Not found')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(ROOT/'config.json'))
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--demo', action='store_true', help='Demo only: use frozen example readings')
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    config = json.loads(Path(args.config).read_text(encoding='utf-8'))
    mon = Monitor(config, demo=args.demo)
    Handler.monitor = mon
    worker = threading.Thread(target=mon.loop, name='poller', daemon=True)
    worker.start()
    with ThreadingHTTPServer((args.bind,args.port), Handler) as http:
        LOG.info('Serving http://%s:%s/ (%s)', args.bind, args.port, 'DEMO' if args.demo else 'LIVE')
        try:
            http.serve_forever(poll_interval=0.5)
        except KeyboardInterrupt:
            pass
        finally:
            mon.stop.set()
            http.server_close()

if __name__ == '__main__':
    main()
