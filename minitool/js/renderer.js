(function () {
  "use strict";
  var SDD = window.SDD = window.SDD || {};
  var TABLE_SCALE = 0.78;
  var TABLE_Y = 400;

  function Renderer(canvas, db) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.db = db;
    this.images = {};
    this.imagePromises = {};
    this.flight = null;
    this.scaleBatch = null;
    this.scaleBatchTimer = 0;
    this.ledValue = 0;
    this.ledStart = 0;
    this.ledTarget = 0;
    this.ledElapsed = 0;
    this.ledDuration = 0.4;
    this.priceTags = [];
    this.bagPulse = 0;
    this.comboPulse = 0;
    this.floaters = [];
    this.tapBounces = {};
    this.pauseRect = { x: 642, y: 16, w: 62, h: 58 };
    this.magnetRect = { x: 542, y: 16, w: 88, h: 58 };
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
      this.flight = { items: event.items.slice(), starts: event.items.map(function (item) { return { x: item.x, y: item.y }; }),
        elapsed: 0, duration: event.duration, flightTime: event.flightTime, stagger: event.stagger };
      var theoretical = 0;
      event.items.forEach(function (item) { theoretical += item.weight; });
      this.ledStart = this.ledValue; this.ledTarget = theoretical; this.ledElapsed = 0; this.ledDuration = event.duration;
    } else if (event.type === "group_weighed") {
      this.flight = null;
      this.scaleBatch = event.items.slice(); this.scaleBatchTimer = 0.16;
      this.ledStart = this.ledValue; this.ledTarget = event.weight; this.ledElapsed = 0;
      this.ledDuration = game.cfg.weigh_anim_time;
      this.priceTags.push({ weight: event.weight, price: event.price.total, life: 0.62, maxLife: 0.62 });
      this.bagPulse = 0.28;
      this.floaters.push({ text: "+" + event.price.total + " 金币", x: 574, y: 660, life: 0.72, color: "#a83a2c" });
    } else if (event.type === "snacks_gathered") {
      if (event.combo >= 3) this.comboPulse = 0.22;
    } else if (event.type === "customer_started" && event.index === 1) {
      this.flight = null; this.scaleBatch = null; this.scaleBatchTimer = 0;
      this.priceTags = []; this.floaters = [];
      this.bagPulse = 0; this.comboPulse = 0; this.tapBounces = {};
      this.ledValue = 0; this.ledStart = 0; this.ledTarget = 0; this.ledElapsed = 0;
    }
  };
  Renderer.prototype.advance = function (delta) {
    if (this.flight) this.flight.elapsed += delta;
    this.scaleBatchTimer = Math.max(0, this.scaleBatchTimer - delta);
    if (this.ledElapsed < this.ledDuration) {
      this.ledElapsed = Math.min(this.ledDuration, this.ledElapsed + delta);
      var t = this.ledDuration ? this.ledElapsed / this.ledDuration : 1;
      this.ledValue = Math.round(this.ledStart + (this.ledTarget - this.ledStart) * (1 - Math.pow(1 - t, 3)));
    }
    for (var p = this.priceTags.length - 1; p >= 0; p -= 1) {
      this.priceTags[p].life -= delta;
      if (this.priceTags[p].life <= 0) this.priceTags.splice(p, 1);
    }
    this.bagPulse = Math.max(0, this.bagPulse - delta);
    this.comboPulse = Math.max(0, this.comboPulse - delta);
    for (var i = this.floaters.length - 1; i >= 0; i -= 1) {
      this.floaters[i].life -= delta;
      this.floaters[i].y -= delta * 42;
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
    this.drawDevice();
    if (game.phase === "pouring") this.drawPour(game);
    else this.drawTableItems(game, drag);
    this.drawScaleBatch();
    this.drawBatch(game);
    this.drawCashier(game);
    this.drawTop(game);
    this.drawPriceTags();
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
  Renderer.prototype.drawDevice = function () {
    var ctx = this.ctx;
    this.drawAsset("scale_stand.svg", 548, 260, 58, 58);
    this.drawAsset("scale_platform.svg", 452, 282, 250, 350);
    this.drawAsset("pos_screen.svg", 480, 138, 194, 132);
    if (!this.image("scale_platform.svg")) { ctx.fillStyle = "#7a9b76"; ctx.fillRect(466, 320, 220, 290); }
    ctx.save(); ctx.fillStyle = "#b8f5d3"; ctx.font = "bold 26px monospace"; ctx.textAlign = "center";
    ctx.fillText(Math.round(this.ledValue) + " g", 558, 564);
    ctx.font = "13px monospace"; ctx.fillText("CLUSTER AUTO", 577, 187);
    ctx.fillStyle = "#4a3525"; ctx.font = "bold 15px sans-serif"; ctx.fillText("收银显示屏", 577, 153);
    ctx.font = "bold 16px sans-serif"; ctx.fillText("聚堆自动称重", 577, 238); ctx.restore();
    ctx.save(); ctx.fillStyle = "#4a3525"; ctx.font = "bold 16px sans-serif"; ctx.textAlign = "center";
    ctx.fillText("同款聚成堆 · 异款留空隙", 580, 660);
    ctx.font = "14px sans-serif"; ctx.fillText("整理完成立即连续入秤", 580, 684); ctx.restore();
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
      var bounceY = bounceTime > 0 ? -Math.sin((0.14 - bounceTime) / 0.14 * Math.PI) * 9 : 0;
      this.drawSnack(item, item.x, item.y + bounceY, drag && drag.uid === item.uid && drag.dragging ? 1.07 : 1, drag && drag.uid === item.uid);
    }
    ctx.restore();
  };
  Renderer.prototype.drawSnack = function (item, x, y, scale, dragging) {
    var ctx = this.ctx;
    var fileName = item.blind && !item.revealed && !item.picked ? "blind.svg" : item.size === 2 ? "gift.svg" : this.snackFile(item.snack);
    var size = SDD.itemSize(item);
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
    var count = game.basket.items.length;
    var timing = game.pourTiming || SDD.pourTiming(count);
    var entry = SDD.clamp(game.pourElapsed / timing.entry, 0, 1);
    var basketX = -270 + (1 - Math.pow(1 - entry, 3)) * 120;
    ctx.save(); ctx.globalAlpha = game.pourElapsed > game.pourDuration - timing.exit ? Math.max(0, (game.pourDuration - game.pourElapsed) / timing.exit) : 1;
    this.drawAsset("basket.svg", basketX, 566, 270, 342);
    if (!this.image("basket.svg")) { ctx.fillStyle = "#8f653d"; ctx.fillRect(basketX, 566, 270, 342); }
    ctx.restore();
    for (var i = 0; i < count; i += 1) {
      var item = game.basket.items[i];
      var t = (game.pourElapsed - timing.first - i * timing.stagger) / timing.flight;
      if (t <= 0) continue;
      t = SDD.clamp(t, 0, 1);
      var end = this.localToGlobal(item);
      var start = { x: 18, y: 655 + (i % 5) * 24 };
      var eased = 1 - Math.pow(1 - t, 3);
      var x = start.x + (end.x - start.x) * eased;
      var y = start.y + (end.y - start.y) * eased - Math.sin(Math.PI * t) * 90;
      ctx.save(); ctx.translate(x, y); ctx.rotate((1 - eased) * (i % 2 ? 1.4 : -1.4)); ctx.translate(-x, -y);
      this.drawSnack(item, x, y, TABLE_SCALE, false);
      ctx.restore();
    }
    ctx.save(); ctx.fillStyle = "rgba(74,53,37,.78)"; this.roundRect(190, 850, 340, 48, 20); ctx.fill();
    ctx.fillStyle = "#fff7e7"; ctx.font = "bold 19px sans-serif"; ctx.textAlign = "center";
    ctx.fillText("零食撒落中 · 落地后自由聚堆", 360, 880); ctx.restore();
  };
  Renderer.prototype.scalePoint = function (index) {
    return { x: 520 + (index % 3) * 48, y: 385 + Math.floor(index / 3) * 52 };
  };
  Renderer.prototype.drawScaleBatch = function () {
    if (!this.scaleBatch || !this.scaleBatch.length || this.scaleBatchTimer <= 0) return;
    var ctx = this.ctx;
    ctx.save(); ctx.globalAlpha = SDD.clamp(this.scaleBatchTimer / 0.16, 0, 1);
    for (var i = 0; i < this.scaleBatch.length; i += 1) {
      var p = this.scalePoint(i);
      this.drawSnack(this.scaleBatch[i], p.x, p.y, 0.42, false);
    }
    ctx.restore();
  };
  Renderer.prototype.drawBatch = function () {
    if (!this.flight || !this.flight.items.length) return;
    var ctx = this.ctx;
    for (var i = 0; i < this.flight.items.length; i += 1) {
      var t = SDD.clamp((this.flight.elapsed - i * this.flight.stagger) / this.flight.flightTime, 0, 1);
      var eased = 1 - Math.pow(1 - t, 3);
      var start = this.localToGlobal(this.flight.starts[i]);
      var end = this.scalePoint(i);
      var x = start.x + (end.x - start.x) * eased;
      var y = start.y + (end.y - start.y) * eased - Math.sin(t * Math.PI) * 58;
      ctx.save(); ctx.translate(x, y); ctx.rotate((1 - eased) * (i % 2 ? 0.35 : -0.35)); ctx.translate(-x, -y);
      this.drawSnack(this.flight.items[i], x, y, TABLE_SCALE + (0.42 - TABLE_SCALE) * eased, false);
      ctx.restore();
    }
  };
  Renderer.prototype.drawPriceTags = function () {
    var ctx = this.ctx;
    for (var i = 0; i < this.priceTags.length; i += 1) {
      var tag = this.priceTags[i];
      var age = tag.maxLife - tag.life;
      var enter = SDD.clamp(age / 0.08, 0, 1);
      var fly = SDD.clamp((age - 0.20) / 0.30, 0, 1);
      var x = 472 + (610 - 472) * fly + i * 8;
      var y = 702 + (1130 - 702) * fly - (1 - enter) * 20 - i * 12;
      ctx.save(); ctx.globalAlpha = Math.min(enter, SDD.clamp(tag.life / 0.12, 0, 1));
      ctx.translate(x, y); ctx.rotate(-0.04 + fly * 0.2); ctx.scale(0.85 + enter * 0.15, 0.85 + enter * 0.15);
      ctx.fillStyle = "#fffdf5"; ctx.fillRect(0, 0, 190, 70); ctx.lineWidth = 3; ctx.strokeStyle = "#4a3525"; ctx.strokeRect(0, 0, 190, 70);
      ctx.fillStyle = "#4a3525"; ctx.font = "bold 22px monospace"; ctx.textAlign = "center";
      ctx.fillText(tag.weight + "g  ¥" + tag.price, 95, 32);
      ctx.font = "12px monospace"; ctx.fillText("SNACK DING DONG", 95, 54); ctx.restore();
    }
  };
  Renderer.prototype.drawCashier = function (game) {
    var ctx = this.ctx;
    var pulse = this.bagPulse > 0 ? Math.sin((1 - this.bagPulse / 0.28) * Math.PI) : 0;
    var bounce = -pulse * 8;
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

  SDD.Renderer = Renderer;
  SDD.TABLE_SCALE = TABLE_SCALE;
  SDD.TABLE_Y = TABLE_Y;
}());
