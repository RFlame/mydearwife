#!/usr/bin/env python3
"""Godot Web 新功能聚焦：主页测试入口、固定订单、巨大包装与自由聚堆。

所有业务操作通过 Chrome DevTools Protocol 真鼠标/键盘完成；只读桥只用于断言，
不提供或调用任何修改游戏状态的接口。用法：python3 -I tools/web_counter_smoke.py [url] [out_dir]
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


async def wait_phase(client, phase, condition="true", timeout=8):
    expression = """
new Promise((resolve, reject) => {
    const wanted = %s;
    const extra = (s) => %s;
    const deadline = performance.now() + %d;
    const timer = setInterval(() => {
        const history = Array.isArray(window.godotSmokeHistory) ? window.godotSmokeHistory.slice() : [];
        const current = window.godotSmokeState || '';
        if (!history.length || history[history.length - 1] !== current) history.push(current);
        for (const raw of history) {
            let s = {};
            try { s = JSON.parse(raw || '{}'); } catch (e) { continue; }
            if (s.basket_phase === wanted && extra(s)) {
                clearInterval(timer); resolve(JSON.stringify(s)); return;
            }
        }
        if (performance.now() >= deadline) {
            clearInterval(timer); reject(new Error('phase wait timed out: ' + wanted));
        }
    }, 8);
})
""" % (json.dumps(phase), condition, int(timeout * 1000))
    result = await client.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True})
    if "exceptionDetails" in result:
        raise AssertionError(result["exceptionDetails"])
    return json.loads(result["result"]["value"])


async def history(client):
    result = await client.call("Runtime.evaluate", {"expression": "window.godotSmokeHistory || []", "returnByValue": True})
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
    return {"x": safe["x"] - 24.0 * scale + point[0] * scale,
            "y": safe["y"] - 60.0 * scale + point[1] * scale}


def center(rect):
    return {"x": rect["x"] + rect["w"] * 0.5, "y": rect["y"] + rect["h"] * 0.5}


def by_kind(snapshot):
    groups = {}
    for item in snapshot.get("table_items", []):
        groups.setdefault(item["snack"], []).append(item)
    for items in groups.values():
        items.sort(key=lambda item: item["uid"])
    return groups


async def key(client, key, code, virtual_key):
    await client.call("Input.dispatchKeyEvent", {"type": "keyDown", "key": key, "code": code,
                                                   "windowsVirtualKeyCode": virtual_key, "nativeVirtualKeyCode": virtual_key})
    await asyncio.sleep(0.04)
    await client.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": key, "code": code,
                                                 "windowsVirtualKeyCode": virtual_key, "nativeVirtualKeyCode": virtual_key})
    await asyncio.sleep(0.06)


async def choose_option(client, option_rect, index, count, popup_y, popup_height):
    """OptionButton 的菜单是真实 Godot 弹出窗口，直接点击对应菜单项。"""
    await client.click(**center(option_rect))
    await asyncio.sleep(0.12)
    await client.click(option_rect["x"] + option_rect["w"] * 0.5,
                       popup_y + popup_height * (index + 0.5) / count)
    await asyncio.sleep(0.16)


async def set_fixed_quantity(client, test, value=2):
    if test["test_options"].get("random_quantity", True):
        await client.click(**center(test["controls"]["random"]))
        await asyncio.sleep(0.16)
    slider = test["controls"]["quantity"]
    ratio = (value - 1.0) / 19.0
    await client.click(slider["x"] + slider["w"] * ratio, slider["y"] + slider["h"] * 0.5)
    await key(client, "Home", "Home", 36)
    for _ in range(value - 1):
        await key(client, "ArrowRight", "ArrowRight", 39)
    await asyncio.sleep(0.12)


async def configure_test(client, level=2, giant=0, scale=1.5):
    test = await web.wait_snapshot(client, lambda s: s.get("page") == "test", 8)
    controls = test["controls"]
    await choose_option(client, controls["level"], level - 1, 20, 310, 568)
    test = await web.snapshot(client)
    assert test["test_options"]["level_id"] == level, test
    await choose_option(client, controls["preset"], 1, 3, 400, 92)
    await set_fixed_quantity(client, await web.snapshot(client), 2)
    size = controls["size"]
    await client.click(size["x"] + size["w"] * (scale - 1.0), size["y"] + size["h"] * 0.5)
    await asyncio.sleep(0.12)
    await choose_option(client, controls["giant"], giant, 3, 760, 92)
    test = await web.wait_snapshot(client, lambda s: s.get("page") == "test" and s["test_options"]["level_id"] == level
                                   and s["test_options"]["giant_kinds"] == giant
                                   and not s["test_options"]["random_quantity"]
                                   and s["test_options"]["fixed_quantity"] == 2
                                   and abs(s["test_options"]["package_scale"] - scale) < 0.01, 5)
    return test


async def start_test(client, test):
    expected_level = test["test_options"]["level_id"]
    scope = "s.level == %d && s.customer == 1" % expected_level
    await client.click(**center(test["start"]))
    lift = await wait_phase(client, "lift", scope, timeout=8)
    assert lift["switching"] and lift["cashier"]["action_seq"] > 0
    assert all(not item["parent_table"] for item in lift["table_items"])
    assert_fixed_pose(lift)
    pour = await wait_phase(client, "pour", scope + " && s.table_items.some(item => item.parent_table)")
    assert pour["pouring"]
    assert_fixed_pose(pour)
    mouth, origin = pour["basket_mouth"], pour["spill_origin"]
    assert math.isfinite(mouth["x"]) and math.isfinite(origin["x"])
    assert math.hypot(origin["x"] - mouth["x"], origin["y"] - mouth["y"]) < 100
    leave = await wait_phase(client, "leave", scope, timeout=8)
    assert leave["switching"] and leave["basket_present"]
    game = await wait_phase(client, "done", scope + " && !s.switching")
    assert not game["basket_present"] and game["live_basket_count"] == 0
    assert game["pos_mode"] == "聚堆自动称重" and "zones" not in game and "auto_settle" not in game
    assert all(item["parent_table"] and not item["flying"] for item in game["table_items"])
    web.assert_layout(game)
    return game


async def drag_to(client, uid, target, customer):
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
        return moved is None or math.hypot(moved["table_x"] - target[0], moved["table_y"] - target[1]) < 2.0
    return await web.wait_snapshot(client, arrived, 5)


async def perform_handoff(client, customer, out_dir, tag):
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
    game = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer and not s.get("switching"), 12)
    groups = by_kind(game)
    assert len(groups) == 3 and all(len(items) == 2 for items in groups.values()), groups
    origins = [(100.0, 680.0), (400.0, 400.0), (680.0, 680.0)]
    pending = {}
    for index, items in enumerate(sorted(groups.values(), key=lambda value: value[0]["uid"])):
        for member, item in enumerate(items):
            pending[item["uid"]] = (origins[index][0] + member * 110.0, origins[index][1])
    for _round in range(16):
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
    proc = subprocess.Popen([web.CHROME, "--headless=new", "--no-sandbox", "--use-angle=swiftshader",
        "--enable-unsafe-swiftshader", "--window-size=720,1280",
        "--remote-debugging-port=%d" % web.PORT, "--user-data-dir=" + profile, "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
            home = await web.wait_snapshot(client, lambda s: s.get("page") == "home", 30)
            save_before = home["save_summary"]
            assert home.get("test_entry"), home
            await client.shot(os.path.join(out_dir, "web_test_home.png"))
            await client.click(**center(home["test_entry"]))
            test = await configure_test(client, 1, 0)
            await client.shot(os.path.join(out_dir, "web_test_screen.png"))
            game = await start_test(client, test)
            assert game["level"] == 1 and game["remaining"] == 4 and game["total_items"] == 8, game
            assert game["test_mode"] and game["package_scale"] == 1.5 and game["giant_kinds"] == 0, game
            assert game["save_summary"] == save_before
            await client.shot(os.path.join(out_dir, "web_counter_ready.png"))

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
            assert result["test_mode"] and result["test_config"]["level_id"] == 1
            assert result["save_summary"] == save_before
            await web.click_point(client, result["next"])
            test = await configure_test(client, 2, 0)
            level_two = await start_test(client, test)
            assert level_two["customers"] == 3 and level_two["remaining"] == 6 and level_two["total_items"] == 18
            assert len(level_two["table_items"]) == 6 and level_two["save_summary"] == save_before
            progressed = await solve_three_pairs(client, 1)
            assert progressed["customer"] == 2 and progressed["remaining"] == 6 and progressed["bagged_items"] == 6
            assert progressed["bagged_groups"] == 3 and abs(progressed["progress"]["value"] - 6.0 / 18.0) < 0.0001
            await client.shot(os.path.join(out_dir, "web_level2_cluster_progress.png"))

            # 重新加载只读预览回到主页，避免依赖暂停弹窗的未公开布局坐标。
            await client.call("Page.navigate", {"url": url})
            home = await web.wait_snapshot(client, lambda s: s.get("page") == "home", 15)
            assert home["save_summary"] == save_before
            await client.click(**center(home["test_entry"]))
            test = await configure_test(client, 3, 2)
            giant_game = await start_test(client, test)
            assert giant_game["test_mode"] and giant_game["giant_kinds"] == 2
            assert 2 <= giant_game["giant_items"] <= 4
            assert giant_game["current_order_items"] == len(giant_game["table_items"])
            giant = [item for item in giant_game["table_items"] if item["giant"]]
            assert len(giant) == giant_game["giant_items"]
            assert all(item["size"] == 3 and abs(item["package_scale"] - 1.5) < 0.01 for item in giant)
            assert giant_game["save_summary"] == save_before
            await client.shot(os.path.join(out_dir, "web_test_giant_scatter.png"))
            exposed_giant = next((item for item in giant_game["available"] if item["giant"]), None)
            if exposed_giant:
                before = giant_game["table_tap"]["seq"]
                await web.click_point(client, exposed_giant)
                tapped_giant = await web.wait_snapshot(client, lambda s: s.get("table_tap", {}).get("uid") == exposed_giant["uid"], 5)
                assert tapped_giant["batch_serial"] == giant_game["batch_serial"] and tapped_giant["table_tap"]["seq"] > before
            print("web counter smoke: test entry, fixed orders, giant geometry, real-mouse clusters, continuous feedback and no-save results ok")
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
