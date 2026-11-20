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

sys.dont_write_bytecode = True

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


def assert_product_geometry(snapshot):
    bases = {1: (120.0, 104.0), 2: (152.0, 120.0), 3: (192.0, 164.0)}
    scales = set()
    for item in snapshot["table_items"]:
        base = bases[item["size"]]
        multiplier = item["package_scale"] * item["product_scale"]
        expected = (base[0] * multiplier, base[1] * multiplier)
        actual = item["logical_size"]
        assert math.hypot(actual["x"] - expected[0], actual["y"] - expected[1]) < 0.02, item
        assert abs(actual["x"] / base[0] - actual["y"] / base[1]) < 0.001, item
        scales.add(round(item["product_scale"], 3))
    assert len(scales) >= 2 and max(scales) - min(scales) > 0.05, scales


def table_item(snapshot, uid):
    return next(item for item in snapshot["table_items"] if item["uid"] == uid)


def disconnected_nearby_target(source, mate):
    """在 220px 内寻找一对旋转矩形仍有 24px 投影净间隙的真实落点。"""
    best = None
    for degree in range(0, 360, 2):
        angle = math.radians(degree)
        extent = 0.0
        for item in (source, mate):
            relative = angle - item["rotation"]
            half_x, half_y = item["logical_size"]["x"] * 0.5, item["logical_size"]["y"] * 0.5
            extent += abs(math.cos(relative)) * half_x + abs(math.sin(relative)) * half_y
        distance = extent + 24.0
        if distance <= 214.0 and (best is None or distance < best[0]):
            best = (distance, angle)
    assert best is not None, "current rotated pair has no disconnected fixture within 220px"
    distance, angle = best
    return (source["table_x"] + math.cos(angle) * distance,
            source["table_y"] + math.sin(angle) * distance)


async def key(client, key, code, virtual_key):
    await client.call("Input.dispatchKeyEvent", {"type": "keyDown", "key": key, "code": code,
                                                   "windowsVirtualKeyCode": virtual_key, "nativeVirtualKeyCode": virtual_key})
    await asyncio.sleep(0.04)
    await client.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": key, "code": code,
                                                 "windowsVirtualKeyCode": virtual_key, "nativeVirtualKeyCode": virtual_key})
    await asyncio.sleep(0.06)


async def choose_option(client, name, index):
    """读取真实弹窗位置后点击菜单项，不硬编码不同页面切换后的窗口坐标。"""
    test = await web.wait_snapshot(client, lambda s: s.get("page") == "test", 5)
    await client.click(**center(test["controls"][name]))

    def opened(s):
        if s.get("page") != "test":
            return False
        popup = s["controls"][name].get("popup", {})
        rect = popup.get("rect", {})
        return popup.get("visible", False) and rect.get("w", 0) > 0 and rect.get("h", 0) > 0

    opened_test = await web.wait_snapshot(client, opened, 5)
    popup = opened_test["controls"][name]["popup"]["rect"]
    count = opened_test["controls"][name]["item_count"]
    await client.click(popup["x"] + popup["w"] * 0.5,
                       popup["y"] + popup["h"] * (index + 0.5) / count)
    await asyncio.sleep(0.2)


async def set_fixed_quantity(client, test, value=2):
    if test["test_options"].get("random_quantity", True):
        await client.click(**center(test["controls"]["random"]))
        await asyncio.sleep(0.16)
    slider = test["controls"]["quantity"]
    # 最右端可能落在滑杆有效热区之外；先点击中部偏右取得焦点，再用键盘到精确值。
    ratio = (min(value, 7) - 1.0) / 9.0
    await client.click(slider["x"] + slider["w"] * ratio, slider["y"] + slider["h"] * 0.5)
    await key(client, "Home", "Home", 36)
    for _ in range(value - 1):
        await key(client, "ArrowRight", "ArrowRight", 39)
    await asyncio.sleep(0.12)


