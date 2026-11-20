#!/usr/bin/env python3
"""Development-only browser smoke for free clustering; not container acceptance."""

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

            async def drag_points(start, end, settle=0.02):
                start_css = css_point(*start)
                end_css = css_point(*end)
                await mouse("mouseMoved", *start_css)
                await mouse("mousePressed", *start_css)
                for step in range(1, 6):
                    x = start_css[0] + (end_css[0] - start_css[0]) * step / 5
                    y = start_css[1] + (end_css[1] - start_css[1]) * step / 5
                    await mouse("mouseMoved", x, y)
                await mouse("mouseReleased", *end_css)
                if settle:
                    await asyncio.sleep(settle)

            snapshot_js = """(function(){var g=SDD.app.game,r=SDD.app.renderer;return {state:g.state,phase:g.phase,customer:g.customerIndex,bagged:g.baggedItems,groups:g.baggedGroups,remaining:g.basket.remaining(),active:g.activeBatch.length?g.activeBatch[0].snack:null,queue:g.queue.map(function(b){return b.snack;}),scale:SDD.TABLE_SCALE,tableY:SDD.TABLE_Y,tags:r.priceTags.length,items:g.basket.items.filter(function(i){return !i.picked && g.basket.canPick(i.uid);}).map(function(i){var p=g.basket.exposedPoint(i.uid),e=r.localToGlobal(p),c=r.localToGlobal(i);return {uid:i.uid,snack:i.snack,x:e.x,y:e.y,cx:c.x,cy:c.y};})};}())"""

            async def drag_item(item, target, scale=0.78, table_y=400, settle=0.02):
                target_global = (target[0] * scale, table_y + target[1] * scale)
                end = (target_global[0] + item["x"] - item["cx"], target_global[1] + item["y"] - item["cy"])
                await drag_points((item["x"], item["y"]), end, settle)

            start = await cdp.evaluate("JSON.stringify(document.getElementById('start-button').getBoundingClientRect())")
            start_rect = json.loads(start)
            await click_css(start_rect["left"] + start_rect["width"] / 2, start_rect["top"] + start_rect["height"] / 2)
            await cdp.wait("SDD.app.game && SDD.app.game.phase === 'pouring'")
            await cdp.wait("SDD.app.game.pourElapsed > 0.65", 5)
            await cdp.shot("02-pour.png")
            await cdp.wait("SDD.app.game.phase === 'playing'", 10)
            assert await cdp.evaluate("SDD.app.game.totalItems") == 8
            assert await cdp.evaluate("SDD.app.game.baggedGroups") == 0

            first = await cdp.evaluate(snapshot_js)
            by_snack = {}
            for item in first["items"]:
                by_snack.setdefault(item["snack"], []).append(item)
            assert len(by_snack) == 2 and all(len(items) == 2 for items in by_snack.values())
            snack_a, snack_b = list(by_snack)
            same = by_snack[snack_a]
            blocker, other = by_snack[snack_b]
            scale, table_y = first["scale"], first["tableY"]

            # Put one foreign package below the future pair, then complete the pair around it.
            await drag_item(blocker, (150, 300), scale, table_y)
            await drag_item(same[0], (130, 170), scale, table_y)
            await drag_item(same[1], (160, 170), scale, table_y)
            blocked = await cdp.evaluate(snapshot_js)
            assert blocked["groups"] == 0 and blocked["active"] is None and blocked["queue"] == []
            assert blocked["remaining"] == 4
            await cdp.shot("03-foreign-blocked.png")

            # Moving the blocker away releases the complete pair. Immediately use the real
            # magnet button to queue the other kind while the first pair is still flying.
            current = await cdp.evaluate(snapshot_js)
            moved_blocker = next(item for item in current["items"] if item["uid"] == blocker["uid"])
            await drag_item(moved_blocker, (350, 600), scale, table_y, settle=0)
            await click_logical(586, 45)
            continuous = await cdp.evaluate(snapshot_js)
            assert continuous["active"] == snack_a, continuous
            assert continuous["queue"] == [snack_b], continuous
            await cdp.shot("04-continuous-batches.png")
            await cdp.wait("SDD.app.game.customerIndex === 2 && SDD.app.game.phase === 'pouring'", 15)
            assert await cdp.evaluate("SDD.app.game.baggedGroups") == 2
            assert await cdp.evaluate("SDD.app.renderer.priceTags.length") >= 1
            await cdp.shot("05-next-customer-tags.png")

            elapsed = await cdp.evaluate("SDD.app.game.elapsed")
            await cdp.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:function(){return true;}});document.dispatchEvent(new Event('visibilitychange'));")
            await asyncio.sleep(0.45)
            assert await cdp.evaluate("SDD.app.rafId") == 0
            assert abs(await cdp.evaluate("SDD.app.game.elapsed") - elapsed) < 0.001
            await cdp.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:function(){return false;}});document.dispatchEvent(new Event('visibilitychange'));")
            await cdp.wait("SDD.app.game.phase === 'playing'", 10)

            async def place_remaining():
                targets = [(110, 150), (410, 150), (130, 580), (420, 580), (110, 710), (430, 710)]
                target_for = {}
                for _ in range(30):
                    state = await cdp.evaluate(snapshot_js)
                    if state["phase"] != "playing" or state["state"] != "playing":
                        return state
                    if not state["items"]:
                        if state["remaining"] == 0:
                            await cdp.wait("SDD.app.game.state === 'complete' || SDD.app.game.phase === 'pouring'", 15)
                            return await cdp.evaluate(snapshot_js)
                        await asyncio.sleep(0.05)
                        continue
                    item = state["items"][0]
                    if item["snack"] not in target_for:
                        target_for[item["snack"]] = targets[len(target_for)]
                    same_kind = [candidate for candidate in state["items"] if candidate["snack"] == item["snack"]]
                    base = target_for[item["snack"]]
                    for index, candidate in enumerate(same_kind):
                        latest = await cdp.evaluate(snapshot_js)
                        current_item = next((entry for entry in latest["items"] if entry["uid"] == candidate["uid"]), None)
                        if current_item:
                            await drag_item(current_item, (base[0] + index * 28, base[1]), latest["scale"], latest["tableY"])
                raise AssertionError("too many drags or inaccessible packages")

            await place_remaining()
            await cdp.wait("SDD.app.game.state === 'complete'", 15)
            assert await cdp.evaluate("SDD.app.game.baggedItems") == 8
            assert await cdp.evaluate("SDD.app.game.result.total_groups") == 4
            await cdp.shot("06-complete.png")

            await cdp.call("Emulation.setScriptExecutionDisabled", {"value": True})
            await cdp.call("Page.navigate", {"url": "http://127.0.0.1:%d/" % http_port})
            await asyncio.sleep(0.5)
            static_text = await cdp.evaluate("document.getElementById('boot-title').textContent + '|' + document.querySelector('h1').textContent")
            assert static_text == "柜台准备中|零食叮叮咚"
            await cdp.shot("07-static-first-screen.png")
            assert not cdp.errors, cdp.errors
            print(json.dumps({
                "result": "PASS",
                "scope": "real mouse free clustering, foreign blocking/release, immediate next batch, two customers, hidden/resume, static first screen",
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
