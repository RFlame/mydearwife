#!/usr/bin/env node
"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = path.resolve(__dirname, "..", "..");
const build = path.join(root, "build", "minitool");
const context = vm.createContext({ window: {}, console, Promise });
["js/data.js", "js/model.js", "js/game.js", "js/platform.js", "js/renderer.js"].forEach(file => {
  vm.runInContext(fs.readFileSync(path.join(build, file), "utf8"), context, { filename: file });
});
const SDD = context.window.SDD;
const db = new SDD.DataDB(context.window.SnackDingDongData);
let passed = 0;
let failed = 0;
const failures = [];

function test(name, fn) {
  return Promise.resolve().then(fn).then(() => {
    passed += 1;
    console.log("PASS " + name);
  }).catch(error => {
    failed += 1;
    failures.push({ name, error });
    console.error("FAIL " + name + "\n" + error.stack);
  });
}
function advance(game, seconds) {
  const steps = Math.ceil(seconds / 0.05);
  for (let i = 0; i < steps; i += 1) game.update(Math.min(0.05, seconds - i * 0.05));
}
function finishPour(game) {
  game.update(game.pourDuration + 0.01);
  assert.strictEqual(game.phase, "playing");
  game.drainEvents();
}
function fresh(levelId, auto, options) {
  const settings = Object.assign({ auto: auto !== false, seed: 71237 + levelId }, options || {});
  const game = new SDD.Game(db, levelId, settings);
  finishPour(game);
  return game;
}
function layout(game) {
  game.basket.items.forEach((item, index) => {
    item.x = 100 + (index % 3) * 170;
    item.y = 120 + Math.floor(index / 3) * 145;
    item.rotation = 0;
    item.z = index + 1;
    item.picked = false;
  });
  game.basket.items.forEach(item => assert.strictEqual(game.basket.canPick(item.uid), true));
}
function kinds(game) {
  const result = [];
  game.basket.items.forEach(item => { if (result.indexOf(item.snack) < 0) result.push(item.snack); });
  return result;
}
function placeKind(game, snack, zone) {
  game.basket.items.filter(item => item.snack === snack).forEach(item => {
    assert.strictEqual(game.placeInZone(item.uid, zone, { x: item.x, y: item.y }), true, "place " + snack);
  });
}
function serveCurrent(game) {
  layout(game);
  const current = game.customerIndex;
  const list = kinds(game);
  assert.ok(list.length <= 4);
  list.forEach((snack, index) => placeKind(game, snack, index));
  for (let i = 0; i < 800 && game.state === "playing" && game.customerIndex === current && game.phase === "playing"; i += 1) {
    game.update(0.05);
  }
  assert.ok(game.state === "complete" || game.customerIndex > current, "customer should finish");
}

