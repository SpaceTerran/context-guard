#!/usr/bin/env python3
"""Ask the running Codex app server which sessions it has loaded, for live-test/codex-session.sh.

    uv run -q --with websockets python3 codex_rpc.py loaded

Prints one JSON object per loaded session: {"id", "cwd", "ephemeral", "status"}. Exits 3 when no
app server is listening. It only reads (thread/loaded/list, thread/read), connects to the control
socket's "/" path only (never /daemon/shutdown), and answers no requests from the server.
"""
import asyncio
import json
import os
import sys

import websockets


def socket_path() -> str:
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    return os.path.join(home, "app-server-control", "app-server-control.sock")


async def loaded() -> None:
    path = socket_path()
    if not os.path.exists(path):
        sys.exit(3)
    try:
        ws = await websockets.unix_connect(path, uri="ws://localhost/", max_size=None)
    except OSError:
        sys.exit(3)
    async with ws:
        next_id = 0

        async def call(method: str, params: dict) -> dict:
            nonlocal next_id
            next_id += 1
            mine = next_id
            await ws.send(json.dumps({"id": mine, "method": method, "params": params}))
            while True:
                msg = json.loads(await asyncio.wait_for(ws.recv(), 30))
                # Notifications and the server's own requests aren't answers.
                if msg.get("id") == mine and "method" not in msg:
                    if "error" in msg:
                        raise SystemExit(f"{method}: {msg['error']}")
                    return msg["result"]

        await call("initialize", {"clientInfo": {"name": "context_guard_live_test", "title": None, "version": "1"},
                                  "capabilities": {"experimentalApi": True}})
        await ws.send(json.dumps({"method": "initialized"}))
        ids: list[str] = []
        cursor = None
        while True:
            page = await call("thread/loaded/list", {"cursor": cursor} if cursor else {})
            ids += page.get("data", [])
            cursor = page.get("nextCursor")
            if not cursor:
                break
        for tid in ids:
            t = (await call("thread/read", {"threadId": tid}))["thread"]
            print(json.dumps({"id": tid, "cwd": t.get("cwd"), "ephemeral": bool(t.get("ephemeral")),
                              "status": (t.get("status") or {}).get("type")}))


if __name__ == "__main__":
    if sys.argv[1:] != ["loaded"]:
        sys.exit(__doc__)
    asyncio.run(loaded())
