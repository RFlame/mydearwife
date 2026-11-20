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
function fresh(levelId, options) {
  const game = new SDD.Game(db, levelId, options || {});
  game.phase = "playing";
  game.drainEvents();
  return game;
}
function finishPour(game) {
  game.update(game.pourDuration + 0.01);
  assert.strictEqual(game.phase, "playing");
  game.drainEvents();
}
function layout(game) {
  let visibleIndex = 0;
  game.basket.items.forEach(item => {
    if (item.picked) return;
    item.x = 100 + (visibleIndex % 3) * 200;
    item.y = 130 + Math.floor(visibleIndex / 3) * 180;
    item.rotation = 0;
    item.z = visibleIndex + 1;
    visibleIndex += 1;
  });
  game.basket.items.forEach(item => {
    if (!item.picked) assert.strictEqual(game.basket.canPick(item.uid), true);
  });
}
function kinds(game, remainingOnly) {
  const result = [];
  game.basket.items.forEach(item => {
    if ((!remainingOnly || !item.picked) && result.indexOf(item.snack) < 0) result.push(item.snack);
  });
  return result;
}
function positionKind(game, snack, x, y) {
  const items = game.basket.items.filter(item => item.snack === snack && !item.picked);
  items.forEach((item, index) => {
    item.x = x + (index % 3) * 28;
    item.y = y + Math.floor(index / 3) * 24;
  });
  return items;
}
function serveCurrent(game) {
  layout(game);
  const current = game.customerIndex;
  const centers = [[100, 130], [380, 130], [220, 540], [440, 560], [100, 700], [430, 700]];
  kinds(game, true).forEach((snack, index) => positionKind(game, snack, centers[index][0], centers[index][1]));
  game.scanClusters();
  for (let i = 0; i < 200 && game.state === "playing" && game.customerIndex === current && game.phase === "playing"; i += 1) {
    game.update(0.05);
  }
  assert.ok(game.state === "complete" || game.customerIndex > current, "customer should finish");
}
function modelItem(uid, snack, x, y, size, rotation) {
  return { uid, snack, weight: 40, size: size || 1, blind: false, picked: false,
    revealed: false, x, y, rotation: rotation || 0, z: uid };
}
function rendererState() {
  const renderer = Object.create(SDD.Renderer.prototype);
  Object.assign(renderer, { flight: null, scaleBatch: null, scaleBatchTimer: 0,
    ledValue: 20, ledStart: 20, ledTarget: 20, ledElapsed: 0, ledDuration: 0.4,
    priceTags: [], floaters: [], bagPulse: 0, comboPulse: 0, tapBounces: {} });
  return renderer;
}