async function main() {
  await test("业务数据保留 20 关、40 款零食、12 位顾客", () => {
    assert.strictEqual(db.levels.length, 20);
    assert.strictEqual(Object.keys(db.snacks).length, 40);
    assert.strictEqual(Object.keys(db.customers).length, 12);
  });

  await test("第 2 关为 3 客 × 6 件，总计 18 件", () => {
    const game = fresh(2, false);
    assert.strictEqual(game.customersTotal, 3);
    assert.strictEqual(game.basket.items.length, 6);
    assert.strictEqual(game.totalItems, 18);
    assert.ok(kinds(game).length <= 3);
  });

  await test("撒落期间锁定，最后一件落地后解锁", () => {
    const game = new SDD.Game(db, 2, { auto: false });
    layout(game);
    const uid = game.basket.items[0].uid;
    const patience = game.patienceLeft;
    assert.strictEqual(game.placeInZone(uid, 0), false);
    game.update(game.pourDuration - 0.02);
    assert.strictEqual(game.phase, "pouring");
    assert.strictEqual(game.patienceLeft, patience);
    assert.strictEqual(game.elapsed, 0);
    game.update(0.03);
    assert.strictEqual(game.phase, "playing");
    assert.strictEqual(game.placeInZone(uid, 0), true);
  });

  await test("暂停与后台等价冻结不推进计时或队列", () => {
    const game = fresh(2, false);
    const elapsed = game.elapsed;
    game.paused = true;
    game.update(10);
    assert.strictEqual(game.elapsed, elapsed);
    game.paused = false;
    game.update(1);
    assert.ok(game.elapsed > elapsed);
  });

  await test("真实遮挡只命中顶层，辅助热区不穿透", () => {
    const bottom = { uid: 1, snack: "chips", weight: 40, size: 1, picked: false, x: 200, y: 200, rotation: 0, z: 1 };
    const top = { uid: 2, snack: "candy", weight: 20, size: 1, picked: false, x: 200, y: 200, rotation: 0, z: 2 };
    const basket = new SDD.Basket([bottom, top]);
    assert.strictEqual(basket.hitTest({ x: 200, y: 200 }), 2);
    assert.strictEqual(basket.hitTestAssisted({ x: 269, y: 200 }, 14), 2);
    assert.strictEqual(basket.canPick(1), false);
    basket.moveItem(2, { x: 400, y: 400 }, false);
    assert.strictEqual(basket.canPick(1), true);
  });

  await test("整桌拖动受收银员过道与称重台禁放区约束", () => {
    const item = { uid: 1, snack: "chips", weight: 40, size: 1, picked: false, x: 200, y: 200, rotation: 0, z: 1 };
    const basket = new SDD.Basket([item]);
    basket.moveItem(1, { x: 700, y: 0 }, true);
    const scaleCorners = SDD.cornersAt(item, item.x, item.y);
    scaleCorners.forEach(p => assert.ok(p.x <= 576 || p.x >= 904 || p.y <= -156 || p.y >= 302));
    basket.moveItem(1, { x: 200, y: 5000 }, false);
    SDD.cornersAt(item, item.x, item.y).forEach(p => assert.ok(p.y <= 800.001));
  });

  await test("椭圆区中心可放置，矩形角不误判为椭圆", () => {
    const rect = SDD.ZONE_RECTS[0];
    assert.strictEqual(SDD.zoneAt({ x: rect.x + rect.w / 2, y: rect.y + rect.h / 2 }), 0);
    assert.strictEqual(SDD.zoneAt({ x: rect.x + 2, y: rect.y + 2 }), -1);
  });

  await test("同款分跨两区时不完整，退回并集中后才入队", () => {
    const game = fresh(1, false);
    layout(game);
    const snack = kinds(game)[0];
    const items = game.basket.items.filter(item => item.snack === snack);
    assert.strictEqual(game.placeInZone(items[0].uid, 0), true);
    assert.strictEqual(game.placeInZone(items[1].uid, 1), true);
    assert.deepStrictEqual(Array.from(game.queue), []);
    assert.strictEqual(game.returnZoneItem(1, items[1].uid), true);
    assert.strictEqual(game.placeInZone(items[1].uid, 0), true);
    assert.deepStrictEqual(Array.from(game.queue), [0]);
  });

  await test("同款全部同区后立即入队并锁定", () => {
    const game = fresh(1, false);
    layout(game);
    const list = kinds(game);
    placeKind(game, list[0], 0);
    assert.deepStrictEqual(Array.from(game.queue), [0]);
    assert.strictEqual(game.isZoneLocked(0), true);
  });

  await test("混放区可退回，已入队区禁止退货", () => {
    const game = fresh(1, false);
    layout(game);
    const list = kinds(game);
    const first = game.basket.items.find(item => item.snack === list[0]);
    const other = game.basket.items.find(item => item.snack === list[1]);
    assert.strictEqual(game.placeInZone(first.uid, 0), true);
    assert.strictEqual(game.placeInZone(other.uid, 0), true);
    assert.strictEqual(game.completeSnack(0), "");
    assert.strictEqual(game.returnZoneItem(0, other.uid), true);
    assert.strictEqual(game.basket.byUid(other.uid).picked, false);
    assert.strictEqual(game.returnZoneItem(0, first.uid), true);
    placeKind(game, list[0], 0);
    assert.strictEqual(game.isZoneLocked(0), true);
    assert.strictEqual(game.returnZoneItem(0, first.uid), false);
  });

  await test("手动模式不自动称重，一次授权消费完整 FIFO 队列", () => {
    const game = fresh(2, false);
    layout(game);
    const list = kinds(game);
    placeKind(game, list[0], 0);
    placeKind(game, list[1], 2);
    placeKind(game, list[2], 3);
    assert.deepStrictEqual(Array.from(game.queue), [0, 2, 3]);
    advance(game, 2);
    assert.strictEqual(game.baggedGroups, 0);
    assert.strictEqual(game.requestManual(), true);
    advance(game, 12);
    const weighed = game.drainEvents().filter(event => event.type === "group_weighed");
    assert.deepStrictEqual(Array.from(weighed, event => event.zone), [0, 2, 3]);
    assert.strictEqual(game.baggedGroups, 3);
    assert.strictEqual(game.queue.length, 0);
    assert.strictEqual(game.manualRequested, false);
  });

  await test("自动模式与手动模式共用串行 active zone", () => {
    const game = fresh(2, true);
    layout(game);
    const list = kinds(game);
    placeKind(game, list[0], 1);
    placeKind(game, list[1], 3);
    advance(game, 0.4);
    assert.strictEqual(game.batchPhase, "flying");
    const active = game.activeZone;
    assert.ok(active >= 0);
    assert.strictEqual(game.queue.indexOf(active), -1);
    advance(game, 8);
    assert.strictEqual(game.baggedGroups, 2);
  });

  await test("切回自动模式会启动已经等待的 FIFO", () => {
    const game = fresh(2, false);
    layout(game);
    placeKind(game, kinds(game)[0], 0);
    advance(game, 1);
    assert.strictEqual(game.baggedGroups, 0);
    game.setAuto(true);
    advance(game, 4);
    assert.strictEqual(game.baggedGroups, 1);
  });

  await test("退货恢复桌面位置并重置当前连击", () => {
    const game = fresh(1, false);
    layout(game);
    const item = game.basket.items[0];
    const origin = { x: item.x, y: item.y };
    game.placeInZone(item.uid, 0, origin);
    assert.ok(game.combo.combo > 0);
    game.returnZoneItem(0, item.uid);
    assert.strictEqual(game.combo.combo, 0);
    assert.strictEqual(item.x, origin.x);
    assert.strictEqual(item.y, origin.y);
    assert.strictEqual(game.returnCount, 1);
  });

  await test("第 2 关连续服务三位顾客并完成 18 件", () => {
    const game = fresh(2, true);
    serveCurrent(game);
    assert.strictEqual(game.customerIndex, 2);
    assert.strictEqual(game.phase, "pouring");
    assert.ok(game.combo.best >= 6, "best combo survives customer change");
    finishPour(game);
    serveCurrent(game);
    finishPour(game);
    serveCurrent(game);
    assert.strictEqual(game.state, "complete");
    assert.strictEqual(game.baggedItems, 18);
    assert.strictEqual(game.result.total_items, 18);
    assert.ok(game.result.coins > 0);
  });

  await test("gift 与 blind 保留原始特殊物品规则", () => {
    const gift = new SDD.Game(db, 15, { auto: false });
    assert.strictEqual(gift.basket.items[0].size, 2);
    const blind = new SDD.Game(db, 16, { auto: false });
    const blindItems = blind.basket.items.filter(item => item.blind);
    assert.ok(blindItems.length > 0 && blindItems.length <= 2);
    const both = new SDD.Game(db, 20, { auto: false });
    assert.strictEqual(both.basket.items[0].size, 2);
    assert.strictEqual(both.basket.items[0].blind, false);
    assert.strictEqual(both.totalItems, 36);
  });

  await test("盲袋入区后揭示，吸附消耗次数并走四区规则", () => {
    const game = fresh(16, false);
    layout(game);
    const blindItem = game.basket.items.find(item => item.blind);
    assert.strictEqual(blindItem.picked, false);
    assert.strictEqual(game.placeInZone(blindItem.uid, 0), true);
    assert.strictEqual(blindItem.picked, true);
    const charges = game.magnetCharges;
    assert.strictEqual(game.useMagnet(), true);
    assert.strictEqual(game.magnetCharges, charges - 1);
  });

  await test("耐心耗尽失败，无限耐心关不失效", () => {
    const limited = fresh(6, false);
    limited.update(limited.patienceTotal + 1);
    assert.strictEqual(limited.state, "failed");
    assert.strictEqual(limited.result.completed, false);
    const unlimited = fresh(3, false);
    unlimited.update(10000);
    assert.strictEqual(unlimited.state, "playing");
  });

  await test("升级影响称重动画与吸附次数，存档记录解锁", () => {
    const save = SDD.defaultSave();
    save.coins = 3000;
    assert.strictEqual(SDD.buyUpgrade(save, db, "scale").ok, true);
    assert.strictEqual(SDD.buyUpgrade(save, db, "magnet").ok, true);
    const game = fresh(1, false, { upgrades: save.upgrades });
    assert.strictEqual(game.cfg.weigh_anim_time, 0.3);
    assert.strictEqual(game.magnetCharges, 2);
    game.state = "complete";
    game.baggedItems = game.totalItems;
    game.finishResult(true);
    SDD.recordResult(save, game);
    assert.strictEqual(save.unlocked, 2);
    assert.ok(save.stars["1"] >= 1);
  });

  await test("Storage 缺失或低版本时明确降级且不写浏览器存储", async () => {
    const bridge = new SDD.PlatformBridge({});
    await bridge.init();
    const loaded = await bridge.load();
    assert.strictEqual(loaded.available, false);
    assert.ok(loaded.reason.indexOf("仅保留") >= 0 || loaded.reason.indexOf("9.46") >= 0);
    assert.strictEqual(await bridge.save({ coins: 1 }), false);
  });

  await test("Storage 使用 JSON 字符串，窗口与振动按能力调用", async () => {
    let written = null;
    let vibration = null;
    const root = {
      xhs: {
        launchOptions: { miniToolEnv: { buildVersion: 9500004 } },
        miniTool: {
          getStorage: () => Promise.resolve({ data: null }),
          setStorage: options => { written = options; return Promise.resolve(); },
          vibrateShort: options => { vibration = options; return Promise.resolve(); },
          getWindowInfo: () => Promise.resolve({ windowWidth: 390, windowHeight: 844, safeArea: { top: 40, left: 0, right: 390, bottom: 810 } })
        }
      }
    };
    const bridge = new SDD.PlatformBridge(root);
    await bridge.init();
    const loaded = await bridge.load();
    assert.strictEqual(loaded.available, true);
    assert.strictEqual(await bridge.save({ coins: 7 }), true);
    assert.strictEqual(typeof written.data, "string");
    assert.strictEqual(JSON.parse(written.data).coins, 7);
    assert.strictEqual(await bridge.vibrate(false), true);
    assert.strictEqual(vibration.type, "light");
    assert.strictEqual(SDD.clientVersion(9500004), 9500);
  });

  await test("换客不会清除上一批独立价签动画", () => {
    const renderer = Object.create(SDD.Renderer.prototype);
    renderer.floaters = [];
    const game = fresh(2, true);
    renderer.handleEvent({ type: "group_weighed", items: game.basket.items.slice(0, 1), weight: 120, price: { total: 8 } }, game);
    assert.ok(renderer.priceTagTimer > 0);
    renderer.handleEvent({ type: "customer_started" }, game);
    assert.ok(renderer.priceTagTimer > 0);
    assert.strictEqual(renderer.priceTag.weight, 120);
  });

  await test("同一布局种子确定，JSON 数据无外置运行时依赖", () => {
    const a = new SDD.Game(db, 2, { seed: 9988 });
    const b = new SDD.Game(db, 2, { seed: 9988 });
    assert.deepStrictEqual(JSON.parse(JSON.stringify(a.basket.items)), JSON.parse(JSON.stringify(b.basket.items)));
    const html = fs.readFileSync(path.join(build, "index.html"), "utf8");
    assert.ok(html.indexOf("柜台准备中") >= 0);
    assert.ok(html.indexOf("重新打开本小工具") >= 0);
    assert.ok(html.indexOf("js/data.js") >= 0);
  });

  console.log("\nFocused mini-tool tests: " + passed + " passed, " + failed + " failed");
  if (failed) {
    console.error(JSON.stringify(failures.map(item => ({ name: item.name, message: item.error.message })), null, 2));
    process.exitCode = 1;
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
