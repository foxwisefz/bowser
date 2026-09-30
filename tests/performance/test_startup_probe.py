import asyncio
import contextlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from startup_probe import wait_for_tabs


class StartupProbeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.home = tempfile.TemporaryDirectory(prefix='startup-probe-', dir='/tmp')
        self.endpoint = Path(self.home.name) / 'agent.sock'
        self.tasks = set()
        self.attempts = 0
        self.mode = 'recover'

        async def reply(reader, writer):
            task = asyncio.current_task(); self.tasks.add(task)
            self.attempts += 1
            attempt = self.attempts
            try:
                await reader.readline()
                if self.mode == 'hang' or attempt == 1:
                    await asyncio.sleep(5)
                writer.write(json.dumps({'ok': True, 'tabs': [1] * 100}).encode() + b'\n')
                await writer.drain()
            except ConnectionError:
                pass
            finally:
                writer.close()
                with contextlib.suppress(ConnectionError):
                    await writer.wait_closed()
                self.tasks.discard(task)
        self.server = await asyncio.start_unix_server(reply, path=self.endpoint)

    async def asyncTearDown(self):
        self.server.close()
        tasks = list(self.tasks)
        for task in tasks: task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await self.server.wait_closed()
        self.home.cleanup()

    async def test_slow_probe_retries_without_resetting_elapsed_time(self):
        start = time.monotonic()
        probes = []
        await wait_for_tabs(self.endpoint, 100, start + 1, lambda: False,
                            probe_timeout=.03, poll_interval=.001,
                            observe=lambda *probe: probes.append(probe))
        self.assertGreaterEqual(self.attempts, 2)
        self.assertGreaterEqual(time.monotonic() - start, .03)
        self.assertEqual(probes[0][3], 'TimeoutError')
        self.assertIsNone(probes[0][2])
        self.assertEqual(probes[-1][2:], (100, None))
        self.assertTrue(all(start <= begin <= end for begin, end, _, _ in probes))

    async def test_hung_agent_still_hits_overall_deadline(self):
        self.mode = 'hang'
        start = time.monotonic()
        with self.assertRaisesRegex(TimeoutError, 'restore 100 exceeded startup deadline'):
            await wait_for_tabs(self.endpoint, 100, start + .1, lambda: False,
                                probe_timeout=.03, poll_interval=.001)
        self.assertGreaterEqual(self.attempts, 2)
        self.assertLess(time.monotonic() - start, 1)

    async def test_process_exit_is_immediate_failure(self):
        with self.assertRaisesRegex(RuntimeError, 'Browser exited'):
            await wait_for_tabs(self.endpoint, 100, time.monotonic() + 20, lambda: True)
        self.assertEqual(self.attempts, 0)
