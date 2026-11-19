(function () {
  "use strict";
  var SDD = window.SDD = window.SDD || {};
  var STORAGE_KEY = "snack-dingdong-save-v1";

  function readBuildVersion(launchOptions) {
    var env = launchOptions && launchOptions.miniToolEnv;
    return Number(env && env.buildVersion) || 0;
  }
  function clientVersion(buildVersion) { return Math.floor(buildVersion / 1000); }
  function atLeast(buildVersion, minimum) { return clientVersion(buildVersion) >= minimum; }

  function PlatformBridge(root) {
    this.root = root || window;
    this.buildVersion = 0;
    this.storageAvailable = false;
    this.storageReason = "正在检查存档能力";
    this.windowInfo = null;
  }
  PlatformBridge.prototype.miniTool = function () {
    var xhs = this.root.xhs;
    return xhs && xhs.miniTool;
  };
  PlatformBridge.prototype.getBuildVersion = function () {
    var xhs = this.root.xhs;
    var syncVersion = readBuildVersion(xhs && xhs.launchOptions);
    if (syncVersion) return Promise.resolve(syncVersion);
    var miniTool = this.miniTool();
    if (!miniTool || typeof miniTool.getLaunchOptions !== "function") return Promise.resolve(0);
    try {
      return Promise.resolve(miniTool.getLaunchOptions()).then(function (options) {
        return readBuildVersion(options);
      }).catch(function () { return 0; });
    } catch (error) { return Promise.resolve(0); }
  };
  PlatformBridge.prototype.init = function () {
    var self = this;
    return this.getBuildVersion().then(function (version) {
      self.buildVersion = version;
      return self.readWindowInfo();
    });
  };
  PlatformBridge.prototype.load = function () {
    var self = this;
    var miniTool = this.miniTool();
    if (!atLeast(this.buildVersion, 9460)) {
      this.storageReason = "需要小红书 9.46+ 才能保存进度；当前仅保留到关闭前";
      return Promise.resolve({ save: null, available: false, reason: this.storageReason });
    }
    if (!miniTool || typeof miniTool.getStorage !== "function") {
      this.storageReason = "当前环境存储接口不可用；本次进度仅保留到关闭前";
      return Promise.resolve({ save: null, available: false, reason: this.storageReason });
    }
    try {
      return Promise.resolve(miniTool.getStorage({ key: STORAGE_KEY })).then(function (result) {
        self.storageAvailable = true;
        if (!result || result.data === null || typeof result.data === "undefined") {
          self.storageReason = "进度会保存到当前小工具";
          return { save: null, available: true, reason: self.storageReason };
        }
        try {
          var parsed = JSON.parse(result.data);
          self.storageReason = "已读取小工具存档";
          return { save: parsed, available: true, reason: self.storageReason };
        } catch (error) {
          self.storageReason = "存档内容无法读取，已使用新存档；下次保存将覆盖损坏内容";
          return { save: null, available: true, reason: self.storageReason };
        }
      }).catch(function () {
        self.storageAvailable = false;
        self.storageReason = "存档读取失败；本次进度仅保留到关闭前";
        return { save: null, available: false, reason: self.storageReason };
      });
    } catch (error) {
      this.storageReason = "存档读取失败；本次进度仅保留到关闭前";
      return Promise.resolve({ save: null, available: false, reason: this.storageReason });
    }
  };
  PlatformBridge.prototype.save = function (saveData) {
    var miniTool = this.miniTool();
    if (!this.storageAvailable || !miniTool || typeof miniTool.setStorage !== "function") return Promise.resolve(false);
    var serialized;
    try { serialized = JSON.stringify(saveData); } catch (error) { return Promise.resolve(false); }
    if (typeof serialized !== "string") return Promise.resolve(false);
    try {
      return Promise.resolve(miniTool.setStorage({ key: STORAGE_KEY, data: serialized })).then(function () { return true; }).catch(function () { return false; });
    } catch (error) { return Promise.resolve(false); }
  };
  PlatformBridge.prototype.vibrate = function (heavy) {
    if (!atLeast(this.buildVersion, 9500)) return Promise.resolve(false);
    var miniTool = this.miniTool();
    if (!miniTool) return Promise.resolve(false);
    try {
      if (heavy && typeof miniTool.vibrateLong === "function") {
        return Promise.resolve(miniTool.vibrateLong()).then(function () { return true; }).catch(function () { return false; });
      }
      if (typeof miniTool.vibrateShort === "function") {
        return Promise.resolve(miniTool.vibrateShort({ type: heavy ? "heavy" : "light" })).then(function () { return true; }).catch(function () { return false; });
      }
    } catch (error) { return Promise.resolve(false); }
    return Promise.resolve(false);
  };
  PlatformBridge.prototype.readWindowInfo = function () {
    var self = this;
    var miniTool = this.miniTool();
    if (!atLeast(this.buildVersion, 9490) || !miniTool || typeof miniTool.getWindowInfo !== "function") return Promise.resolve(null);
    try {
      return Promise.resolve(miniTool.getWindowInfo()).then(function (info) {
        self.windowInfo = info || null;
        self.applySafeArea(info);
        return info;
      }).catch(function () { return null; });
    } catch (error) { return Promise.resolve(null); }
  };
  PlatformBridge.prototype.applySafeArea = function (info) {
    if (!info || !info.safeArea || !this.root.document || !this.root.document.documentElement) return;
    var area = info.safeArea;
    var style = this.root.document.documentElement.style;
    var top = Math.max(0, Number(area.top) || 0);
    var left = Math.max(0, Number(area.left) || 0);
    var right = Math.max(0, (Number(info.windowWidth) || area.right || 0) - (Number(area.right) || 0));
    var bottom = Math.max(0, (Number(info.windowHeight) || area.bottom || 0) - (Number(area.bottom) || 0));
    style.setProperty("--safe-area-inset-top", top + "px");
    style.setProperty("--safe-area-inset-right", right + "px");
    style.setProperty("--safe-area-inset-bottom", bottom + "px");
    style.setProperty("--safe-area-inset-left", left + "px");
  };

  SDD.PlatformBridge = PlatformBridge;
  SDD.readBuildVersion = readBuildVersion;
  SDD.clientVersion = clientVersion;
  SDD.atLeast = atLeast;
  SDD.STORAGE_KEY = STORAGE_KEY;
}());
