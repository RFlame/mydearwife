#!/usr/bin/env python3
"""Web 真鼠标全流程：顾客图鉴 → 第 1 关完整结账与倒货换客 → 第 2 关百件桌面。

只读桥由游戏在 ?smoke=1 时提供，脚本不直接调用 pick/return/settle。
第 2 关验证拖动、附近同款双击、整批退货和桌边首件 LED，不自动点完全部 300 件。
依赖：本机 Chrome、python3 websockets、已启动的 HTTP 服务。
用法：python3 -I tools/web_smoke.py [url] [out_dir]
"""
import asyncio
import base64
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

import websockets

CHROME = os.environ.get("CHROME_BIN", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
PORT = 9222
console_logs = []


async def main() -> int:
    console_logs.clear()
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8765/"
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "docs/images"
    parts = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qs(parts.query)
    query["smoke"] = ["1"]
    query.setdefault("seed", ["42"])
    url = urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query, doseq=True)))
    os.makedirs(out_dir, exist_ok=True)
    profile = "/tmp/godot_web_smoke_profile"
    shutil.rmtree(profile, ignore_errors=True)  # 清空 IndexedDB，始终从第 1 关开始
    proc = subprocess.Popen([
        CHROME, "--headless=new", "--no-sandbox", "--use-angle=swiftshader",
        "--enable-unsafe-swiftshader", "--window-size=720,1280",
        "--remote-debugging-port=%d" % PORT, "--user-data-dir=" + profile,
        "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = False
    try:
        ws_url = await wait_target()
        async with websockets.connect(ws_url, max_size=None) as ws:
            client = CDP(ws)
            await client.call("Runtime.enable")
            await client.call("Page.enable")
            await client.call("Page.navigate", {"url": url})
            print("loading", url)
            home = await wait_snapshot(client, lambda s: s.get("page") == "home", 30)
            assert home["page"] == "home"
            await client.shot(os.path.join(out_dir, "web_home.png"))

            await client.click(442, 1166)  # 主页真实点击“顾客图鉴”
            customers = await wait_snapshot(client, lambda s: s.get("page") == "customers", 8)
            assert customers["profiles"] == 12 and customers["total"] == 12
            await client.shot(os.path.join(out_dir, "web_customers.png"))
            await client.click(360, 1176)  # 返回店铺
            await wait_snapshot(client, lambda s: s.get("page") == "home", 8)

            await client.click(360, 398)  # 开始营业 · 第 1 关
            arriving = await wait_snapshot(client, lambda s: s.get("page") == "game", 15)
            assert arriving["switching"], "new customer should begin with basket arrival"
            pouring = await wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("pouring") and s.get("basket_tilt", 0) >= 0.35, 5)
            assert pouring["switching"] and pouring["basket_present"], "tilted basket must remain visible and lock table input"
            await client.shot(os.path.join(out_dir, "web_pour.png"), 0.0)
            game = await wait_snapshot(client, lambda s: s.get("page") == "game" and not s.get("switching"), 8)
            assert not game["basket_present"] and game["live_basket_count"] == 0, "empty basket must disappear before input unlocks"
            assert_layout(game)
            assert game["level"] == 1 and game["customer"] == 1 and game["customers"] == 2
            assert game["remaining"] == 4 and game["total_items"] == 8
            assert game["customer_discovered"], "first customer must unlock collection entry"
            first_customer_id = game["customer_id"]
            await asyncio.sleep(0.5)
            await client.shot(os.path.join(out_dir, "web_game.png"))

            # 全部通过真实鼠标制造 A+B 混台；无异类露出时先结掉当前纯同款批次。
            mixed = None
            for _ in range(30):
                s = await snapshot(client)
                if s["page"] == "game" and s.get("switching"):
                    await asyncio.sleep(0.12)
                    continue
                if s["page"] == "game" and len(s["tray"]) == 2 and len({e["snack"] for e in s["tray"]}) == 2:
                    mixed = s
                    break
                if any(e["flying"] for e in s["tray"]):
                    await asyncio.sleep(0.15)
                    continue
                if not s["tray"]:
                    await click_point(client, s["available"][0])
                else:
                    current = s["tray"][0]["snack"]
                    different = next((a for a in s["available"] if a["snack"] != current and a["size"] <= s["free_slots"]), None)
                    if different:
                        await click_point(client, different)
                    else:
                        assert s["checkout"]["enabled"], "uniform batch should be settleable"
                        await click_point(client, s["checkout"])
                await asyncio.sleep(0.38)
            assert mixed is not None, "could not prepare mixed scale with real clicks"
            assert not mixed["checkout"]["enabled"], "mixed POS must be disabled"
            assert mixed["combo"]["value"] == 2 and mixed["combo"]["text"] == "COMBO ×2", mixed["combo"]
            assert mixed["combo"]["pulse_seq"] >= 1 and mixed["combo"]["peak_scale"] > 1.01, "top combo pulse was not sampled"
            assert abs(mixed["combo"]["scale"] - 1.0) < 0.01, "combo pulse did not return to normal scale"
            await client.shot(os.path.join(out_dir, "web_mixed.png"))

            groups_before = mixed["bagged_groups"]
            await click_point(client, mixed["checkout"])
            await asyncio.sleep(0.3)
            rejected = await snapshot(client)
            assert rejected["bagged_groups"] == groups_before and len(rejected["tray"]) == 2, "disabled POS settled mixed items"

            returned = rejected["tray"][-1]
            remaining_before = rejected["remaining"]
            await click_point(client, returned)
            returned_state = await wait_snapshot(client, lambda s: s.get("page") == "game" and s["remaining"] == remaining_before + 1 and len(s["tray"]) == 1, 5)
            assert len({e["snack"] for e in returned_state["tray"]}) == 1
            assert returned_state["combo"]["value"] == 0 and returned_state["combo"]["text"] == "COMBO —", "return must clear visible combo"
            await asyncio.sleep(0.25)
            await client.shot(os.path.join(out_dir, "web_return.png"))

            items_before = returned_state["bagged_items"]
            assert returned_state["checkout"]["enabled"], "single uniform item should be settleable"
            await click_point(client, returned_state["checkout"])
            weighed = await wait_snapshot(client, lambda s: s.get("page") == "game" and s["bagged_items"] == items_before + 1 and not s["tray"], 5)
            assert weighed["progress"]["value"] == weighed["bagged_items"] / weighed["total_items"]
            assert weighed["progress"]["text"] == "已称重 %d / %d 件 · %d 批" % (weighed["bagged_items"], weighed["total_items"], weighed["bagged_groups"])
            await asyncio.sleep(0.12)
            await client.shot(os.path.join(out_dir, "web_weigh.png"))

            # 继续真实点击直到完成整关。策略不凑三：无同款可拿就结算当前批次。
            next_customer_shot = False
            swap_input_locked = False
            swap_completed = False
            last_game = weighed
            for guard in range(100):
                s = await snapshot(client)
                if s["page"] != "game" or s.get("state") != "playing":
                    last_game = s
                    break
                last_game = s
                if s["customer"] == 2 and not next_customer_shot:
                    next_customer_shot = True
                    assert s["switching"], "customer 2 should begin with basket swap animation"
                    assert s["customer_id"] != first_customer_id, "next customer must be a different character"
                    assert s["customer_discovered"], "next customer must unlock on arrival"
                    if s["available"]:
                        remaining_before_swap_click = s["remaining"]
                        await click_point(client, s["available"][0])
                        locked = await snapshot(client)
                        swap_input_locked = locked["switching"] and locked["remaining"] == remaining_before_swap_click and not locked["tray"]
                    await client.shot(os.path.join(out_dir, "web_next_customer.png"), 0.0)
                if s.get("switching"):
                    await asyncio.sleep(0.12)
                    continue
                if s["customer"] == 2:
                    swap_completed = not s["basket_present"] and s["live_basket_count"] == 0
                    assert s["queue_ids"] == [], "last customer should show no upcoming queue"
                    assert_layout(s)
                if any(e["flying"] for e in s["tray"]):
                    await asyncio.sleep(0.12)
                    continue
                if s["remaining"] == 0:
                    assert s["tray"] and s["checkout"]["enabled"], "empty basket must settle pending scale"
                    await click_point(client, s["checkout"])
                elif s["tray"]:
                    current = s["tray"][0]["snack"]
                    same = next((a for a in s["available"] if a["snack"] == current and a["size"] <= s["free_slots"]), None)
                    if same:
                        await click_point(client, same)
                    else:
                        assert s["checkout"]["enabled"], "auto strategy unexpectedly mixed scale"
                        await click_point(client, s["checkout"])
                else:
                    assert s["available"], "nonempty basket has no exposed item"
                    await click_point(client, s["available"][0])
                await asyncio.sleep(0.36)
            else:
                raise AssertionError("web auto play exceeded action guard")

            assert next_customer_shot, "queue never advanced to customer 2"
            assert swap_input_locked, "real browser click was not locked during basket swap"
            assert swap_completed, "basket swap never released input"
            result = await wait_snapshot(client, lambda s: s.get("page") == "result", 12)
            assert result["page"] == "result"
            assert last_game.get("state") == "complete" and last_game.get("bagged_items") == 8, last_game
            await asyncio.sleep(0.4)
            await client.shot(os.path.join(out_dir, "web_result.png"))

            assert result.get("next"), "level 1 result has no next-level button"
            await click_point(client, result["next"])
            bulk = await wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("level") == 2 and not s.get("switching"), 15)
            assert bulk["customers"] == 3 and bulk["customer"] == 1
            assert bulk["remaining"] == 100 and bulk["total_items"] == 300
            assert bulk["led"] == "0 g" and bulk["tray_weight"] == 0
            assert not bulk["basket_present"] and bulk["live_basket_count"] == 0
            assert_layout(bulk)
            safe = bulk["layout"]["table_safe"]
            assert all(item["parent_table"] and not item["flying"] for item in bulk["table_items"]), "poured items are not ready"
            assert all(safe["x"] - 1 <= corner["x"] <= safe["x"] + safe["w"] + 1 and safe["y"] - 1 <= corner["y"] <= safe["y"] + safe["h"] + 1
                       for item in bulk["table_items"] for corner in item["corners"]), "snack corners escaped enlarged table"
            await asyncio.sleep(0.5)
            await client.shot(os.path.join(out_dir, "web_bulk_level2.png"))

            # 真实浏览器拖动：只整理桌面，不进入称重台。
            drag_item = bulk["available"][0]
            drag_origin = (drag_item["table_x"], drag_item["table_y"])
            drag_end = {"x": max(safe["x"] + 55, drag_item["x"] - 85),
                        "y": min(safe["y"] + safe["h"] - 60, drag_item["y"] + 160)}
            await client.drag(drag_item, drag_end)
            await asyncio.sleep(0.25)
            dragged = await snapshot(client)
            moved = next(a for a in dragged["available"] if a["uid"] == drag_item["uid"])
            assert dragged["drag_uid"] == -1 and not dragged["tray"] and dragged["remaining"] == 100
            assert (moved["table_x"] - drag_origin[0]) ** 2 + (moved["table_y"] - drag_origin[1]) ** 2 > 400
            await client.shot(os.path.join(out_dir, "web_table_drag.png"))

            # 真实双击：第一次入一件，第二击聚合中心半径 220 内的露出同款。
            double_target = None
            for candidate in dragged["available"]:
                nearby = [a for a in dragged["available"]
                          if a["snack"] == candidate["snack"]
                          and (a["table_x"] - candidate["table_x"]) ** 2 + (a["table_y"] - candidate["table_y"]) ** 2 <= 220 ** 2]
                if len(nearby) >= 2:
                    double_target = candidate
                    break
            assert double_target is not None, "no nearby same-snack pair for browser double-click"
            await client.double_click(double_target)
            gathered = await wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("last_double_count", 0) >= 2 and len(s.get("tray", [])) >= 2, 5)
            assert len({e["snack"] for e in gathered["tray"]}) == 1 and gathered["bagged_items"] == 0
            assert gathered["tray_weight"] > 0 and gathered["led"] == "%d g" % gathered["tray_weight"]
            await asyncio.sleep(0.65)
            await client.shot(os.path.join(out_dir, "web_double_gather.png"))
            for _ in range(20):
                current = await snapshot(client)
                if not current["tray"]:
                    break
                if any(e["flying"] for e in current["tray"]):
                    await asyncio.sleep(0.15)
                    continue
                before_return = len(current["tray"])
                await click_point(client, current["tray"][-1])
                await wait_snapshot(client, lambda s, n=before_return: s.get("page") == "game" and len(s.get("tray", [])) == n - 1, 5)
                await asyncio.sleep(0.28)
            bulk = await wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("level") == 2 and s.get("remaining") == 100 and not s.get("tray"), 5)

            chosen = max(bulk["available"], key=lambda a: a["y"])  # 专测扩大后最靠桌边的露出物品
            assert chosen["y"] > 850, "fixture did not find an expanded lower-table snack"
            await click_point(client, chosen)
            live = await wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("remaining") == 99 and len(s.get("tray", [])) == 1, 5)
            assert live["tray_weight"] == chosen["weight"], (live["tray_weight"], chosen)
            assert live["led"] == "%d g" % chosen["weight"], live["led"]
            await client.shot(os.path.join(out_dir, "web_bulk_live_weight.png"))
            await asyncio.sleep(0.35)
            live = await snapshot(client)
            await click_point(client, live["tray"][-1])
            returned_bulk = await wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("remaining") == 100 and not s.get("tray"), 5)
            assert returned_bulk["tray_weight"] == 0 and returned_bulk["led"] == "0 g"
            print("web flow: top HUD/combo, released basket, integrated POS/platform, level 1 + swap, level 2 expanded-table input ok")
            ok = True
    except Exception as exc:
        print("WEB SMOKE FAILED:", repr(exc))
        try:
            diagnostic = await client.call("Runtime.evaluate", {
                "expression": "JSON.stringify({href:location.href,bridge:typeof window.godotSmokeState,state:window.godotSmokeState || '',canvas:!!document.querySelector('canvas')})",
                "returnByValue": True,
            })
            print("browser diagnostic:", diagnostic.get("result", {}).get("value"))
            print("last snapshot:", await snapshot(client))
            await client.shot(os.path.join(out_dir, "web_failure.png"))
        except Exception:
            pass
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    errors = [m for m in console_logs if "error" in m.lower() or "exception" in m.lower()]
    print("console messages:", len(console_logs), "errors:", len(errors))
    for line in console_logs[-12:]:
        print(line[:500])
    return 0 if ok and not errors else 1


