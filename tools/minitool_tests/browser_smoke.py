#!/usr/bin/env python3
"""Development-only browser smoke for the mini-tool; not container acceptance."""

import asyncio
import base64
import functools
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "build" / "minitool"
OUT = ROOT / "build" / "minitool-smoke"
CHROME = os.environ.get("CHROME_BIN", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass


class CDP:
    def __init__(self, ws):
        self.ws = ws
        self.next_id = 1
        self.errors = []

    async def call(self, method, params=None):
        message_id = self.next_id
        self.next_id += 1
        await self.ws.send(json.dumps({"id": message_id, "method": method, "params": params or {}}))
        while True:
            message = json.loads(await self.ws.recv())
            if message.get("id") == message_id:
                if "error" in message:
                    raise RuntimeError(method + ": " + json.dumps(message["error"]))
                return message.get("result", {})
            if message.get("method") == "Runtime.exceptionThrown":
                self.errors.append(message["params"]["exceptionDetails"].get("text", "runtime exception"))
            if message.get("method") == "Log.entryAdded":
                entry = message["params"]["entry"]
                if entry.get("level") == "error":
                    self.errors.append(entry.get("text", "log error"))

    async def evaluate(self, expression):
        result = await self.call("Runtime.evaluate", {"expression": expression, "returnByValue": True, "awaitPromise": True})
        if "exceptionDetails" in result:
            raise RuntimeError(json.dumps(result["exceptionDetails"], ensure_ascii=False))
        return result.get("result", {}).get("value")

    async def wait(self, expression, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if await self.evaluate(expression):
                return
            await asyncio.sleep(0.10)
        raise AssertionError("Timed out: " + expression)

    async def shot(self, name):
        result = await self.call("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": True})
        (OUT / name).write_bytes(base64.b64decode(result["data"]))


async def main():
    OUT.mkdir(parents=True, exist_ok=True)
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    http_port = server.getsockname()[1]
    server.close()
    debug_socket = socket.socket()
    debug_socket.bind(("127.0.0.1", 0))
    debug_port = debug_socket.getsockname()[1]
    debug_socket.close()
    handler = functools.partial(QuietHandler, directory=str(SITE))
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", http_port), handler)
    thread = threading.Thread(target=httpd.serve_forever)
    thread.daemon = True
    thread.start()
    profile = "/tmp/mydearwife-minitool-browser-profile"
    shutil.rmtree(profile, ignore_errors=True)
    proc = subprocess.Popen([
        CHROME, "--headless=new", "--no-sandbox", "--remote-debugging-port=" + str(debug_port),
        "--user-data-dir=" + profile, "--window-size=480,960", "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        target = None
        for _ in range(100):
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/json" % debug_port, timeout=0.3) as response:
                    targets = json.load(response)
                target = next(item for item in targets if item.get("type") == "page")
                break
            except Exception:
                await asyncio.sleep(0.1)
        if not target:
            raise RuntimeError("Chrome DevTools target unavailable")
        async with websockets.connect(target["webSocketDebuggerUrl"], max_size=None) as ws:
            cdp = CDP(ws)
            await cdp.call("Runtime.enable")
            await cdp.call("Page.enable")
            await cdp.call("Log.enable")
            await cdp.call("Emulation.setDeviceMetricsOverride", {"width": 480, "height": 960, "deviceScaleFactor": 1, "mobile": True})
            await cdp.call("Page.navigate", {"url": "http://127.0.0.1:%d/" % http_port})
            await cdp.wait("window.SDD && SDD.app && !document.getElementById('home-panel').hidden", 20)
            assert "9.46" in await cdp.evaluate("document.getElementById('storage-status').textContent")
            await cdp.shot("01-home.png")

            rect = await cdp.evaluate("JSON.stringify(document.getElementById('game-canvas').getBoundingClientRect())")
            canvas = json.loads(rect)

            def css_point(x, y):
                return canvas["left"] + x * canvas["width"] / 720, canvas["top"] + y * canvas["height"] / 1280

            async def mouse(kind, x, y, clicks=1):
                await cdp.call("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "clickCount": clicks})

            async def click_css(x, y):
                await mouse("mousePressed", x, y)
                await mouse("mouseReleased", x, y)

            async def click_logical(x, y):
                await click_css(*css_point(x, y))

            async def double_logical(x, y):
                await click_logical(x, y)
                await asyncio.sleep(0.08)
                await click_logical(x, y)

            async def drag_logical(x1, y1, x2, y2):
                start = css_point(x1, y1)
                end = css_point(x2, y2)
                await mouse("mouseMoved", *start)
                await mouse("mousePressed", *start)
                for step in range(1, 8):
                    x = start[0] + (end[0] - start[0]) * step / 7
                    y = start[1] + (end[1] - start[1]) * step / 7
                    await mouse("mouseMoved", x, y)
                    await asyncio.sleep(0.015)
                await mouse("mouseReleased", *end)
                await asyncio.sleep(0.12)

            start = await cdp.evaluate("JSON.stringify(document.getElementById('start-button').getBoundingClientRect())")
            start_rect = json.loads(start)
            await click_css(start_rect["left"] + start_rect["width"] / 2, start_rect["top"] + start_rect["height"] / 2)
            await cdp.wait("SDD.app.game && SDD.app.game.phase === 'pouring'")
            await cdp.wait("SDD.app.game.pourElapsed > 1.45", 5)
            await cdp.shot("02-pour.png")
            await cdp.wait("SDD.app.game.phase === 'playing'", 10)
            assert await cdp.evaluate("SDD.app.game.totalItems") == 8

            await click_logical(577, 240)
            assert await cdp.evaluate("SDD.app.game.auto") is False

            snapshot_js = """(function(){var g=SDD.app.game,r=SDD.app.renderer;return {state:g.state,phase:g.phase,customer:g.customerIndex,bagged:g.baggedItems,groups:g.baggedGroups,returned:g.returnCount,auto:g.auto,items:g.basket.items.filter(function(i){return !i.picked && g.basket.canPick(i.uid);}).map(function(i){var p=g.basket.exposedPoint(i.uid);return {uid:i.uid,snack:i.snack,x:r.localToGlobal(p).x,y:r.localToGlobal(p).y};}),zones:g.sections.map(function(s){return s.map(function(i){return {uid:i.uid,snack:i.snack};});})};}())"""
            first = await cdp.evaluate(snapshot_js)
            pair = None
            for a in first["items"]:
                for b in first["items"]:
                    if a["uid"] != b["uid"] and a["snack"] != b["snack"]:
                        pair = (a, b)
                        break
                if pair:
                    break
            assert pair, "level seed should expose two snack kinds"
            snack_a, snack_b = pair[0]["snack"], pair[1]["snack"]
            zone_for = {snack_a: 0, snack_b: 1}
            await drag_logical(pair[0]["x"], pair[0]["y"], 106, 431)
            latest = await cdp.evaluate(snapshot_js)
            second = next(item for item in latest["items"] if item["uid"] == pair[1]["uid"])
            await drag_logical(second["x"], second["y"], 106, 431)
            mixed = await cdp.evaluate(snapshot_js)
            assert len({item["snack"] for item in mixed["zones"][0]}) == 2
            await cdp.shot("03-mixed.png")
            await click_logical(106 + -26 * 0.78, 431 + -18 * 0.78)
            await cdp.wait("SDD.app.game.returnCount === 1")
            assert await cdp.evaluate("SDD.app.game.baggedGroups") == 0

            async def place_remaining():
                for _ in range(20):
                    state = await cdp.evaluate(snapshot_js)
                    if state["phase"] != "playing" or state["state"] != "playing":
                        return state
                    if not state["items"]:
                        return state
                    item = state["items"][0]
                    if item["snack"] not in zone_for:
                        zone_for[item["snack"]] = len(zone_for)
                    zone = zone_for[item["snack"]]
                    centers = [(106, 431), (362, 431), (106, 578), (362, 578)]
                    await drag_logical(item["x"], item["y"], *centers[zone])
                raise AssertionError("too many drags")

            await place_remaining()
            assert await cdp.evaluate("SDD.app.game.queue.length") == 2
            await double_logical(360, 900)
            await cdp.wait("SDD.app.game.customerIndex === 2 && SDD.app.game.phase === 'pouring'", 15)
            elapsed = await cdp.evaluate("SDD.app.game.elapsed")
            await cdp.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:function(){return true;}});document.dispatchEvent(new Event('visibilitychange'));")
            await asyncio.sleep(0.45)
            assert await cdp.evaluate("SDD.app.rafId") == 0
            assert abs(await cdp.evaluate("SDD.app.game.elapsed") - elapsed) < 0.001
            await cdp.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:function(){return false;}});document.dispatchEvent(new Event('visibilitychange'));")
            await cdp.wait("SDD.app.game.phase === 'playing'", 10)
            await place_remaining()
            await double_logical(360, 900)
            await cdp.wait("SDD.app.game.state === 'complete'", 15)
            assert await cdp.evaluate("SDD.app.game.baggedItems") == 8
            assert await cdp.evaluate("SDD.app.game.result.total_groups") == 4
            await cdp.shot("04-complete.png")

            await cdp.call("Emulation.setScriptExecutionDisabled", {"value": True})
            await cdp.call("Page.navigate", {"url": "http://127.0.0.1:%d/" % http_port})
            await asyncio.sleep(0.5)
            static_text = await cdp.evaluate("document.getElementById('boot-title').textContent + '|' + document.querySelector('h1').textContent")
            assert static_text == "柜台准备中|零食叮叮咚"
            await cdp.shot("05-static-first-screen.png")
            assert not cdp.errors, cdp.errors
            print(json.dumps({
                "result": "PASS",
                "scope": "real browser start, pour lock, drag, mixed return, manual FIFO, two customers, hidden/resume, static first screen",
                "bagged_items": 8,
                "console_errors": len(cdp.errors),
                "screenshots": str(OUT),
                "acceptance": "development aid only; XiaoHongShu simulator and devices still required",
            }, ensure_ascii=False, indent=2))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        httpd.shutdown()
        httpd.server_close()


if __name__ == "__main__":
    asyncio.run(main())
