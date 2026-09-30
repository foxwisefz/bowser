"""Readiness polling bounded by the startup deadline, not one socket reply."""
import asyncio
import json
import time


async def tab_count(endpoint):
    reader, writer = await asyncio.open_unix_connection(str(endpoint))
    try:
        writer.write(b'{"tool":"list_tabs"}\n')
        await writer.drain()
        data = await reader.readline()
        if not data:
            raise ConnectionError('agent closed before replying')
        reply = json.loads(data)
        return len(reply.get('tabs', [])) if reply.get('ok') else None
    finally:
        writer.close()
        await writer.wait_closed()


async def wait_for_tabs(endpoint, count, deadline, exited, probe_timeout=2, poll_interval=.01,
                        observe=None):
    attempts = 0
    last = 'agent socket not ready'
    while True:
        if exited():
            raise RuntimeError(f'Browser exited before restoring {count} tabs; last probe: {last}')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f'Browser restore {count} exceeded startup deadline after {attempts} probes; last probe: {last}')
        attempts += 1
        started = time.monotonic()
        try:
            actual = await asyncio.wait_for(tab_count(endpoint), min(probe_timeout, remaining))
            if observe:
                observe(started, time.monotonic(), actual, None)
            # A reply arriving past the overall deadline is not a passing sample.
            if actual == count and time.monotonic() < deadline:
                return
            last = f'agent reported {actual} tabs'
        except (FileNotFoundError, ConnectionError, TimeoutError) as error:
            last = type(error).__name__
            if observe:
                observe(started, time.monotonic(), None, last)
        await asyncio.sleep(min(poll_interval, max(0, deadline - time.monotonic())))