async def snapshot(client):
    result = await client.call("Runtime.evaluate", {
        "expression": "window.godotSmokeState || ''",
        "returnByValue": True,
    })
    value = result.get("result", {}).get("value", "")
    return json.loads(value) if value else {"page": "loading"}


async def wait_snapshot(client, predicate, timeout):
    deadline = time.monotonic() + timeout
    last = {"page": "loading"}
    while time.monotonic() < deadline:
        last = await snapshot(client)
        if predicate(last):
            return last
        await asyncio.sleep(0.2)
    raise AssertionError("snapshot wait timed out: %s" % last)


def assert_layout(s):
    layout = s["layout"]
    assert abs(layout["pos"]["x"] - 480) < 0.1 and abs(layout["pos"]["y"] - 138) < 0.1, layout["pos"]
    assert abs(layout["scale"]["x"] - 452) < 0.1 and abs(layout["scale"]["y"] - 282) < 0.1, layout["scale"]
    assert abs(layout["pos"]["x"] + layout["pos"]["w"] * 0.5 - layout["scale"]["x"] - layout["scale"]["w"] * 0.5) < 0.1, "POS and scale must be coaxial"
    gap = layout["scale"]["y"] - layout["pos"]["y"] - layout["pos"]["h"]
    assert 0 <= gap <= 16 and layout["stand"]["y"] <= layout["pos"]["y"] + layout["pos"]["h"] and layout["stand"]["y"] + layout["stand"]["h"] >= layout["scale"]["y"], "integrated stand must bridge POS and scale"
    assert abs(layout["queue"]["x"] - 190) < 0.1 and abs(layout["queue"]["y"] - 250) < 0.1, layout["queue"]
    assert abs(layout["cashier"]["x"]) < 0.1 and abs(layout["cashier"]["y"] - 1024) < 0.1, layout["cashier"]
    assert abs(layout["cashier"]["w"] - 720) < 0.1 and abs(layout["cashier"]["h"] - 256) < 0.1, layout["cashier"]
    assert abs(layout["counter"]["y"] + layout["counter"]["h"] - 1024) < 0.1, layout["counter"]
    assert layout["aisle"] == layout["cashier"], "visual aisle must match the reserved cashier area"
    assert layout["table_safe"]["w"] >= 420 and 540 <= layout["table_safe"]["h"] <= 590, layout["table_safe"]
    assert abs(layout["table_safe"]["y"] + layout["table_safe"]["h"] - 1024) < 0.1, layout["table_safe"]
    assert abs(s["cashier"]["x"] - 360) < 0.1 and layout["cashier"]["y"] <= s["cashier"]["y"] <= 1280, s["cashier"]
    assert s["progress"]["rect"]["y"] < 100 and s["progress"]["bag"]["y"] < 100, s["progress"]
    assert s["combo"]["rect"]["x"] > 500 and s["combo"]["rect"]["y"] < 60, s["combo"]
    assert s["tools"] == [], "legacy magnet/slot/freeze controls remain: %s" % s["tools"]


