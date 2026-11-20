#!/usr/bin/env python3
"""Godot Web 聚焦检查：自由聚堆、异款阻断、双批连续称重与第 2 关进度。

全部游戏操作均为 Chrome DevTools Protocol 真鼠标事件；只读桥不提供状态修改接口。
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
import time
import traceback
import urllib.parse

import websockets

_spec = importlib.util.spec_from_file_location("web_smoke_support", Path(__file__).with_name("web_smoke.py"))
web = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(web)


async def wait_phase(client, phase, condition="true", timeout=6):
    """从只读历史观察短阶段，低帧率跨过阶段时也不丢失。"""
    expression = """
new Promise((resolve, reject) => {
    const wanted = %s;
    const extra = (s) => %s;
    const deadline = performance.now() + %d;
    const timer = setInterval(() => {
        const history = Array.isArray(window.godotSmokeHistory) ? window.godotSmokeHistory.slice() : [];
        const current = window.godotSmokeState || '';
        if (!history.length || history[history.length - 1] !== current) history.push(current);
        for (let cursor = 0; cursor < history.length; cursor += 1) {
            let s = {};
            try { s = JSON.parse(history[cursor] || '{}'); } catch (e) { continue; }
            if (s.basket_phase === wanted && extra(s)) {
                clearInterval(timer);
                resolve(JSON.stringify(s));
                return;
            }
        }
        if (performance.now() >= deadline) {
            clearInterval(timer);
            reject(new Error('phase wait timed out: ' + wanted));
        }
    }, 8);
})
""" % (json.dumps(phase), condition, int(timeout * 1000))
    result = await client.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True})
    if "exceptionDetails" in result:
        raise AssertionError(result["exceptionDetails"])
    return json.loads(result["result"]["value"])


async def history(client):
    result = await client.call("Runtime.evaluate", {
        "expression": "window.godotSmokeHistory || []",
        "returnByValue": True,
    })
    rows = []
    for raw in result.get("result", {}).get("value", []):
        try:
            rows.append(json.loads(raw))
        except (TypeError, json.JSONDecodeError):
            pass
    current = await web.snapshot(client)
    if current:
        rows.append(current)
    return rows


async def wait_history(client, predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for snapshot in await history(client):
            if predicate(snapshot):
                return snapshot
        await asyncio.sleep(0.05)
    raise AssertionError("event history wait timed out: %s" % (await web.snapshot(client)))


def assert_fixed_pose(snapshot):
    assert abs(snapshot["basket_view_rotation"]) < 0.01
    rotation = snapshot["basket_root_rotation"]
    assert abs(rotation["x"]) < 0.01 and abs(rotation["z"]) < 0.01
    assert abs(rotation["y"] - math.pi / 2) < 0.01, rotation


def local_point(snapshot, point):
    safe = snapshot["layout"]["table_safe"]
    scale = safe["w"] / 552.0
    return {
        "x": safe["x"] - 24.0 * scale + point[0] * scale,
        "y": safe["y"] - 60.0 * scale + point[1] * scale,
    }


def by_kind(snapshot):
    groups = {}
    for item in snapshot.get("table_items", []):
        groups.setdefault(item["snack"], []).append(item)
    for items in groups.values():
        items.sort(key=lambda item: item["uid"])
    return groups


async def drag_to(client, uid, target, customer):
    """把包装中心拖到逻辑桌面 target，并补偿真实露出点击点的抓取偏移。"""
    snapshot = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and not s.get("switching"), 8)
    if snapshot["customer"] != customer:
        return snapshot
    available = next((item for item in snapshot["available"] if item["uid"] == uid), None)
    if available is None:
        raise AssertionError("uid %d is not exposed; snapshot=%s" % (uid, snapshot))
    node = next(item for item in snapshot["table_items"] if item["uid"] == uid)
    end = local_point(snapshot, target)
    end["x"] += available["x"] - node["x"]
    end["y"] += available["y"] - node["y"]
    await client.drag(available, end)

    def arrived(s):
        if s.get("page") != "game" or s.get("customer") != customer:
            return True
        moved = next((item for item in s.get("table_items", []) if item["uid"] == uid), None)
        if moved is None:
            return True
        return math.hypot(moved["table_x"] - target[0], moved["table_y"] - target[1]) < 2.0

    return await web.wait_snapshot(client, arrived, 5)


async def sample_frames(client, count=60):
    result = await client.call("Runtime.evaluate", {
        "expression": """