async def configure_test(client, level=2, giant=0, scale=1.5, check_quantity_limit=False):
    test = await web.wait_snapshot(client, lambda s: s.get("page") == "test", 8)
    controls = test["controls"]
    await choose_option(client, "level", level - 1)
    test = await web.snapshot(client)
    assert test["test_options"]["level_id"] == level, test
    await choose_option(client, "preset", 1)
    if check_quantity_limit:
        await set_fixed_quantity(client, await web.snapshot(client), 10)
        maximum = await web.wait_snapshot(client, lambda s: s.get("page") == "test" and s["test_options"]["fixed_quantity"] == 10, 5)
        assert not maximum["test_options"]["random_quantity"]
    await set_fixed_quantity(client, await web.snapshot(client), 2)
    size = controls["size"]
    await client.click(size["x"] + size["w"] * (scale - 1.0), size["y"] + size["h"] * 0.5)
    await asyncio.sleep(0.12)
    await choose_option(client, "giant", giant)
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
    print("drag uid", uid, "from", (round(node["table_x"], 2), round(node["table_y"], 2)),
          "to", target, "pointer", (round(available["x"], 2), round(available["y"], 2)),
          "end", (round(end["x"], 2), round(end["y"], 2)))

    def arrived(s):
        if s.get("page") != "game" or s.get("customer") != customer:
            return True
        moved = next((item for item in s.get("table_items", []) if item["uid"] == uid), None)
        if s.get("drag_uid", -1) != -1:
            return False
        return moved is None or math.hypot(moved["table_x"] - target[0], moved["table_y"] - target[1]) < 2.0
    try:
        return await web.wait_snapshot(client, arrived, 5)
    except AssertionError:
        latest = await web.snapshot(client)
        moved = next((item for item in latest.get("table_items", []) if item["uid"] == uid), None)
        positions = [(item["uid"], item["snack"], round(item["table_x"], 2), round(item["table_y"], 2))
                     for item in latest.get("table_items", [])]
        raise AssertionError("drag uid %d target=%s origin=%s actual=%s drag_uid=%s items=%s tap=%s" % (
            uid, target, (node["table_x"], node["table_y"]),
            None if moved is None else (moved["table_x"], moved["table_y"]), latest.get("drag_uid"),
            positions, latest.get("table_tap"))) from None


async def perform_handoff(client, customer, out_dir, tag):
    game = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer and not s.get("switching"), 12)
    groups = by_kind(game)
    assert len(groups) == 2 and all(len(items) == 2 for items in groups.values()), groups
    ordered = sorted(groups.values(), key=lambda items: items[0]["uid"])
    a, b = ordered
    a1, a2 = a[0]["uid"], a[1]["uid"]
    b1, b2 = b[0]["uid"], b[1]["uid"]
    baseline_bagged = game["bagged_items"]

    # B 先形成完整连通堆，A1 与 B1 实际重叠而阻断；A2 留在远处使 A 不完整。
    await drag_to(client, a2, (140.0, 700.0), customer)
    await drag_to(client, b1, (560.0, 400.0), customer)
    current = await web.snapshot(client)
    a1_item, b1_item = table_item(current, a1), table_item(current, b1)
    contact = (b1_item["table_x"], b1_item["table_y"] +
               (a1_item["logical_size"]["y"] + b1_item["logical_size"]["y"]) * 0.5 - 0.02)
    await drag_to(client, a1, contact, customer)
    current = await web.snapshot(client)
    b1_item, b2_item = table_item(current, b1), table_item(current, b2)
    b2_target = (b1_item["table_x"] + (b1_item["logical_size"]["x"] + b2_item["logical_size"]["x"]) * 0.5 + 9.0,
                 b1_item["table_y"])
    blocked = await drag_to(client, b2, b2_target, customer)
    assert blocked["customer"] == customer and blocked["remaining"] == 4 and blocked["bagged_items"] == baseline_bagged, blocked
    assert not blocked["active_batch"] and not blocked["batch_queue"], blocked
    await client.shot(os.path.join(out_dir, "web_%s_blocked.png" % tag), 0.0)

    # A1 移开后两堆同时合格，沿用 FIFO 连续称重与独立价签。
    current = await web.snapshot(client)
    a1_item, a2_item = table_item(current, a1), table_item(current, a2)
    final_a1 = (a2_item["table_x"] + (a1_item["logical_size"]["x"] + a2_item["logical_size"]["x"]) * 0.5 + 9.0,
                a2_item["table_y"])
    serial_before = current["batch_serial"]
    await drag_to(client, a1, final_a1, customer)
    queued = await wait_history(client, lambda s: s.get("customer") == customer and s.get("batch_serial", 0) > serial_before and len(s.get("batch_queue", [])) >= 1, 4)
    assert queued["active_batch"] and queued["batch_phase"] == "flying", queued
    await client.shot(os.path.join(out_dir, "web_%s_queued.png" % tag), 0.0)
    done = await web.wait_snapshot(client, lambda s: s.get("page") != "game" or s.get("bagged_items", 0) >= baseline_bagged + 4, 10)
    rows = await history(client)
    assert any(s.get("customer") == customer and s.get("active_batch") and s.get("price_tags", 0) >= 1 for s in rows), "next batch did not overlap previous price tag"
    assert any(s.get("customer") == customer and s.get("price_tags", 0) >= 2 for s in rows), "independent price tags did not coexist"
    return done