async def click_point(client, point):
    await client.click(float(point["x"]), float(point["y"]))


async def wait_target() -> str:
    endpoint = "http://localhost:%d/json/list" % PORT
    for _ in range(60):
        try:
            with urllib.request.urlopen(endpoint, timeout=1) as resp:
                targets = json.load(resp)
            for t in targets:
                if t.get("type") == "page":
                    return t["webSocketDebuggerUrl"]
        except Exception:
            pass
        await asyncio.sleep(0.5)
    raise RuntimeError("Chrome DevTools target not ready")


class CDP:
    def __init__(self, ws):
        self.ws = ws
        self.next_id = 0

    async def call(self, method, params=None):
        self.next_id += 1
        mid = self.next_id
        await self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        while True:
            msg = json.loads(await self.ws.recv())
            self._event(msg)
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError("%s: %s" % (method, msg["error"]))
                return msg.get("result", {})

    def _event(self, msg):
        method = msg.get("method", "")
        if method == "Runtime.consoleAPICalled":
            args = msg["params"].get("args", [])
            text = " ".join(str(a.get("value", a.get("description", ""))) for a in args)
            console_logs.append("console.%s: %s" % (msg["params"].get("type"), text))
        elif method == "Runtime.exceptionThrown":
            console_logs.append("exception: " + json.dumps(msg["params"], ensure_ascii=False))

    async def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                msg = json.loads(await asyncio.wait_for(self.ws.recv(), timeout=max(0.05, deadline - time.monotonic())))
                self._event(msg)
            except asyncio.TimeoutError:
                break

    async def click(self, x, y, click_count=1):
        # 入参为 720x1280 逻辑坐标；固定比例缩放后，X/Y 共用 scale 和居中留边偏移。
        rect = await self.call("Runtime.evaluate", {
            "expression": "JSON.stringify(document.querySelector('canvas').getBoundingClientRect())",
            "returnByValue": True,
        })
        box = json.loads(rect["result"]["value"])
        scale = min(box["width"] / 720.0, box["height"] / 1280.0)
        origin_x = box["x"] + (box["width"] - 720.0 * scale) * 0.5
        origin_y = box["y"] + (box["height"] - 1280.0 * scale) * 0.5
        cx = origin_x + x * scale
        cy = origin_y + y * scale
        print("click logical", (round(x, 1), round(y, 1)), "css", (round(cx, 1), round(cy, 1)))
        await self.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": cx, "y": cy, "button": "none"})
        await self.call("Input.dispatchMouseEvent", {"type": "mousePressed", "x": cx, "y": cy, "button": "left", "clickCount": click_count})
        await asyncio.sleep(0.08)
        await self.call("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": cx, "y": cy, "button": "left", "clickCount": click_count})

    async def double_click(self, point):
        rect = await self.call("Runtime.evaluate", {
            "expression": "JSON.stringify(document.querySelector('canvas').getBoundingClientRect())",
            "returnByValue": True,
        })
        box = json.loads(rect["result"]["value"])
        scale = min(box["width"] / 720.0, box["height"] / 1280.0)
        x = box["x"] + (box["width"] - 720.0 * scale) * 0.5 + float(point["x"]) * scale
        y = box["y"] + (box["height"] - 1280.0 * scale) * 0.5 + float(point["y"]) * scale
        await self.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y, "button": "none"})
        for count in [1, 2]:
            await self.call("Input.dispatchMouseEvent", {"type": "mousePressed", "x": x, "y": y, "button": "left", "buttons": 1, "clickCount": count})
            await asyncio.sleep(0.025)
            await self.call("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": x, "y": y, "button": "left", "buttons": 0, "clickCount": count})
            await asyncio.sleep(0.035)

    async def drag(self, start, end):
        rect = await self.call("Runtime.evaluate", {
            "expression": "JSON.stringify(document.querySelector('canvas').getBoundingClientRect())",
            "returnByValue": True,
        })
        box = json.loads(rect["result"]["value"])
        scale = min(box["width"] / 720.0, box["height"] / 1280.0)
        origin_x = box["x"] + (box["width"] - 720.0 * scale) * 0.5
        origin_y = box["y"] + (box["height"] - 1280.0 * scale) * 0.5
        sx = origin_x + float(start["x"]) * scale
        sy = origin_y + float(start["y"]) * scale
        ex = origin_x + float(end["x"]) * scale
        ey = origin_y + float(end["y"]) * scale
        await self.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": sx, "y": sy, "button": "none"})
        await self.call("Input.dispatchMouseEvent", {"type": "mousePressed", "x": sx, "y": sy, "button": "left", "buttons": 1, "clickCount": 1})
        for i in range(1, 9):
            x = sx + (ex - sx) * i / 8.0
            y = sy + (ey - sy) * i / 8.0
            await self.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": x, "y": y, "button": "left", "buttons": 1})
            await asyncio.sleep(0.025)
        await self.call("Input.dispatchMouseEvent", {"type": "mouseReleased", "x": ex, "y": ey, "button": "left", "buttons": 0, "clickCount": 1})

    async def shot(self, path, drain_seconds=0.3):
        await self.drain(drain_seconds)
        result = await self.call("Page.captureScreenshot", {"format": "png"})
        with open(path, "wb") as f:
            f.write(base64.b64decode(result["data"]))
        print("shot", path)


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
