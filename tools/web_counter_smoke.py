#!/usr/bin/env python3
"""本轮 Web 聚焦检查：固定篮口撒落、四区拖放/退回及集齐自动称重。

不运行完整 web_smoke，不调用任何游戏状态修改接口。
用法：python3 -I tools/web_counter_smoke.py [url] [out_dir]
"""
import asyncio
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import traceback
import urllib.parse

import websockets

_spec = importlib.util.spec_from_file_location("web_smoke_support", Path(__file__).with_name("web_smoke.py"))
web = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(web)


async def wait_phase(client, phase, condition="true", timeout=6):
    """按只读历史游标观察短阶段；低帧率跨过阶段时也不丢失当时快照。"""
    expression = """
new Promise((resolve, reject) => {
    const wanted = %s;
    const extra = (s) => %s;
    const deadline = performance.now() + %d;
    const timer = setInterval(() => {
        const history = Array.isArray(window.godotSmokeHistory) ? window.godotSmokeHistory.slice() : [];
        const current = window.godotSmokeState || '';
        if (!history.length || history[history.length - 1] !== current) history.push(current);
        let cursor = Math.min(window.__counterSmokeCursor || 0, Math.max(0, history.length - 1));
        for (; cursor < history.length; cursor += 1) {
            let s = {};
            try { s = JSON.parse(history[cursor] || '{}'); } catch (e) { continue; }
            if (s.basket_phase === wanted && extra(s)) {
                window.__counterSmokeCursor = cursor + 1;
                clearInterval(timer);
                resolve(JSON.stringify(s));
                return;
            }
        }
        if (performance.now() >= deadline) {
            clearInterval(timer);
            let s = {};
            try { s = JSON.parse(current || '{}'); } catch (e) {}
            reject(new Error('phase wait timed out: ' + JSON.stringify({wanted, phase:s.basket_phase, tilt:s.basket_tilt, switching:s.switching})));
        }
    }, 8);
})
""" % (json.dumps(phase), condition, int(timeout * 1000))
    result = await client.call("Runtime.evaluate", {
        "expression": expression,
        "awaitPromise": True,
        "returnByValue": True,
    })
    if "exceptionDetails" in result:
        error = result["exceptionDetails"].get("exception", {})
        raise AssertionError(error.get("description", result["exceptionDetails"]))
    return json.loads(result["result"]["value"])


def assert_fixed_pose(snapshot):
    """真实节点始终保持固定 90°，不是播放一次翻转动画。"""
    assert abs(snapshot["basket_view_rotation"]) < 0.01
    rotation = snapshot["basket_root_rotation"]
    assert abs(rotation["x"]) < 0.01 and abs(rotation["z"]) < 0.01
    assert abs(rotation["y"] - math.pi / 2) < 0.01, rotation


