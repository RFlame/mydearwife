(function () {
  "use strict";
  var SDD = window.SDD = window.SDD || {};

  function RNG(seed) {
    this.state = (seed >>> 0) || 0x6d2b79f5;
  }
  RNG.prototype.next = function () {
    var t = this.state += 0x6d2b79f5;
    t = Math.imul(t ^ t >>> 15, t | 1);
    t ^= t + Math.imul(t ^ t >>> 7, t | 61);
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
  RNG.prototype.range = function (min, max) { return min + (max - min) * this.next(); };
  RNG.prototype.int = function (min, max) { return Math.floor(this.range(min, max + 1)); };
  RNG.prototype.pick = function (items) { return items[this.int(0, items.length - 1)]; };
  RNG.prototype.shuffle = function (items) {
    var result = items.slice();
    for (var i = result.length - 1; i > 0; i -= 1) {
      var j = this.int(0, i);
      var temp = result[i]; result[i] = result[j]; result[j] = temp;
    }
    return result;
  };

  function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }
  function point(x, y) { return { x: x, y: y }; }

  var TABLE_BOUNDS = { x: 24, y: 60, w: 552, h: 740 };
  var DRAG_BOUNDS = { x: 16, y: -92, w: 888, h: 892 };
  var SCALE_BLOCK = { x: 580, y: -152, w: 320, h: 450 };
  var SCALE_GAP = 4;
  var ZONE_RECTS = [
    { x: 44, y: -48, w: 184, h: 176 },
    { x: 372, y: -48, w: 184, h: 176 },
    { x: 44, y: 140, w: 184, h: 176 },
    { x: 372, y: 140, w: 184, h: 176 }
  ];
  var ZONE_OFFSETS = [
    point(0, 0), point(-26, -18), point(26, -18), point(-28, 18), point(28, 18),
    point(0, -30), point(0, 30), point(-38, 0), point(38, 0), point(-16, 0),
    point(16, 0), point(0, 14)
  ];

  function itemSize(item) {
    return item.size === 2 ? { w: 152, h: 120 } : { w: 120, h: 104 };
  }
  function cornersAt(item, x, y) {
    var size = itemSize(item);
    var hw = size.w / 2;
    var hh = size.h / 2;
    var angle = item.rotation || 0;
    var c = Math.cos(angle);
    var s = Math.sin(angle);
    var local = [point(-hw, -hh), point(hw, -hh), point(hw, hh), point(-hw, hh)];
    var result = [];
    for (var i = 0; i < local.length; i += 1) {
      result.push(point(x + local[i].x * c - local[i].y * s, y + local[i].x * s + local[i].y * c));
    }
    return result;
  }
  function pointInPolygon(p, polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i, i += 1) {
      var a = polygon[i]; var b = polygon[j];
      var crosses = ((a.y > p.y) !== (b.y > p.y)) &&
        p.x < (b.x - a.x) * (p.y - a.y) / ((b.y - a.y) || 0.00001) + a.x;
      if (crosses) inside = !inside;
    }
    return inside;
  }
  function polygonsIntersect(a, b) {
    var polygons = [a, b];
    for (var p = 0; p < polygons.length; p += 1) {
      var polygon = polygons[p];
      for (var i = 0; i < polygon.length; i += 1) {
        var start = polygon[i]; var end = polygon[(i + 1) % polygon.length];
        var nx = -(end.y - start.y); var ny = end.x - start.x;
        var minA = Infinity; var maxA = -Infinity; var minB = Infinity; var maxB = -Infinity;
        for (var j = 0; j < a.length; j += 1) {
          var pa = a[j].x * nx + a[j].y * ny; minA = Math.min(minA, pa); maxA = Math.max(maxA, pa);
        }
        for (var k = 0; k < b.length; k += 1) {
          var pb = b[k].x * nx + b[k].y * ny; minB = Math.min(minB, pb); maxB = Math.max(maxB, pb);
        }
        if (maxA <= minB || maxB <= minA) return false;
      }
    }
    return true;
  }

  function Basket(items) { this.items = items || []; }
  Basket.prototype.byUid = function (uid) {
    for (var i = 0; i < this.items.length; i += 1) if (this.items[i].uid === uid) return this.items[i];
    return null;
  };
  Basket.prototype.remaining = function () {
    var count = 0;
    for (var i = 0; i < this.items.length; i += 1) if (!this.items[i].picked) count += 1;
    return count;
  };
  Basket.prototype.sorted = function () {
    return this.items.slice().sort(function (a, b) { return a.z - b.z || a.uid - b.uid; });
  };
  Basket.prototype.hitTest = function (p) {
    var sorted = this.sorted();
    for (var i = sorted.length - 1; i >= 0; i -= 1) {
      var item = sorted[i];
      if (!item.picked && pointInPolygon(p, cornersAt(item, item.x, item.y))) return item.uid;
    }
    return -1;
  };
  Basket.prototype.hitTestAssisted = function (p, padding) {
    var exact = this.hitTest(p);
    if (exact > 0) return exact;
    var pad = typeof padding === "number" ? padding : 14;
    var sorted = this.sorted();
    for (var i = sorted.length - 1; i >= 0; i -= 1) {
      var item = sorted[i];
      if (item.picked || !this.canPick(item.uid)) continue;
      var angle = -(item.rotation || 0);
      var dx = p.x - item.x; var dy = p.y - item.y;
      var lx = dx * Math.cos(angle) - dy * Math.sin(angle);
      var ly = dx * Math.sin(angle) + dy * Math.cos(angle);
      var size = itemSize(item);
      if (Math.abs(lx) <= size.w / 2 + pad && Math.abs(ly) <= size.h / 2 + pad) return item.uid;
    }
    return -1;
  };
  Basket.prototype.exposure = function (uid) {
    var item = this.byUid(uid);
    if (!item || item.picked) return 0;
    var size = itemSize(item);
    var exposed = 0; var total = 0;
    var angle = item.rotation || 0; var c = Math.cos(angle); var s = Math.sin(angle);
    for (var iy = 0; iy < 5; iy += 1) {
      for (var ix = 0; ix < 5; ix += 1) {
        var lx = -size.w / 2 + size.w * (ix + 0.5) / 5;
        var ly = -size.h / 2 + size.h * (iy + 0.5) / 5;
        var p = point(item.x + lx * c - ly * s, item.y + lx * s + ly * c);
        total += 1;
        if (this.hitTest(p) === uid) exposed += 1;
      }
    }
    return total ? exposed / total : 0;
  };
  Basket.prototype.canPick = function (uid) {
    var item = this.byUid(uid);
    return !!item && !item.picked && this.exposure(uid) >= 0.12;
  };
  Basket.prototype.exposedPoint = function (uid) {
    var item = this.byUid(uid);
    if (!item || item.picked) return null;
    var size = itemSize(item);
    var angle = item.rotation || 0; var c = Math.cos(angle); var s = Math.sin(angle);
    for (var iy = 0; iy < 9; iy += 1) {
      for (var ix = 0; ix < 9; ix += 1) {
        var lx = -size.w / 2 + size.w * (ix + 0.5) / 9;
        var ly = -size.h / 2 + size.h * (iy + 0.5) / 9;
        var p = point(item.x + lx * c - ly * s, item.y + lx * s + ly * c);
        if (this.hitTest(p) === uid) return p;
      }
    }
    return null;
  };
  Basket.prototype.pick = function (uid) {
    var item = this.byUid(uid);
    if (!item || item.picked) return false;
    item.picked = true;
    return true;
  };
  Basket.prototype.unpick = function (uid) {
    var item = this.byUid(uid);
    if (!item) return false;
    item.picked = false;
    return true;
  };
  Basket.prototype.bringToFront = function (uid) {
    var item = this.byUid(uid);
    if (!item) return;
    var maxZ = 0;
    for (var i = 0; i < this.items.length; i += 1) maxZ = Math.max(maxZ, this.items[i].z);
    item.z = maxZ + 1;
    var sorted = this.sorted();
    for (var j = 0; j < sorted.length; j += 1) sorted[j].z = j + 1;
  };
  Basket.prototype.clampPoint = function (item, x, y, bounds) {
    var rect = bounds || DRAG_BOUNDS;
    var corners = cornersAt(item, x, y);
    var minX = Infinity; var maxX = -Infinity; var minY = Infinity; var maxY = -Infinity;
    for (var i = 0; i < corners.length; i += 1) {
      minX = Math.min(minX, corners[i].x - x); maxX = Math.max(maxX, corners[i].x - x);
      minY = Math.min(minY, corners[i].y - y); maxY = Math.max(maxY, corners[i].y - y);
    }
    x = clamp(x, rect.x - minX, rect.x + rect.w - maxX);
    y = clamp(y, rect.y - minY, rect.y + rect.h - maxY);
    if (bounds) return point(x, y);

    var expanded = { x: SCALE_BLOCK.x - SCALE_GAP, y: SCALE_BLOCK.y - SCALE_GAP,
      w: SCALE_BLOCK.w + SCALE_GAP * 2, h: SCALE_BLOCK.h + SCALE_GAP * 2 };
    var blockCorners = [point(expanded.x, expanded.y), point(expanded.x + expanded.w, expanded.y),
      point(expanded.x + expanded.w, expanded.y + expanded.h), point(expanded.x, expanded.y + expanded.h)];
    if (polygonsIntersect(cornersAt(item, x, y), blockCorners)) {
      var candidates = [
        point(expanded.x - maxX, y),
        point(x, expanded.y - maxY),
        point(x, expanded.y + expanded.h - minY),
        point(expanded.x + expanded.w - minX, y)
      ];
      var best = null; var bestDistance = Infinity;
      for (var c = 0; c < candidates.length; c += 1) {
        var candidate = candidates[c];
        candidate.x = clamp(candidate.x, rect.x - minX, rect.x + rect.w - maxX);
        candidate.y = clamp(candidate.y, rect.y - minY, rect.y + rect.h - maxY);
        if (polygonsIntersect(cornersAt(item, candidate.x, candidate.y), blockCorners)) continue;
        var distance = Math.pow(candidate.x - x, 2) + Math.pow(candidate.y - y, 2);
        if (distance < bestDistance) { best = candidate; bestDistance = distance; }
      }
      if (best) { x = best.x; y = best.y; }
    }
    return point(x, y);
  };
  Basket.prototype.clampToTable = function (item) {
    var p = this.clampPoint(item, item.x, item.y, TABLE_BOUNDS);
    item.x = p.x; item.y = p.y;
  };
  Basket.prototype.moveItem = function (uid, p, bringToFront) {
    var item = this.byUid(uid);
    if (!item || item.picked) return false;
    if (bringToFront) this.bringToFront(uid);
    var clamped = this.clampPoint(item, p.x, p.y);
    item.x = clamped.x; item.y = clamped.y;
    return true;
  };
  Basket.prototype.accessibleSame = function (snackId) {
    var result = [];
    for (var i = 0; i < this.items.length; i += 1) {
      var item = this.items[i];
      if (!item.picked && item.snack === snackId && this.canPick(item.uid)) result.push(item);
    }
    result.sort(function (a, b) { return a.uid - b.uid; });
    return result;
  };

  function zoneAt(p) {
    for (var i = 0; i < ZONE_RECTS.length; i += 1) {
      var r = ZONE_RECTS[i];
      var nx = (p.x - (r.x + r.w / 2)) / (r.w / 2);
      var ny = (p.y - (r.y + r.h / 2)) / (r.h / 2);
      if (nx * nx + ny * ny <= 1) return i;
    }
    return -1;
  }
  function zoneCenter(index) {
    var r = ZONE_RECTS[index];
    return point(r.x + r.w / 2, r.y + r.h / 2);
  }
  function zoneItemPoint(index, itemIndex) {
    var center = zoneCenter(index);
    var offset = ZONE_OFFSETS[itemIndex % ZONE_OFFSETS.length];
    var ring = Math.floor(itemIndex / ZONE_OFFSETS.length);
    return point(center.x + offset.x + ring * 9, center.y + offset.y + ring * 8);
  }

  function generateBasket(cfg, snacks, rng) {
    var total = Math.max(1, cfg.items | 0);
    var pool = (cfg.pool || Object.keys(snacks)).slice();
    pool = rng.shuffle(pool);
    var kindCount = Math.max(1, Math.min(cfg.snack_kinds || 1, pool.length, total));
    var kinds = pool.slice(0, kindCount);
    var items = [];
    for (var i = 0; i < total; i += 1) {
      var snackId = kinds[i % kindCount];
      var snack = snacks[snackId];
      items.push({ uid: i + 1, snack: snackId, weight: snack.weight, size: 1,
        blind: false, picked: false, x: 300, y: 430, rotation: 0, z: i + 1 });
    }
    var features = cfg.features || [];
    if (features.indexOf("gift") >= 0) items[0].size = 2;
    if (features.indexOf("blind") >= 0) {
      var candidates = items.filter(function (item) { return item.size === 1; });
      candidates = rng.shuffle(candidates);
      for (var b = 0; b < Math.min(2, candidates.length); b += 1) candidates[b].blind = true;
    }
    var overlap = cfg.overlap || 0;
    var halfWidth = 500 * 0.5 * (1 - overlap * 0.28);
    var halfHeight = 480 * (1 - overlap * 0.42);
    for (var n = 0; n < items.length; n += 1) {
      var item = items[n];
      var p = point(300 + rng.range(-halfWidth, halfWidth), 430 + rng.range(-halfHeight * 0.5, halfHeight * 0.5));
      if (n > 0) {
        var anchorIndex = Math.max(0, n - 1 - rng.int(0, Math.min(4, n - 1)));
        var anchor = items[anchorIndex];
        var angle = rng.range(0, Math.PI * 2);
        var distance = rng.range(32, 94) * (1.12 - overlap * 0.30);
        var contact = point(anchor.x + Math.cos(angle) * distance, anchor.y + Math.sin(angle) * distance);
        p.x = p.x + (contact.x - p.x) * 0.72;
        p.y = p.y + (contact.y - p.y) * 0.72;
      }
      item.x = p.x; item.y = p.y;
      item.rotation = rng.range(-0.48, 0.48) * (1 + overlap * 0.4);
    }
    var basket = new Basket(items);
    for (var c = 0; c < items.length; c += 1) basket.clampToTable(items[c]);
    return basket;
  }

  SDD.RNG = RNG;
  SDD.Basket = Basket;
  SDD.generateBasket = generateBasket;
  SDD.zoneAt = zoneAt;
  SDD.zoneCenter = zoneCenter;
  SDD.zoneItemPoint = zoneItemPoint;
  SDD.itemSize = itemSize;
  SDD.cornersAt = cornersAt;
  SDD.TABLE_BOUNDS = TABLE_BOUNDS;
  SDD.DRAG_BOUNDS = DRAG_BOUNDS;
  SDD.SCALE_BLOCK = SCALE_BLOCK;
  SDD.ZONE_RECTS = ZONE_RECTS;
  SDD.clamp = clamp;
}());