async function main() {
  await test("第 2 关保持 3 客 × 6 件，总计 18 件", () => {
    const game = fresh(2);
    assert.strictEqual(db.levels.length, 20);
    assert.strictEqual(Object.keys(db.snacks).length, 40);
    assert.strictEqual(Object.keys(db.customers).length, 12);
    assert.strictEqual(game.customersTotal, 3);
    assert.strictEqual(game.basket.items.length, 6);
    assert.strictEqual(game.totalItems, 18);
    assert.strictEqual(kinds(game).length, 3);
  });

  await test("撒落期间锁定，落地完成时自动扫描聚堆", () => {
    const game = new SDD.Game(db, 1, { seed: 71237 });
    const uid = game.basket.items[0].uid;
    const patience = game.patienceLeft;
    assert.strictEqual(game.revealItem(uid), false);
    assert.strictEqual(game.finishMove(uid, { x: 100, y: 100 }, true), false);
    const list = kinds(game);
    positionKind(game, list[0], 100, 130);
    positionKind(game, list[1], 400, 560);
    game.update(game.pourDuration - 0.02);
    assert.strictEqual(game.phase, "pouring");
    assert.strictEqual(game.patienceLeft, patience);
    assert.strictEqual(game.elapsed, 0);
    game.update(0.03);
    assert.strictEqual(game.phase, "playing");
    assert.strictEqual(game.basket.remaining(), 0);
    assert.ok(game.activeBatch.length > 0 || game.queue.length > 0);
  });

  await test("暂停冻结计时和连续批次", () => {
    const game = fresh(1);
    layout(game);
    const list = kinds(game);
    positionKind(game, list[0], 100, 130);
    game.scanClusters();
    const timer = game.batchTimer;
    const elapsed = game.elapsed;
    game.paused = true;
    game.update(10);
    assert.strictEqual(game.elapsed, elapsed);
    assert.strictEqual(game.batchTimer, timer);
    game.paused = false;
    game.update(0.05);
    assert.ok(game.elapsed > elapsed);
    assert.ok(game.batchTimer < timer);
  });

  await test("真实遮挡与整桌禁放边界不受自由聚堆影响", () => {
    const bottom = modelItem(1, "chips", 200, 200);
    const top = modelItem(2, "candy", 200, 200);
    const basket = new SDD.Basket([bottom, top]);
    assert.strictEqual(basket.hitTest({ x: 200, y: 200 }), 2);
    assert.strictEqual(basket.hitTestAssisted({ x: 269, y: 200 }, 14), 2);
    assert.strictEqual(basket.canPick(1), false);
    basket.moveItem(2, { x: 400, y: 400 }, false);
    assert.strictEqual(basket.canPick(1), true);
    basket.moveItem(1, { x: 700, y: 0 }, true);
    SDD.cornersAt(bottom, bottom.x, bottom.y).forEach(p => assert.ok(p.x <= 576 || p.x >= 904 || p.y <= -156 || p.y >= 302));
    basket.moveItem(1, { x: 200, y: 5000 }, false);
    SDD.cornersAt(bottom, bottom.x, bottom.y).forEach(p => assert.ok(p.y <= 800.001));
  });

  await test("同款未全部进入同一连通堆时不触发", () => {
    const items = [modelItem(1, "chips", 100, 130), modelItem(2, "chips", 400, 130),
      modelItem(3, "candy", 100, 600), modelItem(4, "candy", 500, 600)];
    assert.strictEqual(SDD.findReadyClusters(items).length, 0);
  });

  await test("同款通过近邻链连通，而不是要求两两重叠", () => {
    const items = [modelItem(1, "chips", 100, 130), modelItem(2, "chips", 225, 130), modelItem(3, "chips", 350, 130)];
    const ready = SDD.findReadyClusters(items);
    assert.strictEqual(ready.length, 1);
    assert.strictEqual(ready[0].items.length, 3);
  });

  await test("同款表面间距阈值为 18，异款阻断阈值为 28", () => {
    const a = modelItem(1, "chips", 200, 200);
    const b = modelItem(2, "chips", 338, 200);
    assert.strictEqual(SDD.packagesNear(a, b, SDD.CLUSTER_GAP), true);
    b.x = 338.01;
    assert.strictEqual(SDD.packagesNear(a, b, SDD.CLUSTER_GAP), false);
    b.snack = "candy"; b.x = 348;
    assert.strictEqual(SDD.packagesNear(a, b, SDD.FOREIGN_GAP), true);
    b.x = 348.01;
    assert.strictEqual(SDD.packagesNear(a, b, SDD.FOREIGN_GAP), false);
  });

  await test("旋转礼盒使用真实扩张包装轮廓", () => {
    const gift = modelItem(1, "chips", 200, 200, 2, Math.PI / 4);
    const normal = modelItem(2, "chips", 380, 200, 1, Math.PI / 4);
    assert.strictEqual(SDD.packagesNear(gift, normal, SDD.CLUSTER_GAP), true);
    normal.x = 400;
    assert.strictEqual(SDD.packagesNear(gift, normal, SDD.CLUSTER_GAP), false);
    normal.x = 380;
    assert.strictEqual(SDD.findReadyClusters([gift, normal]).length, 1);
  });

  await test("异款贴近阻断，松手移开异款后立即触发", () => {
    const game = fresh(1);
    const list = kinds(game);
    const same = game.basket.items.filter(item => item.snack === list[0]);
    const foreign = game.basket.items.filter(item => item.snack === list[1]);
    same[0].x = 100; same[0].y = 110;
    same[1].x = 130; same[1].y = 110;
    foreign[0].x = 120; foreign[0].y = 240;
    foreign[1].x = 500; foreign[1].y = 650;
    assert.strictEqual(game.scanClusters(), 0);
    assert.strictEqual(game.finishMove(foreign[0].uid, { x: 350, y: 430 }, true), true);
    assert.strictEqual(same[0].picked, true);
    assert.strictEqual(same[1].picked, true);
    assert.strictEqual(game.activeBatch[0].snack, list[0]);
    assert.strictEqual(foreign[0].picked, false);
  });

  await test("拖动途中不检测，finishMove 才锁定完整同款", () => {
    const game = fresh(1);
    layout(game);
    const list = kinds(game);
    const same = game.basket.items.filter(item => item.snack === list[0]);
    positionKind(game, list[1], 400, 600);
    assert.strictEqual(game.moveItem(same[0].uid, { x: 100, y: 130 }, true), true);
    assert.strictEqual(game.activeBatch.length, 0);
    assert.strictEqual(game.finishMove(same[1].uid, { x: 130, y: 130 }, true), true);
    assert.strictEqual(game.activeBatch.length, 2);
    assert.ok(same.every(item => item.picked));
  });

  await test("多个合格堆按首件 uid 确定 FIFO", () => {
    const game = fresh(2);
    layout(game);
    const list = kinds(game);
    positionKind(game, list[0], 100, 130);
    positionKind(game, list[1], 390, 130);
    positionKind(game, list[2], 220, 570);
    assert.strictEqual(game.scanClusters(), 3);
    assert.strictEqual(game.activeBatch[0].snack, list[0]);
    assert.deepStrictEqual(Array.from(game.queue, batch => batch.snack), [list[1], list[2]]);
    assert.deepStrictEqual(Array.from(game.queue, batch => batch.combo), [4, 6]);
  });

  await test("当前批结束同一更新内启动下一批，无冷却空帧", () => {
    const game = fresh(2);
    layout(game);
    const list = kinds(game);
    positionKind(game, list[0], 100, 130);
    positionKind(game, list[1], 390, 130);
    positionKind(game, list[2], 220, 570);
    game.scanClusters(); game.drainEvents();
    game.update(game.batchDuration);
    const events = game.drainEvents();
    assert.strictEqual(events.length, 2);
    assert.strictEqual(events[0].type, "group_weighed");
    assert.strictEqual(events[1].type, "batch_started");
    assert.strictEqual(events[1].snack, list[1]);
    assert.strictEqual(game.batchPhase, "flying");
    assert.strictEqual(game.activeBatch[0].snack, list[1]);
    assert.strictEqual(game.batchTimer, game.batchDuration);
  });

  await test("大 delta 可跨多批结算并保持 FIFO 与连击快照计价", () => {
    const game = fresh(2);
    layout(game);
    const list = kinds(game);
    positionKind(game, list[0], 100, 130);
    positionKind(game, list[1], 390, 130);
    positionKind(game, list[2], 220, 570);
    game.scanClusters(); game.drainEvents();
    game.update(10);
    const weighed = game.drainEvents().filter(event => event.type === "group_weighed");
    assert.deepStrictEqual(Array.from(weighed, event => event.snack), list);
    weighed.forEach((event, index) => {
      const expected = SDD.Score.batchPrice(2, 2, (index + 1) * 2);
      assert.strictEqual(event.price.total, expected.total);
    });
    assert.strictEqual(game.baggedGroups, 3);
    assert.strictEqual(game.customerIndex, 2);
    assert.strictEqual(game.phase, "pouring");
    assert.ok(game.combo.best >= 6);
  });

  await test("第 2 关自由聚堆连续服务三客并完成 18 件", () => {
    const game = fresh(2);
    serveCurrent(game);
    assert.strictEqual(game.customerIndex, 2);
    finishPour(game); serveCurrent(game);
    finishPour(game); serveCurrent(game);
    assert.strictEqual(game.state, "complete");
    assert.strictEqual(game.baggedItems, 18);
    assert.strictEqual(game.result.total_items, 18);
    assert.ok(game.result.coins > 0);
  });

  await test("盲袋拿起揭示，自动入秤也保证揭示", () => {
    const game = fresh(16);
    layout(game);
    const blindItem = game.basket.items.find(item => item.blind);
    assert.strictEqual(game.revealItem(blindItem.uid), true);
    assert.strictEqual(blindItem.revealed, true);
    assert.strictEqual(blindItem.picked, false);
    positionKind(game, blindItem.snack, 120, 650);
    game.scanClusters();
    assert.strictEqual(blindItem.picked, true);
    assert.strictEqual(blindItem.revealed, true);
  });

  await test("吸附在桌面原位附近聚拢同款并消耗次数", () => {
    const game = fresh(1);
    layout(game);
    const charges = game.magnetCharges;
    assert.strictEqual(game.useMagnet(), true);
    assert.strictEqual(game.magnetCharges, charges - 1);
    assert.ok(game.activeBatch.length > 0);
    assert.ok(game.activeBatch.every(item => item.picked));
    assert.strictEqual(game.returnCount, 0);
  });

  await test("耐心失败、无限耐心和升级存档保持兼容", () => {
    const limited = fresh(6);
    limited.update(limited.patienceTotal + 1);
    assert.strictEqual(limited.state, "failed");
    const unlimited = fresh(3);
    unlimited.update(10000);
    assert.strictEqual(unlimited.state, "playing");
    const save = SDD.defaultSave(); save.coins = 3000;
    assert.strictEqual(SDD.buyUpgrade(save, db, "scale").ok, true);
    assert.strictEqual(SDD.buyUpgrade(save, db, "magnet").ok, true);
    const upgraded = fresh(1, { upgrades: save.upgrades });
    assert.strictEqual(upgraded.cfg.weigh_anim_time, 0.3);
    assert.strictEqual(upgraded.magnetCharges, 2);
    upgraded.state = "complete"; upgraded.baggedItems = upgraded.totalItems; upgraded.finishResult(true);
    SDD.recordResult(save, upgraded);
    assert.strictEqual(save.unlocked, 2);
    assert.ok(save.stars["1"] >= 1);
  });

  await test("飞行使用实际桌面起点，秤上驻留与下一批并行", () => {
    const renderer = rendererState();
    const game = fresh(2);
    const first = modelItem(1, "chips", 123, 456);
    const second = modelItem(2, "candy", 321, 654);
    renderer.handleEvent({ type: "group_weighed", items: [first], weight: 120, price: { total: 8 } }, game);
    assert.strictEqual(renderer.priceTags.length, 1);
    assert.strictEqual(renderer.scaleBatchTimer, 0.16);
    renderer.handleEvent({ type: "batch_started", items: [second], duration: 0.18, flightTime: 0.18, stagger: 0 }, game);
    assert.strictEqual(renderer.flight.starts[0].x, 321);
    assert.strictEqual(renderer.flight.starts[0].y, 654);
    assert.strictEqual(renderer.priceTags.length, 1);
    assert.strictEqual(renderer.scaleBatchTimer, 0.16);
    renderer.advance(0.05);
    assert.strictEqual(renderer.flight.elapsed, 0.05);
    assert.ok(renderer.scaleBatchTimer < 0.16);
    assert.ok(renderer.priceTags[0].life < 0.62);
  });

  await test("LED 从当前值接续，换客保留上一批价签", () => {
    const renderer = rendererState();
    const game = fresh(2);
    const item = modelItem(1, "chips", 100, 100);
    renderer.handleEvent({ type: "group_weighed", items: [item], weight: 120, price: { total: 8 } }, game);
    assert.strictEqual(renderer.ledStart, 20);
    assert.strictEqual(renderer.ledTarget, 120);
    renderer.advance(0.05);
    assert.ok(renderer.ledValue > 20 && renderer.ledValue < 120);
    renderer.handleEvent({ type: "customer_started", index: 2 }, game);
    assert.strictEqual(renderer.priceTags.length, 1);
    assert.strictEqual(renderer.priceTags[0].weight, 120);
    renderer.handleEvent({ type: "customer_started", index: 1 }, game);
    assert.strictEqual(renderer.priceTags.length, 0);
    assert.strictEqual(renderer.ledValue, 0);
  });

  await test("Storage 缺失时明确降级且不写浏览器存储", async () => {
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
    const rootObject = {
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
    const bridge = new SDD.PlatformBridge(rootObject);
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

  await test("源码无四区、手动模式旧接口，静态首屏保留", () => {
    const source = ["js/model.js", "js/game.js", "js/renderer.js", "js/app.js"].map(file =>
      fs.readFileSync(path.join(build, file), "utf8")).join("\n");
    const obsolete = /ZONE_RECTS|zoneItemPoint|placeInZone|returnZoneItem|requestManual|setAuto|hitZoneItem|pendingZone|activeZone|queueDelay|manualRequested/;
    assert.strictEqual(obsolete.test(source), false);
    const html = fs.readFileSync(path.join(build, "index.html"), "utf8");
    assert.ok(html.indexOf("柜台准备中") >= 0);
    assert.ok(html.indexOf("重新打开本小工具") >= 0);
    assert.ok(html.indexOf("同款全部聚成一堆") >= 0);
    assert.strictEqual(html.indexOf("四个集货区"), -1);
  });

  await test("同一布局种子确定，JSON 数据无外置运行时依赖", () => {
    const a = new SDD.Game(db, 2, { seed: 9988 });
    const b = new SDD.Game(db, 2, { seed: 9988 });
    assert.deepStrictEqual(JSON.parse(JSON.stringify(a.basket.items)), JSON.parse(JSON.stringify(b.basket.items)));
    const html = fs.readFileSync(path.join(build, "index.html"), "utf8");
    assert.ok(html.indexOf("js/data.js") >= 0);
  });

  console.log("\nFocused mini-tool tests: " + passed + " passed, " + failed + " failed");
  if (failed) {
    console.error(JSON.stringify(failures.map(item => ({ name: item.name, message: item.error.message })), null, 2));
    process.exitCode = 1;
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