async def place_pending(client, customer, pending):
    pending = dict(pending)
    for _round in range(32):
        if not pending:
            break
        snapshot = await web.snapshot(client)
        if snapshot.get("page") != "game" or snapshot.get("customer") != customer:
            # 连锁称重可能直接完成当前顾客；余下待拖物品已随订单一起结算。
            pending.clear()
            break
        present = {item["uid"] for item in snapshot.get("table_items", [])}
        for uid in list(pending):
            if uid not in present:
                pending.pop(uid)
        if snapshot.get("active_batch") or snapshot.get("batch_queue"):
            # 自动批次会改变桌面节点与曝光；等待落地后再取真实命中点。
            await web.wait_snapshot(client, lambda s: s.get("page") != "game" or s.get("customer") != customer
                                    or (not s.get("active_batch") and not s.get("batch_queue")), 5)
            continue
        exposed = {item["uid"] for item in snapshot.get("available", [])}
        uid = next((uid for uid in pending if uid in exposed), None)
        if uid is None:
            if pending:
                await asyncio.sleep(0.12)
            continue
        target = pending.pop(uid)
        await drag_to(client, uid, target, customer)
    assert not pending, "covered snacks remained after repeated real-drag passes: %s" % pending
    return await web.snapshot(client)


async def spread_three_pairs(client, customer):
    game = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer and not s.get("switching"), 12)
    groups = by_kind(game)
    assert len(groups) == 3 and all(len(items) == 2 for items in groups.values()), groups
    points = [(140.0, 160.0), (140.0, 560.0), (400.0, 360.0),
              (400.0, 700.0), (700.0, 420.0), (700.0, 700.0)]
    pending = {}
    ordered = sorted(groups.values(), key=lambda value: value[0]["uid"])
    for pair_index, items in enumerate(ordered):
        for member, item in enumerate(items):
            pending[item["uid"]] = points[pair_index * 2 + member]
    game = await place_pending(client, customer, pending)
    assert game["remaining"] == 6 and not game["active_batch"] and not game["batch_queue"], game
    return game