async def main() -> int:
    web.console_logs.clear()
    web.PORT = 9223
    url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8765/"
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "docs/images"
    parts = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qs(parts.query)
    query["smoke"] = ["1"]
    query.setdefault("seed", ["42"])
    url = urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query, doseq=True)))
    os.makedirs(out_dir, exist_ok=True)
    profile = "/tmp/godot_web_counter_smoke_profile"
    shutil.rmtree(profile, ignore_errors=True)
    proc = subprocess.Popen([
        web.CHROME, "--headless=new", "--no-sandbox", "--use-angle=swiftshader",
        "--enable-unsafe-swiftshader", "--window-size=720,1280",
        "--remote-debugging-port=%d" % web.PORT, "--user-data-dir=" + profile,
        "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = False
    try:
        ws_url = await web.wait_target()
        async with websockets.connect(ws_url, max_size=None) as ws:
            client = web.CDP(ws)
            await client.call("Runtime.enable")
            await client.call("Page.enable")
            await client.call("Page.navigate", {"url": url})
            print("loading", url)
            await web.wait_snapshot(client, lambda s: s.get("page") == "home", 30)
            await client.click(360, 398)

            lift = await wait_phase(client, "lift", timeout=8)
            assert lift["switching"] and lift["cashier"]["action_seq"] > 0
            assert all(not item["parent_table"] for item in lift["table_items"]), "snacks detached during lift"
            assert_fixed_pose(lift)

            pour = await wait_phase(client, "pour", "s.table_items.some(item => item.parent_table)")
            assert pour["pouring"], "snacks must spill without animating the basket angle"
            assert_fixed_pose(pour)
            mouth = pour["basket_mouth"]
            origin = pour["spill_origin"]
            assert math.isfinite(mouth["x"]) and math.isfinite(mouth["y"]), "3D camera must project a finite basket mouth"
            assert math.isfinite(origin["x"]) and math.isfinite(origin["y"]), "snack must have a finite release origin"
            assert math.hypot(origin["x"] - mouth["x"], origin["y"] - mouth["y"]) < 100, "snack did not start inside the basket mouth"
            safe = pour["layout"]["table_safe"]
            assert safe["x"] - 45 <= mouth["x"] <= safe["x"] + safe["w"] / 2
            assert safe["y"] - 45 <= mouth["y"] <= safe["y"] + safe["h"] + 45

            leave = await wait_phase(client, "leave", timeout=8)
            assert leave["switching"] and leave["basket_present"]
            assert all(item["parent_table"] and not item["flying"] for item in leave["table_items"]), "basket left before every snack landed"
            assert_fixed_pose(leave)
            game = await wait_phase(client, "done", "!s.switching")
            assert not game["basket_present"] and game["live_basket_count"] == 0
            assert game["level"] == 1 and game["remaining"] == 4 and not game["tray"]
            assert all(item["parent_table"] and not item["flying"] and abs(item["global_scale"] - 0.78) < 0.01 for item in game["table_items"]), "Web snacks did not restore standard table scale"
            web.assert_layout(game)
            assert len(game["zones"]) == 4
            safe = game["layout"]["table_safe"]
            for zone in game["zones"]:
                rect = zone["rect"]
                assert safe["x"] <= rect["x"] and safe["y"] <= rect["y"]
                assert rect["x"] + rect["w"] <= safe["x"] + safe["w"] + 0.1
                assert rect["y"] + rect["h"] <= safe["y"] + safe["h"] + 0.1
            await client.shot(os.path.join(out_dir, "web_counter_ready.png"))

            idle_samples = []
            for _ in range(6):
                idle_samples.append((await web.snapshot(client))["cashier"]["idle_y"])
                await asyncio.sleep(0.12)
            assert max(idle_samples) - min(idle_samples) > 0.05, idle_samples

            target = game["available"][0]
            snack_id = target["snack"]
            action_before = game["cashier"]["action_seq"]
            await web.click_point(client, target)
            tapped = await web.wait_snapshot(client, lambda s: s.get("table_tap", {}).get("uid") == target["uid"] and s.get("table_tap", {}).get("seq", 0) >= 1, 5)
            assert tapped["remaining"] == 4 and not tapped["tray"]
            assert all(zone["count"] == 0 for zone in tapped["zones"])
            assert tapped["cashier"]["action_seq"] == action_before and not tapped["checkout"]["enabled"]
            await asyncio.sleep(0.3)

            async def drag_next_kind():
                current = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and any(a["snack"] == snack_id for a in s.get("available", [])), 5)
                available = next(a for a in current["available"] if a["snack"] == snack_id)
                rect = current["zones"][0]["rect"]
                await client.drag(available, {"x": rect["x"] + rect["w"] * 0.5, "y": rect["y"] + rect["h"] * 0.5})
                return available["uid"]

            action_before = tapped["cashier"]["action_seq"]
            await drag_next_kind()
            zoned = await web.wait_snapshot(client, lambda s: s.get("zones", [{ "count": 0 }])[0]["count"] == 1 and not s["zones"][0]["items"][0]["flying"], 5)
            assert zoned["remaining"] == 3 and zoned["bagged_items"] == 0 and not zoned["zone_queue"]
            assert zoned["cashier"]["action_seq"] > action_before
            await client.shot(os.path.join(out_dir, "web_counter_zone.png"))

            await web.click_point(client, zoned["zones"][0]["items"][0])
            returned = await web.wait_snapshot(client, lambda s: s.get("remaining") == 4 and s.get("zones", [{ "count": -1 }])[0]["count"] == 0, 5)
            assert not returned["tray"] and returned["bagged_items"] == 0
            await asyncio.sleep(0.3)

            await drag_next_kind()
            await web.wait_snapshot(client, lambda s: s.get("zones", [{ "count": 0 }])[0]["count"] == 1 and not s["zones"][0]["items"][0]["flying"], 5)
            await drag_next_kind()
            queued = await web.wait_snapshot(client, lambda s: s.get("zone_active") == 0 or s.get("zone_queue") == [0] or s.get("bagged_items") == 2, 5)
            assert not queued["checkout"]["enabled"]
            if queued["bagged_items"] == 0:
                await web.click_point(client, queued["checkout"])
                assert (await web.snapshot(client))["bagged_items"] == 0
            weighed = await web.wait_snapshot(client, lambda s: s.get("bagged_items") == 2 and not s.get("tray"), 5)
            assert weighed["bagged_groups"] == 1 and weighed["remaining"] == 2
            assert weighed["zone_active"] == -1 and weighed["zone_queue"] == []
            assert all(zone["count"] == 0 for zone in weighed["zones"])
            assert weighed["progress"]["value"] == weighed["bagged_items"] / weighed["total_items"]
            await client.shot(os.path.join(out_dir, "web_counter_checkout.png"))
            print("web counter smoke: fixed basket, four zones, table hop, real drag/return and automatic whole-kind weighing ok")
            ok = True
    except Exception as exc:
        print("WEB COUNTER SMOKE FAILED:", repr(exc))
        traceback.print_exc()
        try:
            print("last snapshot:", await web.snapshot(client))
            await client.shot(os.path.join(out_dir, "web_counter_failure.png"))
        except Exception:
            pass
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    errors = [m for m in web.console_logs if "error" in m.lower() or "exception" in m.lower()]
    print("console messages:", len(web.console_logs), "errors:", len(errors))
    for line in web.console_logs[-8:]:
        print(line[:500])
    return 0 if ok and not errors else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
