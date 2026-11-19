(function () {
  "use strict";
  var SDD = window.SDD = window.SDD || {};
  var ZONE_FLIGHT_TIME = 0.26;
  var BATCH_FLIGHT_TIME = 0.34;

  function DataDB(raw) {
    this.raw = raw;
    this.snacks = {};
    this.customers = {};
    this.levels = raw.levels.levels || raw.levels;
    this.difficulty = raw.difficulty;
    this.upgrades = raw.upgrades;
    var snackList = raw.snacks.snacks || raw.snacks.items || [];
    var customerList = raw.customers.customers || raw.customers.items || [];
    for (var i = 0; i < snackList.length; i += 1) this.snacks[snackList[i].id] = snackList[i];
    for (var c = 0; c < customerList.length; c += 1) this.customers[customerList[c].id] = customerList[c];
  }
  DataDB.prototype.level = function (levelId) {
    for (var i = 0; i < this.levels.length; i += 1) if (this.levels[i].id === levelId) return this.levels[i];
    return this.levels[0];
  };
  DataDB.prototype.runtimeConfig = function (levelId, presetName, upgradesOwned) {
    var source = this.level(levelId);
    var cfg = {};
    Object.keys(source).forEach(function (key) { cfg[key] = source[key]; });
    var preset = this.difficulty.presets[presetName] || this.difficulty.presets.standard;
    var owned = upgradesOwned || { tray: 1, scale: 1, magnet: 1 };
    var trayLevel = Math.max(1, owned.tray || 1);
    var scaleLevel = Math.max(1, owned.scale || 1);
    var magnetLevel = Math.max(1, owned.magnet || 1);
    cfg.preset = presetName;
    cfg.tray_slots = Math.min(9, preset.tray_slots + trayLevel - 1);
    cfg.patience = (cfg.patience || 0) * preset.patience_scale;
    cfg.combo_window_sec = preset.combo_window_sec;
    cfg.magnet_charges = preset.magnet_charges + magnetLevel - 1;
    var animTimes = this.upgrades.scale.anim_times;
    cfg.weigh_anim_time = animTimes[SDD.clamp(scaleLevel - 1, 0, animTimes.length - 1)];
    cfg.auto_hint = !!preset.auto_hint;
    cfg.deadlock_protection = !!preset.deadlock_protection;
    if (!cfg.pool) cfg.pool = Object.keys(this.snacks);
    if (cfg.pool_categories) {
      var categories = cfg.pool_categories;
      var snacks = this.snacks;
      cfg.pool = Object.keys(snacks).filter(function (id) { return categories.indexOf(snacks[id].category) >= 0; });
    }
    cfg.customers = cfg.customers || cfg.baskets || 1;
    return cfg;
  };

  function Combo(windowSeconds) { this.best = 0; this.reset(); this.window = windowSeconds || 3; }
  Combo.prototype.reset = function () { this.combo = 0; this.timer = 0; };
  Combo.prototype.register = function () {
    this.combo = this.timer > 0 && this.combo > 0 ? this.combo + 1 : 1;
    this.timer = this.window;
    this.best = Math.max(this.best, this.combo);
  };
  Combo.prototype.tick = function (delta) {
    if (this.timer <= 0) return;
    this.timer = Math.max(0, this.timer - delta);
    if (this.timer === 0) this.combo = 0;
  };

  function Score() {}
  Score.itemBase = function (levelId) { return 1.7 * (1 + levelId * 0.02); };
  Score.batchPrice = function (levelId, itemCount, combo) {
    var base = Score.itemBase(levelId) * itemCount;
    var batchBonus = base * Math.max(0, itemCount - 1) * 0.04;
    var comboBonus = base * Math.min(combo * 0.05, 0.5);
    return { base: Math.round(base), bonus: Math.round(batchBonus + comboBonus), total: Math.round(base + batchBonus + comboBonus) };
  };
  Score.stars = function (fields) {
    if (!fields.completed) return 0;
    var result = 1;
    var totalItems = Math.max(1, fields.total_items || 1);
    var fast = fields.patience_unlimited ? fields.time_used <= totalItems * 4 * 1.5 : fields.patience_ratio >= 0.4;
    if (fast) {
      result = 2;
      if (fields.best_combo >= Math.ceil(totalItems * 0.65) && !fields.had_tray_full) result = 3;
    }
    return result;
  };
  Score.settle = function (fields) {
    var perfect = fields.completed && !fields.had_tray_full;
    var coins = Math.round(fields.coins_earned || 0);
    if (perfect) coins = Math.round(coins * 1.3);
    var tip = Math.round((fields.best_combo || 0) * 2 * (fields.tip_mult || 1));
    return { completed: fields.completed, stars: Score.stars(fields), coins: fields.completed ? coins + tip : Math.round(coins * 0.2),
      tip: tip, perfect: perfect, best_combo: fields.best_combo || 0, time_used: fields.time_used || 0,
      total_items: fields.total_items || 0, bagged_items: fields.bagged_items || 0, total_groups: fields.bagged_groups || 0,
      return_count: fields.return_count || 0 };
  };

  function Game(db, levelId, options) {
    options = options || {};
    this.db = db;
    this.levelId = levelId;
    this.cfg = db.runtimeConfig(levelId, options.preset || "standard", options.upgrades);
    this.auto = options.auto !== false;
    this.seed = options.seed || levelId * 10007 + 20261119;
    this.layoutRng = new SDD.RNG(this.seed);
    this.customerRng = new SDD.RNG(this.seed + 97);
    this.weightRng = new SDD.RNG(this.seed + 193);
    this.state = "playing";
    this.phase = "pouring";
    this.paused = false;
    this.events = [];
    this.customerIndex = 0;
    this.customersTotal = this.cfg.customers;
    this.customerQueue = this.buildCustomerQueue();
    this.totalItems = 0;
    this.elapsed = 0;
    this.coinsEarned = 0;
    this.baggedItems = 0;
    this.baggedGroups = 0;
    this.returnCount = 0;
    this.hadTrayFull = false;
    this.result = null;
    this.idleTime = 0;
    this.seenSnacks = {};
    this.seenCustomers = {};
    this.nextCustomer();
  }
  Game.prototype.emit = function (type, data) {
    var event = { type: type };
    if (data) Object.keys(data).forEach(function (key) { event[key] = data[key]; });
    this.events.push(event);
  };
  Game.prototype.drainEvents = function () { return this.events.splice(0, this.events.length); };
  Game.prototype.buildCustomerQueue = function () {
    var ids = Object.keys(this.db.customers);
    var result = [];
    var featured = this.cfg.customer || "normal";
    for (var i = 0; i < this.customersTotal; i += 1) {
      var target = featured;
      if (i < this.customersTotal - 1) {
        if (featured === "normal") target = "normal";
        else if (i % 2 === 1) target = featured;
        else target = "normal";
      }
      var self = this;
      var candidates = ids.filter(function (id) { return self.db.customers[id].base_type === target && result.indexOf(id) < 0; });
      if (!candidates.length) candidates = ids.filter(function (id) { return self.db.customers[id].base_type === target; });
      if (!candidates.length) candidates = ids.filter(function (id) { return result.indexOf(id) < 0; });
      if (!candidates.length) candidates = ids;
      result.push(this.customerRng.pick(candidates));
    }
    return result;
  };
  Game.prototype.currentCustomerId = function () { return this.customerQueue[this.customerIndex - 1]; };
  Game.prototype.currentCustomer = function () { return this.db.customers[this.currentCustomerId()] || {}; };
  Game.prototype.upcomingCustomers = function () { return this.customerQueue.slice(this.customerIndex); };
  Game.prototype.nextCustomer = function () {
    this.customerIndex += 1;
    this.basket = SDD.generateBasket(this.cfg, this.db.snacks, this.layoutRng);
    this.sections = [[], [], [], []];
    this.queue = [];
    this.activeZone = -1;
    this.activeBatch = [];
    this.batchPhase = "idle";
    this.batchTimer = 0;
    this.queueDelay = 0;
    this.manualRequested = false;
    this.magnetCharges = this.cfg.magnet_charges;
    if (this.customerIndex === 1) this.totalItems = this.basket.remaining() * this.customersTotal;
    var profile = this.currentCustomer();
    var previousBest = this.combo ? this.combo.best : 0;
    this.patienceTotal = (this.cfg.patience || 0) * (profile.patience_mult || 1);
    this.patienceLeft = this.patienceTotal;
    this.combo = new Combo(this.cfg.combo_window_sec * (profile.combo_window_mult || 1));
    this.combo.best = previousBest;
    this.seenCustomers[this.currentCustomerId()] = true;
    for (var seen = 0; seen < this.basket.items.length; seen += 1) this.seenSnacks[this.basket.items[seen].snack] = true;
    this.phase = "pouring";
    this.pourElapsed = 0;
    var stagger = Math.min(0.30, 0.98 / Math.max(1, this.basket.items.length - 1));
    this.pourDuration = 1.2 + 0.12 + stagger * Math.max(0, this.basket.items.length - 1) + 0.58;
    this.emit("customer_started", { index: this.customerIndex, customerId: this.currentCustomerId(), items: this.basket.items, duration: this.pourDuration });
    this.emit("pour_started", { index: this.customerIndex, duration: this.pourDuration });
  };
  Game.prototype.canInteract = function () { return this.state === "playing" && this.phase === "playing" && !this.paused; };
  Game.prototype.patienceRatio = function () { return this.patienceTotal <= 0 ? 1 : SDD.clamp(this.patienceLeft / this.patienceTotal, 0, 1); };
  Game.prototype.update = function (delta) {
    if (this.paused || this.state !== "playing" || delta <= 0) return;
    if (this.phase === "pouring") {
      this.pourElapsed += delta;
      if (this.pourElapsed >= this.pourDuration) {
        this.phase = "playing";
        this.emit("pour_finished", { index: this.customerIndex });
      }
      return;
    }
    this.elapsed += delta;
    this.idleTime += delta;
    this.combo.tick(delta);
    if (this.patienceTotal > 0) {
      this.patienceLeft = Math.max(0, this.patienceLeft - delta);
      if (this.patienceLeft <= 0) {
        this.state = "failed";
        this.finishResult(false);
        this.emit("failed", { result: this.result });
        return;
      }
    }
    this.updateBatch(delta);
  };
  Game.prototype.zoneForUid = function (uid) {
    for (var z = 0; z < this.sections.length; z += 1) {
      for (var i = 0; i < this.sections[z].length; i += 1) if (this.sections[z][i].uid === uid) return z;
    }
    return -1;
  };
  Game.prototype.isZoneLocked = function (zoneIndex) { return this.activeZone === zoneIndex || this.queue.indexOf(zoneIndex) >= 0; };
  Game.prototype.completeSnack = function (zoneIndex) {
    if (zoneIndex < 0 || zoneIndex >= 4 || !this.sections[zoneIndex].length) return "";
    var snackId = this.sections[zoneIndex][0].snack;
    for (var i = 0; i < this.sections[zoneIndex].length; i += 1) if (this.sections[zoneIndex][i].snack !== snackId) return "";
    for (var j = 0; j < this.basket.items.length; j += 1) {
      var item = this.basket.items[j];
      if (item.snack !== snackId) continue;
      if (!item.picked || this.zoneForUid(item.uid) !== zoneIndex) return "";
    }
    return snackId;
  };
  Game.prototype.snackTotal = function (snackId) {
    var total = 0;
    for (var i = 0; i < this.basket.items.length; i += 1) if (this.basket.items[i].snack === snackId) total += 1;
    return total;
  };
  Game.prototype.refreshQueue = function () {
    for (var z = 0; z < 4; z += 1) {
      if (this.isZoneLocked(z)) continue;
      var snackId = this.completeSnack(z);
      if (!snackId) continue;
      this.queue.push(z);
      this.emit("zone_queued", { zone: z, snack: snackId });
    }
    if (this.queue.length && this.batchPhase === "idle" && (this.auto || this.manualRequested) && this.queueDelay <= 0) {
      this.queueDelay = ZONE_FLIGHT_TIME + 0.05;
    }
  };
  Game.prototype.placeInZone = function (uid, zoneIndex, origin) {
    if (!this.canInteract() || zoneIndex < 0 || zoneIndex >= 4 || this.isZoneLocked(zoneIndex)) return false;
    var item = this.basket.byUid(uid);
    if (!item || !this.basket.canPick(uid)) return false;
    var returnPoint = origin || { x: item.x, y: item.y };
    if (!this.basket.pick(uid)) return false;
    item.returnX = returnPoint.x; item.returnY = returnPoint.y;
    this.sections[zoneIndex].push(item);
    this.combo.register();
    this.idleTime = 0;
    this.emit("snack_zoned", { uid: uid, zone: zoneIndex, snack: item.snack, blind: item.blind });
    this.emit("zone_changed", { zone: zoneIndex });
    this.refreshQueue();
    return true;
  };
  Game.prototype.returnZoneItem = function (zoneIndex, uid) {
    if (!this.canInteract() || this.isZoneLocked(zoneIndex)) return false;
    var section = this.sections[zoneIndex];
    for (var i = 0; i < section.length; i += 1) {
      if (section[i].uid !== uid) continue;
      var item = section.splice(i, 1)[0];
      this.basket.unpick(uid);
      this.basket.bringToFront(uid);
      this.basket.moveItem(uid, { x: item.returnX, y: item.returnY }, false);
      this.returnCount += 1;
      this.combo.reset();
      this.idleTime = 0;
      this.emit("snack_returned", { uid: uid, zone: zoneIndex, snack: item.snack });
      this.emit("zone_changed", { zone: zoneIndex });
      this.refreshQueue();
      return true;
    }
    return false;
  };
  Game.prototype.moveItem = function (uid, p, bringToFront) {
    if (!this.canInteract()) return false;
    var moved = this.basket.moveItem(uid, p, bringToFront);
    if (moved) this.idleTime = 0;
    return moved;
  };
  Game.prototype.setAuto = function (enabled) {
    this.auto = !!enabled;
    if (this.auto) {
      this.manualRequested = false;
      this.refreshQueue();
      if (this.queue.length && this.batchPhase === "idle") this.queueDelay = ZONE_FLIGHT_TIME + 0.05;
    }
  };
  Game.prototype.requestManual = function () {
    if (!this.canInteract()) return false;
    this.refreshQueue();
    if (this.activeZone < 0 && !this.queue.length) return false;
    if (!this.manualRequested && this.batchPhase === "idle") this.queueDelay = ZONE_FLIGHT_TIME + 0.05;
    this.manualRequested = true;
    this.emit("manual_requested", {});
    return true;
  };
  Game.prototype.beginNextBatch = function () {
    if (this.batchPhase !== "idle" || !this.queue.length) return null;
    var zoneIndex = this.queue.shift();
    var group = this.sections[zoneIndex].slice();
    this.sections[zoneIndex] = [];
    this.activeZone = zoneIndex;
    this.activeBatch = group;
    this.batchPhase = "flying";
    var stagger = Math.min(0.035, 0.12 / Math.max(1, group.length - 1));
    this.batchTimer = BATCH_FLIGHT_TIME + stagger * Math.max(0, group.length - 1) + 0.05;
    this.emit("batch_started", { zone: zoneIndex, items: group, duration: this.batchTimer });
    return group;
  };
  Game.prototype.settleActiveBatch = function () {
    if (this.activeZone < 0 || !this.activeBatch.length) return false;
    var group = this.activeBatch.slice();
    var snackId = group[0].snack;
    for (var i = 0; i < group.length; i += 1) if (group[i].snack !== snackId) return false;
    var weight = 0;
    for (var w = 0; w < group.length; w += 1) weight += group[w].weight;
    weight = Math.round(weight * this.weightRng.range(0.95, 1.05));
    var price = Score.batchPrice(this.levelId, group.length, this.combo.combo);
    this.coinsEarned += price.total;
    this.baggedItems += group.length;
    this.baggedGroups += 1;
    var zoneIndex = this.activeZone;
    this.activeZone = -1;
    this.activeBatch = [];
    this.batchPhase = "cooldown";
    this.batchTimer = Math.max(0.68, this.cfg.weigh_anim_time + 0.28);
    this.emit("group_weighed", { zone: zoneIndex, items: group, snack: snackId, weight: weight, price: price });
    this.checkEnd();
    return true;
  };
  Game.prototype.updateBatch = function (delta) {
    if (this.batchPhase === "flying") {
      this.batchTimer -= delta;
      if (this.batchTimer <= 0) this.settleActiveBatch();
      return;
    }
    if (this.batchPhase === "cooldown") {
      this.batchTimer -= delta;
      if (this.batchTimer <= 0) {
        this.batchPhase = "idle";
        this.batchTimer = 0;
        if (this.queue.length && (this.auto || this.manualRequested)) this.queueDelay = ZONE_FLIGHT_TIME + 0.05;
        else this.manualRequested = false;
      }
      return;
    }
    if (!this.queue.length) { this.manualRequested = false; return; }
    if (!this.auto && !this.manualRequested) return;
    if (this.queueDelay > 0) { this.queueDelay -= delta; return; }
    this.beginNextBatch();
  };
  Game.prototype.zonesClear = function () {
    if (this.activeZone >= 0 || this.queue.length) return false;
    for (var i = 0; i < 4; i += 1) if (this.sections[i].length) return false;
    return true;
  };
  Game.prototype.checkEnd = function () {
    if (this.state !== "playing" || this.basket.remaining() > 0 || !this.zonesClear()) return false;
    if (this.customerIndex >= this.customersTotal) {
      this.state = "complete";
      this.phase = "done";
      this.finishResult(true);
      this.emit("complete", { result: this.result });
    } else {
      this.emit("customer_served", { index: this.customerIndex });
      this.nextCustomer();
    }
    return true;
  };
  Game.prototype.finishResult = function (completed) {
    var tipMult = this.cfg.customer === "rich" ? 2 : this.cfg.customer === "hurried" ? 1.5 : 1;
    this.result = Score.settle({ completed: completed, coins_earned: this.coinsEarned, best_combo: this.combo.best,
      tip_mult: tipMult, total_items: this.totalItems, time_used: this.elapsed, patience_unlimited: this.patienceTotal <= 0,
      patience_ratio: this.patienceRatio(), had_tray_full: this.hadTrayFull, bagged_items: this.baggedItems,
      bagged_groups: this.baggedGroups, return_count: this.returnCount });
  };
  Game.prototype.chooseMagnetZone = function (snackId) {
    var empty = -1;
    for (var z = 0; z < 4; z += 1) {
      if (this.isZoneLocked(z)) continue;
      if (!this.sections[z].length && empty < 0) empty = z;
      if (this.sections[z].length && this.sections[z][0].snack === snackId) return z;
    }
    return empty;
  };
  Game.prototype.useMagnet = function () {
    if (!this.canInteract() || this.magnetCharges <= 0) return false;
    var sorted = this.basket.sorted();
    for (var i = sorted.length - 1; i >= 0; i -= 1) {
      var item = sorted[i];
      if (item.picked || !this.basket.canPick(item.uid)) continue;
      var zoneIndex = this.chooseMagnetZone(item.snack);
      if (zoneIndex < 0) continue;
      var matching = this.basket.accessibleSame(item.snack);
      var moved = 0;
      for (var m = 0; m < matching.length; m += 1) {
        if (this.placeInZone(matching[m].uid, zoneIndex, { x: matching[m].x, y: matching[m].y })) moved += 1;
      }
      if (moved > 0) {
        this.magnetCharges -= 1;
        this.emit("magnet_used", { snack: item.snack, zone: zoneIndex, count: moved, charges: this.magnetCharges });
        return true;
      }
    }
    return false;
  };
  Game.prototype.hintUid = function () {
    if (!this.cfg.auto_hint || this.idleTime < 3 || !this.canInteract()) return -1;
    var sorted = this.basket.sorted();
    for (var i = sorted.length - 1; i >= 0; i -= 1) if (!sorted[i].picked && this.basket.canPick(sorted[i].uid)) return sorted[i].uid;
    return -1;
  };

  function defaultSave() {
    return { version: 1, coins: 0, stars: {}, unlocked: 1, upgrades: { tray: 1, scale: 1, magnet: 1 },
      discovered: {}, customersDiscovered: {}, settings: { sfx: true, vibrate: true, preset: "standard" } };
  }
  function sanitizeSave(value) {
    var save = defaultSave();
    if (!value || typeof value !== "object") return save;
    save.coins = Math.max(0, Number(value.coins) || 0);
    save.stars = value.stars && typeof value.stars === "object" ? value.stars : {};
    save.unlocked = SDD.clamp(Number(value.unlocked) || 1, 1, 20);
    var names = ["tray", "scale", "magnet"];
    for (var i = 0; i < names.length; i += 1) {
      var name = names[i];
      save.upgrades[name] = SDD.clamp(Number(value.upgrades && value.upgrades[name]) || 1, 1, 3);
    }
    save.discovered = value.discovered && typeof value.discovered === "object" ? value.discovered : {};
    save.customersDiscovered = value.customersDiscovered && typeof value.customersDiscovered === "object" ? value.customersDiscovered : {};
    if (value.settings) {
      save.settings.sfx = value.settings.sfx !== false;
      save.settings.vibrate = value.settings.vibrate !== false;
      save.settings.preset = value.settings.preset || "standard";
    }
    return save;
  }
  function recordResult(save, game) {
    if (!game.result) return;
    save.coins += game.result.coins;
    if (!game.result.completed) return;
    var id = String(game.levelId);
    save.stars[id] = Math.max(Number(save.stars[id]) || 0, game.result.stars);
    save.unlocked = Math.max(save.unlocked, Math.min(20, game.levelId + 1));
    Object.keys(game.seenSnacks).forEach(function (snackId) { save.discovered[snackId] = true; });
    Object.keys(game.seenCustomers).forEach(function (customerId) { save.customersDiscovered[customerId] = true; });
  }
  function buyUpgrade(save, db, name) {
    var definition = db.upgrades[name];
    if (!definition) return { ok: false, reason: "未知设备" };
    var level = save.upgrades[name] || 1;
    if (level >= definition.max_level) return { ok: false, reason: "已经满级" };
    var cost = definition.costs[level - 1];
    if (save.coins < cost) return { ok: false, reason: "金币不足" };
    save.coins -= cost;
    save.upgrades[name] = level + 1;
    return { ok: true, cost: cost, level: level + 1 };
  }

  SDD.DataDB = DataDB;
  SDD.Game = Game;
  SDD.Score = Score;
  SDD.defaultSave = defaultSave;
  SDD.sanitizeSave = sanitizeSave;
  SDD.recordResult = recordResult;
  SDD.buyUpgrade = buyUpgrade;
}());
