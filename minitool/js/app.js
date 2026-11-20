(function () {
  "use strict";
  var SDD = window.SDD = window.SDD || {};

  function App() {
    this.db = new SDD.DataDB(window.SnackDingDongData);
    this.canvas = document.getElementById("game-canvas");
    this.renderer = new SDD.Renderer(this.canvas, this.db);
    this.platform = new SDD.PlatformBridge(window);
    this.audio = new SDD.SynthAudio(window);
    this.save = SDD.defaultSave();
    this.game = null;
    this.preview = null;
    this.playing = false;
    this.drag = null;
    this.lastFrameTime = 0;
    this.accumulator = 0;
    this.rafId = 0;
    this.tickBound = this.tick.bind(this);
    this.toastTimer = 0;
    this.storageWarningShown = false;
    this.resultRecorded = false;
  }
  App.prototype.el = function (id) { return document.getElementById(id); };
  App.prototype.init = function () {
    var self = this;
    this.bindUI();
    var baseAssets = ["bg_shop.svg", "counter_top.svg", "cashier_aisle.svg", "cashier_body.svg", "cashier_arm.svg",
      "bag.svg", "basket.svg", "scale_stand.svg", "scale_platform.svg", "pos_screen.svg", "blind.svg", "gift.svg"];
    return this.platform.init().then(function () { return self.platform.load(); }).then(function (stored) {
      self.save = SDD.sanitizeSave(stored.save);
      self.audio.enabled = self.save.settings.sfx;
      self.el("storage-status").textContent = stored.reason;
      self.el("preset-select").value = self.save.settings.preset;
      self.preview = new SDD.Game(self.db, 1, { seed: 1101 });
      self.preview.phase = "playing";
      var assets = baseAssets.concat(self.preview.cfg.pool.map(function (id) { return self.db.snacks[id].svg; }));
      assets.push(self.renderer.customerFile(self.preview.currentCustomerId()));
      return self.renderer.preload(assets);
    }).then(function () {
      self.buildLevelSelect();
      self.refreshHome();
      self.renderer.render(self.preview, null);
      self.el("boot-panel").hidden = true;
      self.el("home-panel").hidden = false;
      self.startLoop();
    }).catch(function (error) {
      self.showStartupError(error);
    });
  };
  App.prototype.showStartupError = function () {
    this.stopLoop();
    this.el("home-panel").hidden = true;
    this.el("boot-panel").hidden = false;
    this.el("boot-title").textContent = "柜台暂时没准备好";
    this.el("boot-message").textContent = "本地资源或脚本未能就绪。请重试；若仍失败，请重新打开本小工具。";
    var retry = this.el("boot-retry");
    retry.disabled = false; retry.textContent = "重新准备";
  };
  App.prototype.bindUI = function () {
    var self = this;
    this.el("boot-retry").addEventListener("click", function () { window.location.reload(); });
    this.el("start-button").addEventListener("click", function () { self.startSelectedLevel(); });
    this.el("level-select").addEventListener("change", function () { self.refreshLevelMeta(); });
    this.el("preset-select").addEventListener("change", function () {
      self.save.settings.preset = self.el("preset-select").value; self.persist();
    });
    this.el("upgrades-button").addEventListener("click", function () { self.showUpgrades(); });
    this.el("snacks-button").addEventListener("click", function () { self.showCollection("snacks"); });
    this.el("customers-button").addEventListener("click", function () { self.showCollection("customers"); });
    this.el("collection-close").addEventListener("click", function () { self.el("collection-panel").hidden = true; });
    this.el("sound-button").addEventListener("click", function () {
      self.save.settings.sfx = !self.save.settings.sfx; self.audio.setEnabled(self.save.settings.sfx); self.refreshSettings(); self.persist();
    });
    this.el("vibrate-button").addEventListener("click", function () {
      self.save.settings.vibrate = !self.save.settings.vibrate; self.refreshSettings(); self.persist();
      if (self.save.settings.vibrate) self.platform.vibrate(false);
    });
    this.canvas.addEventListener("pointerdown", function (event) { self.pointerDown(event); }, { passive: false });
    this.canvas.addEventListener("pointermove", function (event) { self.pointerMove(event); }, { passive: false });
    this.canvas.addEventListener("pointerup", function (event) { self.pointerUp(event); }, { passive: false });
    this.canvas.addEventListener("pointercancel", function (event) { self.pointerCancel(event); }, { passive: false });
    this.canvas.addEventListener("contextmenu", function (event) { event.preventDefault(); });
    document.addEventListener("visibilitychange", function () { self.visibilityChanged(); });
    window.addEventListener("resize", function () { self.platform.readWindowInfo(); });
  };
  App.prototype.buildLevelSelect = function () {
    var select = this.el("level-select");
    while (select.firstChild) select.removeChild(select.firstChild);
    for (var i = 0; i < this.db.levels.length; i += 1) {
      var level = this.db.levels[i];
      var option = document.createElement("option");
      option.value = String(level.id); option.textContent = "第 " + level.id + " 关 · " + level.customers + " 位顾客";
      option.disabled = level.id > this.save.unlocked;
      select.appendChild(option);
    }
    select.value = String(Math.min(this.save.unlocked, this.db.levels.length));
    this.refreshLevelMeta();
  };
  App.prototype.refreshHome = function () {
    this.buildLevelSelect();
    this.el("coin-count").textContent = Math.round(this.save.coins) + " 金币";
    var stars = 0;
    var starMap = this.save.stars;
    Object.keys(starMap).forEach(function (key) { stars += Number(starMap[key]) || 0; });
    this.el("star-count").textContent = stars + " / " + (this.db.levels.length * 3) + " 星";
    this.el("preset-select").value = this.save.settings.preset;
    this.refreshSettings();
  };
  App.prototype.refreshSettings = function () {
    this.el("sound-button").textContent = "音效：" + (this.save.settings.sfx ? "开" : "关");
    this.el("sound-button").setAttribute("aria-pressed", String(this.save.settings.sfx));
    this.el("vibrate-button").textContent = "振动：" + (this.save.settings.vibrate ? "开" : "关");
    this.el("vibrate-button").setAttribute("aria-pressed", String(this.save.settings.vibrate));
  };
  App.prototype.refreshLevelMeta = function () {
    var levelId = Number(this.el("level-select").value) || 1;
    var level = this.db.level(levelId);
    var features = level.features || [];
    var text = level.customers + " 客 × " + level.items + " 件 · " + level.snack_kinds + " 款 · ";
    text += level.patience > 0 ? "基础耐心 " + level.patience + " 秒" : "不限耐心";
    if (features.length) text += " · " + (features.indexOf("gift") >= 0 ? "礼盒 " : "") + (features.indexOf("blind") >= 0 ? "盲袋" : "");
    this.el("level-meta").textContent = text;
  };
  App.prototype.startSelectedLevel = function (overrideLevel) {
    if (this.starting) return;
    var self = this;
    this.audio.unlock();
    var levelId = overrideLevel || Number(this.el("level-select").value) || 1;
    if (levelId > this.save.unlocked) { this.toast("先完成前一关"); return; }
    this.starting = true;
    var startButton = this.el("start-button"); startButton.disabled = true; startButton.textContent = "正在摆好柜台…";
    this.stopLoop();
    var game = new SDD.Game(this.db, levelId, { preset: this.save.settings.preset, upgrades: this.save.upgrades });
    var assets = ["basket.svg", "blind.svg", "gift.svg"];
    game.cfg.pool.forEach(function (id) { assets.push(self.db.snacks[id].svg); });
    game.customerQueue.forEach(function (id) { assets.push(self.renderer.customerFile(id)); });
    this.renderer.preload(assets).then(function () {
      self.game = game; self.preview = null; self.playing = true; self.starting = false; self.resultRecorded = false;
      self.drag = null;
      self.el("home-panel").hidden = true; self.el("dialog-panel").hidden = true; self.el("collection-panel").hidden = true;
      startButton.disabled = false; startButton.textContent = "开始营业";
      self.processEvents(); self.lastFrameTime = 0; self.accumulator = 0; self.startLoop();
    }).catch(function (error) { self.starting = false; startButton.disabled = false; startButton.textContent = "开始营业"; self.showStartupError(error); });
  };
  App.prototype.startLoop = function () {
    if (this.rafId || document.hidden) return;
    this.lastFrameTime = 0;
    this.rafId = window.requestAnimationFrame(this.tickBound);
  };
  App.prototype.stopLoop = function () {
    if (this.rafId) window.cancelAnimationFrame(this.rafId);
    this.rafId = 0; this.lastFrameTime = 0; this.accumulator = 0;
  };
  App.prototype.tick = function (timestamp) {
    this.rafId = 0;
    if (document.hidden) return;
    if (!this.lastFrameTime) this.lastFrameTime = timestamp;
    var delta = Math.min(0.1, Math.max(0, (timestamp - this.lastFrameTime) / 1000));
    this.lastFrameTime = timestamp;
    this.accumulator += delta;
    if (this.accumulator >= 1 / 30) {
      var step = Math.min(0.1, this.accumulator); this.accumulator = 0;
      if (this.game && this.playing) {
        if (!this.game.paused) { this.game.update(step); this.renderer.advance(step); }
        this.processEvents(); this.renderer.render(this.game, this.drag);
      } else if (this.preview) this.renderer.render(this.preview, null);
    }
    this.rafId = window.requestAnimationFrame(this.tickBound);
  };
  App.prototype.visibilityChanged = function () {
    if (document.hidden) { this.stopLoop(); this.audio.suspend(); }
    else {
      this.lastFrameTime = 0; this.accumulator = 0;
      if (this.save.settings.sfx && this.playing && this.game && !this.game.paused) this.audio.unlock();
      this.startLoop();
    }
  };
  App.prototype.processEvents = function () {
    if (!this.game) return;
    var events = this.game.drainEvents();
    for (var i = 0; i < events.length; i += 1) {
      var event = events[i];
      this.renderer.handleEvent(event, this.game);
      if (event.type === "customer_started") {
        this.save.customersDiscovered[event.customerId] = true;
      } else if (event.type === "snacks_gathered") {
        this.save.discovered[event.snack] = true;
        this.audio.play(gameComboName(event.combo), event.combo);
        if (this.save.settings.vibrate && event.combo >= 5) this.platform.vibrate(false);
      } else if (event.type === "group_weighed") {
        for (var s = 0; s < event.items.length; s += 1) this.save.discovered[event.items[s].snack] = true;
        this.audio.play("beep"); this.audio.play("print"); this.audio.play("bag");
        if (this.save.settings.vibrate) this.platform.vibrate(false);
      } else if (event.type === "magnet_used") this.audio.play("magnet");
      else if (event.type === "customer_served") this.persist();
      else if (event.type === "complete") { this.audio.play("complete"); if (this.save.settings.vibrate) this.platform.vibrate(true); this.gameEnded(true); }
      else if (event.type === "failed") { this.audio.play("fail"); this.gameEnded(false); }
    }
  };
  function gameComboName(combo) { return combo >= 3 ? "combo" : "zone"; }
  App.prototype.gameEnded = function (completed) {
    if (!this.resultRecorded) {
      SDD.recordResult(this.save, this.game);
      this.resultRecorded = true; this.persist();
    }
    var self = this;
    var result = this.game.result;
    var body = document.createElement("div");
    var stars = document.createElement("div"); stars.className = "result-stars";
    stars.textContent = completed ? "★★★".slice(0, result.stars) + "☆☆☆".slice(0, 3 - result.stars) : "耐心用完了";
    body.appendChild(stars);
    var grid = document.createElement("div"); grid.className = "result-grid";
    var values = [[result.bagged_items + "/" + result.total_items, "装袋"], [result.total_groups, "称重批次"], [result.coins, "金币"]];
    values.forEach(function (pair) {
      var cell = document.createElement("div"); var strong = document.createElement("strong"); var span = document.createElement("span");
      strong.textContent = pair[0]; span.textContent = pair[1]; cell.appendChild(strong); cell.appendChild(span); grid.appendChild(cell);
    });
    body.appendChild(grid);
    var summary = document.createElement("p");
    summary.textContent = completed ? "最佳连击 ×" + result.best_combo + " · 小费 " + result.tip + " · 连续称重 " + result.total_groups + " 批" : "已结算收入保留 20%，再试一次可以先整理同款。";
    body.appendChild(summary);
    this.showDialog(completed ? "本关营业完成" : "顾客等太久了", body, completed ? "叮咚！柜台清空啦" : "别灰心，重新整理节奏");
    if (completed && this.game.levelId < this.db.levels.length) this.addDialogButton("下一关", true, function () { self.startSelectedLevel(self.game.levelId + 1); });
    this.addDialogButton(completed ? "再玩一次" : "重新挑战", !completed, function () { self.startSelectedLevel(self.game.levelId); });
    this.addDialogButton("返回首页", false, function () { self.goHome(); });
  };
  App.prototype.goHome = function () {
    this.stopLoop(); this.playing = false; this.game = null; this.drag = null;
    this.el("dialog-panel").hidden = true; this.el("home-panel").hidden = false; this.el("collection-panel").hidden = true;
    this.refreshHome();
    this.preview = new SDD.Game(this.db, Math.min(this.save.unlocked, this.db.levels.length), { preset: this.save.settings.preset, upgrades: this.save.upgrades });
    this.preview.phase = "playing";
    var self = this;
    var assets = this.preview.cfg.pool.map(function (id) { return self.db.snacks[id].svg; });
    assets.push(this.renderer.customerFile(this.preview.currentCustomerId()));
    this.renderer.preload(assets).then(function () { if (self.preview) self.renderer.render(self.preview, null); self.startLoop(); });
  };
  App.prototype.pause = function () {
    if (!this.game || this.game.state !== "playing" || this.game.paused) return;
    this.game.paused = true; this.drag = null; this.audio.suspend();
    var self = this;
    var body = document.createElement("p"); body.textContent = "计时、撒落与称重队列都已暂停。";
    this.showDialog("暂停营业", body, "喝口茶，慢慢来");
    this.addDialogButton("继续营业", true, function () { self.resume(); });
    this.addDialogButton("重新开始本关", false, function () { self.startSelectedLevel(self.game.levelId); });
    this.addDialogButton("返回首页", false, function () { self.goHome(); });
  };
  App.prototype.resume = function () {
    if (!this.game) return;
    this.game.paused = false; this.el("dialog-panel").hidden = true; this.lastFrameTime = 0; this.accumulator = 0;
    if (this.save.settings.sfx) this.audio.unlock(); this.startLoop();
  };
  App.prototype.showDialog = function (title, body, eyebrow) {
    this.el("dialog-title").textContent = title;
    this.el("dialog-eyebrow").textContent = eyebrow || "零食叮叮咚";
    var container = this.el("dialog-body");
    while (container.firstChild) container.removeChild(container.firstChild);
    if (body) container.appendChild(body);
    var actions = this.el("dialog-actions"); while (actions.firstChild) actions.removeChild(actions.firstChild);
    this.el("dialog-panel").hidden = false;
  };
  App.prototype.addDialogButton = function (text, primary, handler) {
    var button = document.createElement("button"); button.type = "button"; button.textContent = text;
    if (primary) button.className = "primary-button";
    button.addEventListener("click", handler); this.el("dialog-actions").appendChild(button);
  };
  App.prototype.showUpgrades = function () {
    var self = this;
    var body = document.createElement("div");
    var names = ["scale", "magnet"];
    names.forEach(function (name) {
      var definition = self.db.upgrades[name]; var level = self.save.upgrades[name];
      var row = document.createElement("section"); row.className = "upgrade-row";
      var heading = document.createElement("h3"); heading.textContent = definition.name + " · Lv." + level;
      var desc = document.createElement("p"); desc.textContent = definition.desc;
      row.appendChild(heading); row.appendChild(desc);
      var button = document.createElement("button"); button.type = "button";
      button.textContent = level >= definition.max_level ? "已满级" : "升级 · " + definition.costs[level - 1] + " 金币";
      button.disabled = level >= definition.max_level;
      button.addEventListener("click", function () {
        var result = SDD.buyUpgrade(self.save, self.db, name);
        self.toast(result.ok ? definition.name + "升到 Lv." + result.level : result.reason);
        if (result.ok) { self.persist(); self.refreshHome(); self.showUpgrades(); }
      });
      row.appendChild(button); body.appendChild(row);
    });
    this.showDialog("设备升级", body, "当前 " + Math.round(this.save.coins) + " 金币");
    this.addDialogButton("返回", true, function () { self.el("dialog-panel").hidden = true; });
  };
  App.prototype.showCollection = function (kind) {
    var content = this.el("collection-content"); while (content.firstChild) content.removeChild(content.firstChild);
    var isSnacks = kind === "snacks";
    this.el("collection-title").textContent = isSnacks ? "零食图鉴" : "顾客图鉴";
    var list = isSnacks ? this.db.raw.snacks.snacks : this.db.raw.customers.customers;
    for (var i = 0; i < list.length; i += 1) {
      var entry = list[i]; var discovered = isSnacks ? this.save.discovered[entry.id] : this.save.customersDiscovered[entry.id];
      var card = document.createElement("div"); card.className = "collection-card" + (discovered ? "" : " locked");
      var inner = document.createElement("div"); inner.className = "collection-card-inner";
      var image = document.createElement("img"); image.alt = discovered ? entry.name : "未发现";
      image.src = "assets/svg/" + (discovered ? (isSnacks ? entry.svg : entry.avatar) : "blind.svg");
      var name = document.createElement("strong"); name.textContent = discovered ? entry.name : "？？？";
      var detail = document.createElement("small");
      detail.textContent = discovered ? (isSnacks ? entry.brand + " · " + entry.weight + "g" : entry.personality) : "营业中解锁";
      inner.appendChild(image); inner.appendChild(name); inner.appendChild(detail); card.appendChild(inner); content.appendChild(card);
    }
    this.el("collection-panel").hidden = false;
  };
  App.prototype.persist = function () {
    var self = this;
    return this.platform.save(this.save).then(function (saved) {
      if (!saved && !self.platform.storageAvailable) self.el("storage-status").textContent = self.platform.storageReason;
      if (!saved && self.platform.storageAvailable) {
        self.platform.storageAvailable = false;
        self.platform.storageReason = "存档写入失败；之后的进度仅保留到关闭前";
        self.el("storage-status").textContent = self.platform.storageReason;
        if (!self.storageWarningShown) { self.toast(self.platform.storageReason); self.storageWarningShown = true; }
      }
      return saved;
    });
  };
  App.prototype.toast = function (message) {
    var toast = this.el("toast"); toast.textContent = message; toast.hidden = false;
    if (this.toastTimer) window.clearTimeout(this.toastTimer);
    var self = this;
    this.toastTimer = window.setTimeout(function () { toast.hidden = true; self.toastTimer = 0; }, 2300);
  };
  App.prototype.pointInRect = function (p, rect) { return p.x >= rect.x && p.x <= rect.x + rect.w && p.y >= rect.y && p.y <= rect.y + rect.h; };
  App.prototype.pointerDown = function (event) {
    if (!this.game || !this.playing || this.game.state !== "playing") return;
    event.preventDefault(); this.audio.unlock();
    var p = this.renderer.eventPoint(event);
    if (this.pointInRect(p, this.renderer.pauseRect)) { this.pause(); return; }
    if (!this.game.canInteract()) return;
    if (this.pointInRect(p, this.renderer.magnetRect)) {
      if (!this.game.useMagnet()) this.toast(this.game.magnetCharges <= 0 ? "本顾客吸附次数已用完" : "暂时没有可聚拢的同款零食");
      return;
    }
    var local = this.renderer.globalToLocal(p);
    var uid = this.game.basket.hitTestAssisted(local, 14);
    if (uid <= 0 || !this.game.basket.canPick(uid)) return;
    this.game.revealItem(uid);
    var item = this.game.basket.byUid(uid);
    this.drag = { uid: uid, pointerId: event.pointerId, start: p,
      offset: { x: item.x - local.x, y: item.y - local.y }, dragging: false };
    this.capturePointer(event);
  };
  App.prototype.capturePointer = function (event) {
    if (typeof this.canvas.setPointerCapture === "function") {
      try { this.canvas.setPointerCapture(event.pointerId); } catch (error) {}
    }
  };
  App.prototype.pointerMove = function (event) {
    if (!this.drag || this.drag.pointerId !== event.pointerId || !this.game || !this.game.canInteract()) return;
    event.preventDefault();
    var p = this.renderer.eventPoint(event);
    if (!this.drag.dragging && Math.hypot(p.x - this.drag.start.x, p.y - this.drag.start.y) > 9) this.drag.dragging = true;
    if (!this.drag.dragging) return;
    var local = this.renderer.globalToLocal(p);
    this.game.moveItem(this.drag.uid, { x: local.x + this.drag.offset.x, y: local.y + this.drag.offset.y }, true);
  };
  App.prototype.pointerUp = function (event) {
    if (!this.game || !this.playing) return;
    event.preventDefault();
    if (!this.drag || this.drag.pointerId !== event.pointerId) return;
    var drag = this.drag;
    this.drag = null;
    if (this.game.canInteract() && drag.dragging) {
      var p = this.renderer.eventPoint(event); var local = this.renderer.globalToLocal(p);
      this.game.finishMove(drag.uid, { x: local.x + drag.offset.x, y: local.y + drag.offset.y }, true);
    } else if (this.game.canInteract()) {
      this.renderer.tapBounces[drag.uid] = 0.14;
      this.game.idleTime = 0;
    }
  };
  App.prototype.pointerCancel = function (event) {
    if (!this.drag || this.drag.pointerId !== event.pointerId) return;
    var drag = this.drag;
    this.drag = null;
    if (!drag.dragging || !this.game || !this.game.canInteract()) return;
    var item = this.game.basket.byUid(drag.uid);
    if (item && !item.picked) this.game.finishMove(drag.uid, { x: item.x, y: item.y }, false);
  };

  var app = new App();
  SDD.app = app;
  app.init();
}());