async def click_distant_pair(client, customer, out_dir, tag):
    game = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer and not s.get("switching"), 8)
    groups = by_kind(game)
    assert groups and all(len(items) == 2 for items in groups.values()), groups
    remaining_before = game["remaining"]
    pair = sorted(groups.values(), key=lambda value: value[0]["uid"])[0]
    source, target = pair
    origin = (source["table_x"], source["table_y"])
    available = next(item for item in game["available"] if item["uid"] == source["uid"])
    serial_before = game["batch_serial"]
    bagged_before = game["bagged_items"]
    tap_before = game["table_tap"]["seq"]
    await web.click_point(client, available)
    await client.shot(os.path.join(out_dir, "web_%s_click_flight.png" % tag), 0.0)
    flight = await wait_history(client, lambda s: s.get("customer") == customer and s.get("table_tap", {}).get("seq", 0) > tap_before
                                and s.get("table_tap", {}).get("uid") == source["uid"] and s.get("click_flight_uid") == source["uid"], 4)
    tap = flight["table_tap"]
    assert tap["outcome"] == "fly" and tap["target_uid"] == target["uid"], tap
    assert math.hypot(tap["from"]["x"] - origin[0], tap["from"]["y"] - origin[1]) < 0.02, tap
    flying_source = table_item(flight, source["uid"])
    assert math.hypot(flying_source["table_x"] - origin[0], flying_source["table_y"] - origin[1]) < 0.02, flying_source
    assert flight["batch_serial"] == serial_before and flight["remaining"] == remaining_before, flight
    done = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer
                                   and s.get("weighed_serial", 0) > 0 and s.get("bagged_items", 0) >= bagged_before + 2
                                   and not s.get("active_batch") and not s.get("batch_queue"), 8)
    assert done["remaining"] == remaining_before - 2 and done["click_flight_uid"] == -1, done
    assert done["table_tap"]["outcome"] == "fly" and done["table_tap"]["target_uid"] == target["uid"], done["table_tap"]
    return done


async def verify_bounce_fallback(client, customer):
    game = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer and not s.get("switching"), 8)
    pair = sorted(by_kind(game).values(), key=lambda value: value[0]["uid"])[0]
    source, mate = pair
    target = disconnected_nearby_target(source, mate)
    await drag_to(client, mate["uid"], target, customer)
    game = await web.snapshot(client)
    source = table_item(game, source["uid"])
    available = next(item for item in game["available"] if item["uid"] == source["uid"])
    serial_before = game["batch_serial"]
    bagged_before = game["bagged_items"]
    tap_before = game["table_tap"]["seq"]
    await web.click_point(client, available)
    bounced = await web.wait_snapshot(client, lambda s: s.get("table_tap", {}).get("seq", 0) > tap_before
                                      and s.get("table_tap", {}).get("uid") == source["uid"], 5)
    assert bounced["table_tap"]["outcome"] == "bounce" and bounced["table_tap"]["target_uid"] == -1, bounced["table_tap"]
    item = table_item(bounced, source["uid"])
    assert math.hypot(item["table_x"] - source["table_x"], item["table_y"] - source["table_y"]) < 0.02, item
    assert bounced["batch_serial"] == serial_before and bounced["bagged_items"] == bagged_before and bounced["remaining"] == 4, bounced
    assert bounced["click_flight_uid"] == -1
    return bounced