new Promise((resolve) => {
    const samples = [];
    let previous = 0;
    function frame(now) {
        if (previous) samples.push(now - previous);
        previous = now;
        if (samples.length < %d) requestAnimationFrame(frame);
        else {
            const sorted = samples.slice().sort((a,b) => a-b);
            const elapsed = samples.reduce((a,b) => a+b, 0);
            resolve({frames:samples.length, elapsed_ms:elapsed,
                fps:1000 * samples.length / elapsed,
                p95_ms:sorted[Math.floor((sorted.length - 1) * 0.95)],
                max_ms:Math.max.apply(null, samples)});
        }
    }
    requestAnimationFrame(frame);
})
""" % count,
        "awaitPromise": True,
        "returnByValue": True,
    })
    return result["result"]["value"]


async def perform_handoff(client, customer, out_dir, tag):
    """先以 A1 阻断 B，再拖 A1 与 A2 聚堆；同一次松手应同时释放 A/B 两批。"""
    game = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer and not s.get("switching"), 12)
    groups = by_kind(game)
    assert len(groups) == 2 and all(len(items) == 2 for items in groups.values()), groups
    ordered = sorted(groups.values(), key=lambda items: items[0]["uid"])
    a, b = ordered
    a1, a2 = a[0]["uid"], a[1]["uid"]
    b1, b2 = b[0]["uid"], b[1]["uid"]
    other = next(item for item in game["table_items"] if item["uid"] == a1)
    a2_target = (250.0, 700.0) if math.hypot(other["table_x"] - 100.0, other["table_y"] - 700.0) < 170 else (100.0, 700.0)
    final_a1 = (a2_target[0] + 120.0, a2_target[1])

    await drag_to(client, a2, a2_target, customer)
    await drag_to(client, a1, (450.0, 500.0), customer)
    await drag_to(client, b1, (450.0, 400.0), customer)
    blocked = await drag_to(client, b2, (550.0, 400.0), customer)
    assert blocked["customer"] == customer and blocked["remaining"] == 4 and blocked["bagged_items"] % 4 == 0, blocked
    assert not blocked["active_batch"] and not blocked["batch_queue"], blocked
    await client.shot(os.path.join(out_dir, "web_%s_blocked.png" % tag), 0.0)

    before = await web.snapshot(client)
    serial_before = before["batch_serial"]
    bagged_before = before["bagged_items"]
    await drag_to(client, a1, final_a1, customer)
    queued = await wait_history(client, lambda s: s.get("customer") == customer and s.get("batch_serial", 0) > serial_before and len(s.get("batch_queue", [])) >= 1, 4)
    assert queued["active_batch"] and queued["batch_phase"] == "flying", queued
    await client.shot(os.path.join(out_dir, "web_%s_queued.png" % tag), 0.0)
    done = await web.wait_snapshot(client, lambda s: s.get("page") != "game" or s.get("bagged_items", 0) >= bagged_before + 4, 10)
    rows = await history(client)
    assert any(s.get("customer") == customer and s.get("active_batch") and s.get("price_tags", 0) >= 1 for s in rows), "next batch did not overlap previous price tag"
    assert any(s.get("customer") == customer and s.get("price_tags", 0) >= 2 for s in rows), "independent price tags did not coexist"
    return done


async def solve_three_pairs(client, customer):
    """第 2 关只通一位顾客：把所有款拖到彼此分离的自由聚堆位置。"""
    game = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer and not s.get("switching"), 12)
    groups = by_kind(game)
    assert len(groups) == 3 and all(len(items) == 2 for items in groups.values()), groups
    origins = [(100.0, 680.0), (400.0, 400.0), (680.0, 680.0)]
    pending = {}
    for index, items in enumerate(sorted(groups.values(), key=lambda value: value[0]["uid"])):
        for member, item in enumerate(items):
            pending[item["uid"]] = (origins[index][0] + member * 110.0, origins[index][1])
    for _round in range(12):
        if not pending:
            break
        snapshot = await web.snapshot(client)
        if snapshot.get("page") != "game" or snapshot.get("customer") != customer:
            break
        present = {item["uid"] for item in snapshot.get("table_items", [])}
        for uid in list(pending):
            if uid not in present:
                pending.pop(uid)
        exposed = {item["uid"] for item in snapshot.get("available", [])}
        uid = next((uid for uid in pending if uid in exposed), None)
        if uid is None:
            if pending:
                await asyncio.sleep(0.12)
            continue
        target = pending.pop(uid)
        await drag_to(client, uid, target, customer)
    assert not pending, "covered snacks remained after repeated real-drag passes: %s" % pending
    return await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer + 1 and s.get("bagged_items") == 6 and not s.get("switching"), 12)


async def main() -> int:
    web.console_logs.clear()
    web.PORT = 9223
    url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8766/"
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
    client = None
    try:
        ws_url = await web.wait_target()
        async with websockets.connect(ws_url, max_size=None) as ws:
            client = web.CDP(ws)
            await client.call("Runtime.enable")
            await client.call("Page.enable")
            navigation = await client.call("Page.navigate", {"url": url})
            if navigation.get("errorText"):
                raise AssertionError("page navigation failed: %s" % navigation)
            print("loading", url)
            await web.wait_snapshot(client, lambda s: s.get("page") == "home", 30)
            await client.click(360, 398)

            lift = await wait_phase(client, "lift", timeout=8)
            assert lift["switching"] and lift["cashier"]["action_seq"] > 0
            assert all(not item["parent_table"] for item in lift["table_items"])
            assert_fixed_pose(lift)
            pour = await wait_phase(client, "pour", "s.table_items.some(item => item.parent_table)")
            assert pour["pouring"]
            assert_fixed_pose(pour)
            mouth, origin = pour["basket_mouth"], pour["spill_origin"]
            assert math.isfinite(mouth["x"]) and math.isfinite(origin["x"])
            assert math.hypot(origin["x"] - mouth["x"], origin["y"] - mouth["y"]) < 100
            leave = await wait_phase(client, "leave", timeout=8)
            assert leave["switching"] and leave["basket_present"]
            assert all(item["parent_table"] and not item["flying"] for item in leave["table_items"])
            game = await wait_phase(client, "done", "!s.switching")
            assert game["level"] == 1 and game["remaining"] == 4 and game["total_items"] == 8, game
            assert not game["basket_present"] and game["live_basket_count"] == 0
            assert game["pos_mode"] == "聚堆自动称重" and "zones" not in game and "auto_settle" not in game
            assert all(item["parent_table"] and not item["flying"] for item in game["table_items"])
            web.assert_layout(game)
            await client.shot(os.path.join(out_dir, "web_counter_ready.png"))
            perf = await sample_frames(client)
            print("headless SwiftShader frame sample:", perf)

            target = game["available"][0]
            await web.click_point(client, target)
            tapped = await web.wait_snapshot(client, lambda s: s.get("table_tap", {}).get("uid") == target["uid"], 5)
            assert tapped["remaining"] == 4 and tapped["bagged_items"] == 0 and tapped["batch_serial"] == 0
            await client.double_click({"x": 690, "y": 1160})
            await asyncio.sleep(0.25)
            idle = await web.snapshot(client)
            assert idle["remaining"] == 4 and idle["bagged_items"] == 0 and idle["batch_serial"] == 0

            await perform_handoff(client, 1, out_dir, "customer1")
            switched = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == 2 and s.get("switching"), 5)
            assert switched["led_value"] > 0 and switched["price_tags"] >= 1, switched
            await client.shot(os.path.join(out_dir, "web_customer_switch_feedback.png"), 0.0)
            await perform_handoff(client, 2, out_dir, "customer2")
            result = await web.wait_snapshot(client, lambda s: s.get("page") == "result", 12)
            await web.click_point(client, result["next"])
            level_two = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("level") == 2 and not s.get("switching"), 15)
            assert level_two["customers"] == 3 and level_two["remaining"] == 6 and level_two["total_items"] == 18
            assert len(level_two["table_items"]) == 6
            progressed = await solve_three_pairs(client, 1)
            assert progressed["customer"] == 2 and progressed["remaining"] == 6 and progressed["bagged_items"] == 6
            assert progressed["bagged_groups"] == 3 and abs(progressed["progress"]["value"] - 6.0 / 18.0) < 0.0001
            await client.shot(os.path.join(out_dir, "web_level2_cluster_progress.png"))
            print("web counter smoke: real-mouse cluster blocking, simultaneous FIFO, continuous feedback and level 2 progress ok")
            ok = True
    except Exception as exc:
        print("WEB COUNTER SMOKE FAILED:", repr(exc))
        traceback.print_exc()
        if client:
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
