(function () {
  "use strict";
  var SDD = window.SDD = window.SDD || {};
  var TABLE_SCALE = 0.78;
  var TABLE_Y = 400;
  var COLORS = ["#c94f3d", "#527c89", "#5e7d5b", "#b98242"];

  function Renderer(canvas, db) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.db = db;
    this.images = {};
    this.imagePromises = {};
    this.displayBatch = null;
    this.flightDuration = 0;
    this.ledValue = 0;
    this.ledTarget = 0;
    this.ledElapsed = 0;
    this.ledDuration = 0.4;
    this.priceTag = null;
    this.priceTagTimer = 0;
    this.bagPulse = 0;
    this.comboPulse = 0;
    this.floaters = [];
    this.tapBounces = {};
    this.pauseRect = { x: 642, y: 16, w: 62, h: 58 };
    this.magnetRect = { x: 542, y: 16, w: 88, h: 58 };
    this.modeRect = { x: 492, y: 220, w: 170, h: 40 };
  }
  Renderer.prototype.load = function (fileName) {
    if (this.imagePromises[fileName]) return this.imagePromises[fileName];
    var self = this;
    this.imagePromises[fileName] = new Promise(function (resolve) {
      var image = new Image();
      self.images[fileName] = image;
      image.onload = function () { resolve(true); };
      image.onerror = function () { resolve(false); };
      image.src = "assets/svg/" + fileName;
    });
    return this.imagePromises[fileName];
  };
  Renderer.prototype.preload = function (fileNames) {
    var self = this;
    var unique = [];
    fileNames.forEach(function (name) { if (name && unique.indexOf(name) < 0) unique.push(name); });
    return Promise.all(unique.map(function (name) { return self.load(name); }));
  };
  Renderer.prototype.snackFile = function (snackId) {
    var snack = this.db.snacks[snackId];
    return snack ? snack.svg : "snack_chips.svg";
  };
  Renderer.prototype.customerFile = function (customerId) {
    var customer = this.db.customers[customerId];
    return customer ? customer.avatar : "customer_normal.svg";
  };
  Renderer.prototype.image = function (fileName) {
    var image = this.images[fileName];
    return image && image.complete && image.naturalWidth > 0 ? image : null;
  };
  Renderer.prototype.drawAsset = function (fileName, x, y, w, h) {
    var image = this.image(fileName);
    if (image) this.ctx.drawImage(image, x, y, w, h);
  };
  Renderer.prototype.localToGlobal = function (p) { return { x: p.x * TABLE_SCALE, y: TABLE_Y + p.y * TABLE_SCALE }; };
  Renderer.prototype.globalToLocal = function (p) { return { x: p.x / TABLE_SCALE, y: (p.y - TABLE_Y) / TABLE_SCALE }; };
  Renderer.prototype.eventPoint = function (event) {
    var rect = this.canvas.getBoundingClientRect();
    return { x: (event.clientX - rect.left) * 720 / rect.width, y: (event.clientY - rect.top) * 1280 / rect.height };
  };
  Renderer.prototype.handleEvent = function (event, game) {
    if (event.type === "batch_started") {
      this.displayBatch = event.items.slice();
      this.flightDuration = event.duration;
      var theoretical = 0;
      event.items.forEach(function (item) { theoretical += item.weight; });
      this.ledValue = theoretical; this.ledTarget = theoretical;
    } else if (event.type === "group_weighed") {
      this.displayBatch = event.items.slice();
      this.ledValue = 0; this.ledTarget = event.weight; this.ledElapsed = 0;
      this.ledDuration = game.cfg.weigh_anim_time;
      this.priceTag = { weight: event.weight, price: event.price.total };
      this.priceTagTimer = 1.05;
      this.bagPulse = 0.7;
      this.floaters.push({ text: "+" + event.price.total + " 金币", x: 574, y: 660, life: 1.0, color: "#a83a2c" });
    } else if (event.type === "snack_zoned") {
      if (game.combo.combo >= 3) this.comboPulse = 0.35;
    } else if (event.type === "customer_started") {
      this.displayBatch = null; this.ledValue = 0; this.ledTarget = 0;
    }
  };
  Renderer.prototype.advance = function (delta) {
    if (this.ledElapsed < this.ledDuration) {
      this.ledElapsed = Math.min(this.ledDuration, this.ledElapsed + delta);
      var t = this.ledDuration ? this.ledElapsed / this.ledDuration : 1;
      this.ledValue = Math.round(this.ledTarget * (1 - Math.pow(1 - t, 3)));
    }
    this.priceTagTimer = Math.max(0, this.priceTagTimer - delta);
    this.bagPulse = Math.max(0, this.bagPulse - delta);
    this.comboPulse = Math.max(0, this.comboPulse - delta);
    for (var i = this.floaters.length - 1; i >= 0; i -= 1) {
      this.floaters[i].life -= delta;
      this.floaters[i].y -= delta * 32;
      if (this.floaters[i].life <= 0) this.floaters.splice(i, 1);
    }
    var self = this;
    Object.keys(this.tapBounces).forEach(function (uid) {
      self.tapBounces[uid] -= delta;
      if (self.tapBounces[uid] <= 0) delete self.tapBounces[uid];
    });
  };
  Renderer.prototype.roundRect = function (x, y, w, h, radius) {
    var ctx = this.ctx;
    var r = Math.min(radius, w / 2, h / 2);
    ctx.beginPath(); ctx.moveTo(x + r, y); ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r); ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h); ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r); ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y); ctx.closePath();
  };
  Renderer.prototype.button = function (rect, text, active) {
    var ctx = this.ctx;
    ctx.save(); ctx.fillStyle = active ? "#c94f3d" : "#f5e6c8";
    this.roundRect(rect.x, rect.y, rect.w, rect.h, 9); ctx.fill();
    ctx.lineWidth = 3; ctx.strokeStyle = "#4a3525"; ctx.stroke();
    ctx.fillStyle = active ? "#fff7e7" : "#4a3525"; ctx.font = "bold 17px sans-serif";
    ctx.textAlign = "center"; ctx.textBaseline = "middle"; ctx.fillText(text, rect.x + rect.w / 2, rect.y + rect.h / 2);
    ctx.restore();
  };
  Renderer.prototype.render = function (game, drag) {
    var ctx = this.ctx;
    ctx.clearRect(0, 0, 720, 1280);
    this.drawAsset("bg_shop.svg", 0, 0, 720, 1280);
    if (!this.image("bg_shop.svg")) { ctx.fillStyle = "#efe0bc"; ctx.fillRect(0, 0, 720, 1280); }
    this.drawAsset("counter_top.svg", 0, 330, 720, 780);
    if (!this.image("counter_top.svg")) { ctx.fillStyle = "#b08954"; ctx.fillRect(0, 330, 720, 700); }
    this.drawAsset("cashier_aisle.svg", 0, 1024, 720, 256);
    this.drawCustomer(game);
    this.drawDevice(game);
    this.drawZones(game, drag);
    if (game.phase === "pouring") this.drawPour(game);
    else this.drawTableItems(game, drag);
    this.drawBatch(game);
    this.drawCashier(game);
    this.drawTop(game);
    this.drawPriceTag();
    this.drawFloaters();
  };
  Renderer.prototype.drawTop = function (game) {
    var ctx = this.ctx;
    ctx.save(); ctx.fillStyle = "rgba(255,247,231,.94)"; ctx.fillRect(0, 0, 720, 94);
    ctx.fillStyle = "#a83a2c"; ctx.font = "900 25px sans-serif"; ctx.textAlign = "left"; ctx.textBaseline = "middle";
    ctx.fillText("第 " + game.levelId + " 关", 18, 27);
    ctx.fillStyle = "#4a3525"; ctx.font = "bold 17px sans-serif";
    ctx.fillText("顾客 " + game.customerIndex + "/" + game.customersTotal + " · 已装袋 " + game.baggedItems + "/" + game.totalItems, 18, 63);
    ctx.fillStyle = "#d7c49f"; this.roundRect(184, 18, 224, 22, 11); ctx.fill();
    var patienceColor = game.patienceRatio() < 0.3 ? "#c94f3d" : "#5e7d5b";
    ctx.fillStyle = patienceColor; this.roundRect(184, 18, Math.max(8, 224 * game.patienceRatio()), 22, 11); ctx.fill();
    ctx.fillStyle = "#4a3525"; ctx.font = "13px sans-serif"; ctx.textAlign = "center";
    ctx.fillText(game.patienceTotal > 0 ? Math.ceil(game.patienceLeft) + " 秒" : "耐心不限", 296, 29);
    var comboScale = 1 + this.comboPulse * 0.8;
    ctx.translate(474, 53); ctx.scale(comboScale, comboScale);
    ctx.fillStyle = game.combo.combo >= 3 ? "#c94f3d" : "#527c89"; ctx.font = "900 22px sans-serif";
    ctx.fillText("连击 ×" + game.combo.combo, 0, 0); ctx.restore();
    this.button(this.magnetRect, "吸附 " + game.magnetCharges, false);
    this.button(this.pauseRect, "Ⅱ", false);
  };
  Renderer.prototype.drawCustomer = function (game) {
    var ctx = this.ctx;
    var customer = game.currentCustomer();
    this.drawAsset(this.customerFile(game.currentCustomerId()), 8, 106, 164, 191);
    ctx.save(); ctx.fillStyle = "#4a3525"; ctx.font = "bold 18px sans-serif"; ctx.textAlign = "left";
    ctx.fillText(customer.name || "顾客", 188, 124);
    ctx.fillStyle = "#765e45"; ctx.font = "14px sans-serif"; ctx.fillText(customer.personality || "来买点零食", 188, 148);
    var line = customer.lines && customer.lines.length ? customer.lines[(game.customerIndex - 1) % customer.lines.length] : "麻烦帮我称一下。";
    ctx.fillStyle = "rgba(255,247,231,.92)"; this.roundRect(184, 162, 250, 66, 14); ctx.fill();
    ctx.fillStyle = "#4a3525"; ctx.font = "15px sans-serif";
    this.fitText(line, 198, 187, 222, 15);
    var upcoming = game.upcomingCustomers();
    for (var i = 0; i < Math.min(3, upcoming.length); i += 1) {
      this.drawAsset(this.customerFile(upcoming[i]), 190 + i * 76, 238, 52, 61);
    }
    ctx.restore();
  };
  Renderer.prototype.fitText = function (text, x, y, maxWidth) {
    var ctx = this.ctx;
    var value = String(text);
    while (ctx.measureText(value).width > maxWidth && value.length > 2) value = value.slice(0, -1);
    if (value !== String(text)) value = value.slice(0, -1) + "…";
    ctx.fillText(value, x, y);
  };
  Renderer.prototype.drawDevice = function (game) {
    var ctx = this.ctx;
    this.drawAsset("scale_stand.svg", 548, 260, 58, 58);
    this.drawAsset("scale_platform.svg", 452, 282, 250, 350);
    this.drawAsset("pos_screen.svg", 480, 138, 194, 132);
    if (!this.image("scale_platform.svg")) { ctx.fillStyle = "#7a9b76"; ctx.fillRect(466, 320, 220, 290); }
    ctx.save(); ctx.fillStyle = "#b8f5d3"; ctx.font = "bold 26px monospace"; ctx.textAlign = "center";
    ctx.fillText(Math.round(this.ledValue) + " g", 558, 564);
    ctx.font = "13px monospace"; ctx.fillText(game.auto ? "FIFO AUTO" : "FIFO MANUAL", 577, 187);
    ctx.fillStyle = "#4a3525"; ctx.font = "bold 15px sans-serif"; ctx.fillText("收银显示屏", 577, 153); ctx.restore();
    this.button(this.modeRect, game.auto ? "自动结算：开" : "自动结算：关", game.auto);
    ctx.save(); ctx.fillStyle = "#4a3525"; ctx.font = "bold 16px sans-serif"; ctx.textAlign = "center";
    ctx.fillText(game.auto ? "同款集齐自动称重" : "双击画面开始称重", 580, 660);
    ctx.font = "14px sans-serif"; ctx.fillText("完整批次串行入袋", 580, 684); ctx.restore();
  };
  Renderer.prototype.zoneLabel = function (game, index) {
    var section = game.sections[index];
    if (game.activeZone === index) return "称重中…";
    if (game.queue.indexOf(index) >= 0) return game.auto ? "已集齐 · 等待称重" : "已集齐 · 双击结算";
    if (!section.length) return "拖入同款";
    var snackId = section[0].snack;
    for (var i = 0; i < section.length; i += 1) if (section[i].snack !== snackId) return "混放 " + section.length + " 件 · 点击退回";
    var snack = this.db.snacks[snackId];
    return (snack ? snack.name : snackId) + " " + section.length + "/" + game.snackTotal(snackId);
  };
  Renderer.prototype.drawZones = function (game, drag) {
    var ctx = this.ctx;
    ctx.save(); ctx.translate(0, TABLE_Y); ctx.scale(TABLE_SCALE, TABLE_SCALE);
    for (var z = 0; z < 4; z += 1) {
      var r = SDD.ZONE_RECTS[z];
      var activeDrop = drag && drag.zone === z;
      ctx.save(); ctx.fillStyle = COLORS[z]; ctx.globalAlpha = activeDrop ? 0.38 : game.isZoneLocked(z) ? 0.26 : 0.15;
      ctx.beginPath(); ctx.ellipse(r.x + r.w / 2, r.y + r.h / 2, r.w / 2, r.h / 2, 0, 0, Math.PI * 2); ctx.fill();
      if (activeDrop) { ctx.globalAlpha = 0.8; ctx.lineWidth = 5; ctx.strokeStyle = COLORS[z]; ctx.stroke(); }
      ctx.globalAlpha = 1; ctx.fillStyle = "#4a3525"; ctx.font = "bold 16px sans-serif"; ctx.textAlign = "center";
      this.fitText(this.zoneLabel(game, z), r.x + r.w / 2, r.y + r.h - 17, r.w - 16, 16);
      ctx.restore();
      var section = game.sections[z];
      for (var i = 0; i < section.length; i += 1) {
        var p = SDD.zoneItemPoint(z, i);
        this.drawSnack(section[i], p.x, p.y, 0.54, false, true);
      }
    }
    ctx.restore();
  };
  Renderer.prototype.drawTableItems = function (game, drag) {
    var ctx = this.ctx;
    ctx.save(); ctx.translate(0, TABLE_Y); ctx.scale(TABLE_SCALE, TABLE_SCALE);
    var sorted = game.basket.sorted();
    var hintUid = game.hintUid();
    for (var i = 0; i < sorted.length; i += 1) {
      var item = sorted[i];
      if (item.picked) continue;
      if (item.uid === hintUid) {
        ctx.save(); ctx.strokeStyle = "rgba(255,247,231,.85)"; ctx.lineWidth = 7;
        ctx.beginPath(); ctx.arc(item.x, item.y, 72 + Math.sin(game.elapsed * 5) * 5, 0, Math.PI * 2); ctx.stroke(); ctx.restore();
      }
      var bounceTime = this.tapBounces[item.uid] || 0;
      var bounceY = bounceTime > 0 ? -Math.sin((0.22 - bounceTime) / 0.22 * Math.PI) * 12 : 0;
      this.drawSnack(item, item.x, item.y + bounceY, drag && drag.uid === item.uid && drag.dragging ? 1.07 : 1, drag && drag.uid === item.uid, false);
    }
    ctx.restore();
  };
  Renderer.prototype.drawSnack = function (item, x, y, scale, dragging, inZone) {
    var ctx = this.ctx;
    var fileName = item.blind && !item.picked ? "blind.svg" : item.size === 2 ? "gift.svg" : this.snackFile(item.snack);
    var size = SDD.itemSize(item);
    if (inZone) { size = item.size === 2 ? { w: 112, h: 92 } : { w: 100, h: 88 }; }
    var snack = this.db.snacks[item.snack] || { color: "#c8a06a", accent: "#c94f3d", name: "零食" };
    ctx.save(); ctx.translate(x, y); ctx.rotate(item.rotation || 0); ctx.scale(scale, scale);
    ctx.shadowColor = "rgba(74,53,37,.30)"; ctx.shadowBlur = dragging ? 10 : 3;
    ctx.shadowOffsetX = dragging ? 9 : 5; ctx.shadowOffsetY = dragging ? 12 : 7;
    var image = this.image(fileName);
    if (image) ctx.drawImage(image, -size.w / 2, -size.h / 2, size.w, size.h);
    else {
      ctx.shadowColor = "transparent"; ctx.fillStyle = snack.color;
      this.roundRect(-size.w / 2, -size.h / 2, size.w, size.h * 0.88, 13); ctx.fill();
      ctx.lineWidth = 4; ctx.strokeStyle = "#4a3525"; ctx.stroke();
      ctx.fillStyle = snack.accent; ctx.fillRect(-size.w / 2 + 8, -12, size.w - 16, 30);
      ctx.fillStyle = "#fff7e7"; ctx.font = "bold 17px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.fillText(snack.name, 0, 3);
    }
    ctx.shadowColor = "transparent";
    if (item.size === 2) {
      ctx.fillStyle = "#c94f3d"; ctx.beginPath(); ctx.arc(size.w / 2 - 12, -size.h / 2 + 12, 18, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = "#fff7e7"; ctx.font = "bold 18px sans-serif"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.fillText(snack.name.charAt(0), size.w / 2 - 12, -size.h / 2 + 12);
    }
    ctx.restore();
  };
  Renderer.prototype.drawPour = function (game) {
    var ctx = this.ctx;
    var entry = SDD.clamp(game.pourElapsed / 0.55, 0, 1);
    var basketX = -270 + entry * 120;
    ctx.save(); ctx.globalAlpha = game.pourElapsed > game.pourDuration - 0.22 ? Math.max(0, (game.pourDuration - game.pourElapsed) / 0.22) : 1;
    this.drawAsset("basket.svg", basketX, 566, 270, 342);
    if (!this.image("basket.svg")) { ctx.fillStyle = "#8f653d"; ctx.fillRect(basketX, 566, 270, 342); }
    ctx.restore();
    var count = game.basket.items.length;
    var stagger = Math.min(0.30, 0.98 / Math.max(1, count - 1));
    for (var i = 0; i < count; i += 1) {
      var item = game.basket.items[i];
      var t = (game.pourElapsed - 1.32 - i * stagger) / 0.58;
      if (t <= 0) continue;
      t = SDD.clamp(t, 0, 1);
      var end = this.localToGlobal(item);
      var start = { x: 18, y: 655 + (i % 5) * 24 };
      var eased = 1 - Math.pow(1 - t, 2);
      var x = start.x + (end.x - start.x) * eased;
      var y = start.y + (end.y - start.y) * eased - Math.sin(Math.PI * t) * 115;
      var globalItem = item;
      ctx.save(); ctx.translate(x, y); ctx.rotate((1 - t) * (i % 2 ? 2 : -2)); ctx.translate(-x, -y);
      this.drawSnack(globalItem, x, y, TABLE_SCALE, false, false);
      ctx.restore();
    }
    ctx.save(); ctx.fillStyle = "rgba(74,53,37,.78)"; this.roundRect(190, 850, 340, 48, 20); ctx.fill();
    ctx.fillStyle = "#fff7e7"; ctx.font = "bold 19px sans-serif"; ctx.textAlign = "center";
    ctx.fillText("零食撒落中 · 全部落地后开始分拣", 360, 880); ctx.restore();
  };
  Renderer.prototype.drawBatch = function (game) {
    if (!this.displayBatch || !this.displayBatch.length) return;
    var items = this.displayBatch;
    if (game.batchPhase === "flying" && game.activeZone >= 0) {
      var start = this.localToGlobal(SDD.zoneCenter(game.activeZone));
      for (var i = 0; i < items.length; i += 1) {
        var delay = i * 0.025;
        var t = SDD.clamp((game.batchTimer <= this.flightDuration ? this.flightDuration - game.batchTimer - delay : 0) / Math.max(0.1, this.flightDuration - delay), 0, 1);
        var end = { x: 535 + (i % 3) * 40, y: 390 + Math.floor(i / 3) * 42 };
        var x = start.x + (end.x - start.x) * t;
        var y = start.y + (end.y - start.y) * t - Math.sin(t * Math.PI) * 55;
        this.drawSnack(items[i], x, y, 0.45, false, false);
      }
    } else if (game.batchPhase === "cooldown") {
      for (var j = 0; j < items.length; j += 1) {
        this.drawSnack(items[j], 520 + (j % 3) * 48, 385 + Math.floor(j / 3) * 52, 0.40, false, false);
      }
    }
  };
  Renderer.prototype.drawPriceTag = function () {
    if (!this.priceTag || this.priceTagTimer <= 0) return;
    var ctx = this.ctx;
    var fly = this.priceTagTimer < 0.30 ? 1 - this.priceTagTimer / 0.30 : 0;
    var x = 472 + (610 - 472) * fly;
    var y = 702 + (1130 - 702) * fly;
    ctx.save(); ctx.globalAlpha = Math.min(1, this.priceTagTimer * 3); ctx.translate(x, y); ctx.rotate(-0.04 + fly * 0.2);
    ctx.fillStyle = "#fffdf5"; ctx.fillRect(0, 0, 190, 70); ctx.lineWidth = 3; ctx.strokeStyle = "#4a3525"; ctx.strokeRect(0, 0, 190, 70);
    ctx.fillStyle = "#4a3525"; ctx.font = "bold 22px monospace"; ctx.textAlign = "center";
    ctx.fillText(this.priceTag.weight + "g  ¥" + this.priceTag.price, 95, 32);
    ctx.font = "12px monospace"; ctx.fillText("SNACK DING DONG", 95, 54); ctx.restore();
  };
  Renderer.prototype.drawCashier = function (game) {
    var ctx = this.ctx;
    var bounce = this.bagPulse > 0 ? -Math.sin(this.bagPulse * 18) * 7 : 0;
    this.drawAsset("cashier_body.svg", 246, 1036 + bounce, 220, 230);
    if (this.bagPulse > 0) this.drawAsset("cashier_arm.svg", 382, 1090 + bounce, 104, 100);
    var bagScale = 1 + this.bagPulse * 0.12;
    ctx.save(); ctx.translate(625, 1152); ctx.scale(bagScale, bagScale);
    this.drawAsset("bag.svg", -54, -72, 108, 138); ctx.restore();
    ctx.save(); ctx.fillStyle = "rgba(255,247,231,.88)"; this.roundRect(520, 1220, 178, 38, 12); ctx.fill();
    ctx.fillStyle = "#4a3525"; ctx.font = "bold 15px sans-serif"; ctx.textAlign = "center";
    ctx.fillText("装袋 " + game.baggedItems + "/" + game.totalItems + " · ¥" + game.coinsEarned, 609, 1244);
    ctx.fillStyle = "rgba(245,230,200,.65)"; ctx.font = "15px sans-serif"; ctx.fillText("收银员过道", 360, 1048); ctx.restore();
  };
  Renderer.prototype.drawFloaters = function () {
    var ctx = this.ctx;
    ctx.save(); ctx.textAlign = "center"; ctx.font = "bold 22px sans-serif";
    for (var i = 0; i < this.floaters.length; i += 1) {
      var floater = this.floaters[i]; ctx.globalAlpha = Math.min(1, floater.life * 2); ctx.fillStyle = floater.color;
      ctx.fillText(floater.text, floater.x, floater.y);
    }
    ctx.restore();
  };
  Renderer.prototype.hitZoneItem = function (game, p) {
    for (var z = 0; z < 4; z += 1) {
      var section = game.sections[z];
      for (var i = section.length - 1; i >= 0; i -= 1) {
        var center = SDD.zoneItemPoint(z, i);
        var size = section[i].size === 2 ? { w: 65, h: 54 } : { w: 58, h: 51 };
        if (Math.abs(p.x - center.x) <= size.w / 2 + 8 && Math.abs(p.y - center.y) <= size.h / 2 + 8) return { zone: z, uid: section[i].uid };
      }
    }
    return null;
  };

  SDD.Renderer = Renderer;
  SDD.TABLE_SCALE = TABLE_SCALE;
  SDD.TABLE_Y = TABLE_Y;
}());