async def solve_pairs(client, customer):
    game = await web.wait_snapshot(client, lambda s: s.get("page") == "game" and s.get("customer") == customer and not s.get("switching"), 12)
    groups = by_kind(game)
    assert groups and all(len(items) == 2 for items in groups.values()), groups
    expected_bagged = game["bagged_items"] + game["remaining"]
    # 每组使用独立象限；同组可重叠连通，组间保留净间隙，避免求解夹具自身造成异款接触。
    origins = [(140.0, 140.0), (430.0, 140.0), (140.0, 620.0), (650.0, 620.0)]
    assert len(groups) <= len(origins), groups
    pending = {}
    for index, items in enumerate(sorted(groups.values(), key=lambda value: value[0]["uid"])):
        for item in items:
            pending[item["uid"]] = origins[index]
    await place_pending(client, customer, pending)

    def completed(s):
        if s.get("page") == "result":
            return True
        return (s.get("page") == "game" and s.get("customer") == customer + 1
                and s.get("bagged_items") == expected_bagged and not s.get("switching"))
    return await web.wait_snapshot(client, completed, 12)


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
            # 固定一逻辑像素对应一 CSS 像素，避免亚像素缩放令精确接触夹具偏开 1～2px。
            await client.call("Emulation.setDeviceMetricsOverride", {
                "width": 720, "height": 1280, "deviceScaleFactor": 1, "mobile": False})
            navigation = await client.call("Page.navigate", {"url": url})
            if navigation.get("errorText"):
                raise AssertionError("page navigation failed: %s" % navigation)
            print("loading", url)
            home = await web.wait_snapshot(client, lambda s: s.get("page") == "home", 30)
            save_before = home["save_summary"]
            assert home.get("test_entry"), home
            await client.shot(os.path.join(out_dir, "web_test_home.png"))
            await client.click(**center(home["test_entry"]))
            test = await configure_test(client, 1, 0, check_quantity_limit=True)
            await client.shot(os.path.join(out_dir, "web_test_screen.png"))
            game = await start_test(client, test)
            assert game["level"] == 1 and game["remaining"] == 6 and game["total_items"] == 12, game
            assert game["test_mode"] and game["package_scale"] == 1.5 and game["giant_kinds"] == 0, game
            assert len(by_kind(game)) == 3 and all(len(items) == 2 for items in by_kind(game).values())
            assert_product_geometry(game)
            assert game["save_summary"] == save_before
            await client.shot(os.path.join(out_dir, "web_counter_ready.png"))

            await spread_three_pairs(client, 1)
            game = await click_distant_pair(client, 1, out_dir, "customer1")
            game = await verify_bounce_fallback(client, 1)
            serial_before = game["batch_serial"]
            await client.double_click({"x": 690, "y": 1160})
            await asyncio.sleep(0.25)
            idle = await web.snapshot(client)
            assert idle["remaining"] == 4 and idle["bagged_items"] == 2 and idle["batch_serial"] == serial_before
            await perform_handoff(client, 1, out_dir, "customer1")
            switched = await wait_history(client, lambda s: s.get("customer") == 2 and s.get("switching")
                                          and s.get("led_value", 0) > 0 and s.get("price_tags", 0) >= 1, 5)
            await client.shot(os.path.join(out_dir, "web_customer_switch_feedback.png"), 0.0)
            # 第二客允许移开阻挡物后合法连锁称重；单击与 FIFO 已在第一客完整验证。
            await solve_pairs(client, 2)
            result = await web.wait_snapshot(client, lambda s: s.get("page") == "result", 12)
            assert result["test_mode"] and result["test_config"]["level_id"] == 1
            assert result["save_summary"] == save_before
            await web.click_point(client, result["next"])
            test = await configure_test(client, 2, 0)
            level_two = await start_test(client, test)
            assert level_two["customers"] == 3 and level_two["remaining"] == 8 and level_two["total_items"] == 24
            assert len(level_two["table_items"]) == 8 and len(by_kind(level_two)) == 4 and level_two["save_summary"] == save_before
            assert_product_geometry(level_two)
            progressed = await solve_pairs(client, 1)
            assert progressed["customer"] == 2 and progressed["remaining"] == 8 and progressed["bagged_items"] == 8
            assert progressed["bagged_groups"] == 4 and abs(progressed["progress"]["value"] - 8.0 / 24.0) < 0.0001
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
            assert_product_geometry(giant_game)
            assert giant_game["save_summary"] == save_before
            await client.shot(os.path.join(out_dir, "web_test_giant_scatter.png"))
            exposed_giant = next((item for item in giant_game["available"] if item["giant"]), None)
            if exposed_giant:
                before = giant_game["table_tap"]["seq"]
                await web.click_point(client, exposed_giant)
                tapped_giant = await web.wait_snapshot(client, lambda s: s.get("table_tap", {}).get("uid") == exposed_giant["uid"], 5)
                assert tapped_giant["table_tap"]["seq"] > before and tapped_giant["table_tap"]["outcome"] in ("fly", "bounce")
                if tapped_giant["table_tap"]["outcome"] == "fly":
                    assert tapped_giant["table_tap"]["target_uid"] != exposed_giant["uid"]
                else:
                    assert tapped_giant["table_tap"]["target_uid"] == -1 and tapped_giant["click_flight_uid"] == -1
            print("web counter smoke: 3..10 kinds, ten-item controls, product geometry, click flight/bounce, real-mouse clusters and no-save results ok")
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
