(function () {
  "use strict";
  var SDD = window.SDD = window.SDD || {};

  function SynthAudio(root) {
    this.root = root || window;
    this.enabled = true;
    this.context = null;
    this.failed = false;
    this.noiseBuffer = null;
  }
  SynthAudio.prototype.unlock = function () {
    if (!this.enabled || this.failed) return false;
    try {
      if (!this.context) {
        var AudioCtor = this.root.AudioContext || this.root.webkitAudioContext;
        if (typeof AudioCtor !== "function") { this.failed = true; return false; }
        this.context = new AudioCtor();
      }
      if (this.context.state === "suspended" && typeof this.context.resume === "function") {
        var resumed = this.context.resume();
        if (resumed && typeof resumed.catch === "function") resumed.catch(function () {});
      }
      return true;
    } catch (error) { this.failed = true; return false; }
  };
  SynthAudio.prototype.setEnabled = function (enabled) {
    this.enabled = !!enabled;
    if (this.enabled) this.unlock();
  };
  SynthAudio.prototype.tone = function (frequency, duration, volume, type, delay, endFrequency) {
    if (!this.context || this.failed) return;
    var ctx = this.context;
    var start = ctx.currentTime + (delay || 0);
    var oscillator = ctx.createOscillator();
    var gain = ctx.createGain();
    oscillator.type = type || "sine";
    oscillator.frequency.setValueAtTime(frequency, start);
    if (endFrequency) oscillator.frequency.exponentialRampToValueAtTime(endFrequency, start + duration);
    gain.gain.setValueAtTime(0.0001, start);
    gain.gain.linearRampToValueAtTime(volume, start + Math.min(0.012, duration * 0.2));
    gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);
    oscillator.connect(gain);
    gain.connect(ctx.destination);
    oscillator.start(start);
    oscillator.stop(start + duration + 0.02);
  };
  SynthAudio.prototype.noise = function (duration, volume, delay) {
    if (!this.context || this.failed) return;
    var ctx = this.context;
    if (!this.noiseBuffer) {
      var length = Math.max(1, Math.floor(ctx.sampleRate * 0.35));
      this.noiseBuffer = ctx.createBuffer(1, length, ctx.sampleRate);
      var channel = this.noiseBuffer.getChannelData(0);
      var seed = 193;
      for (var i = 0; i < length; i += 1) {
        seed = (seed * 16807) % 2147483647;
        channel[i] = (seed / 2147483647 * 2 - 1) * (1 - i / length);
      }
    }
    var source = ctx.createBufferSource();
    var filter = ctx.createBiquadFilter();
    var gain = ctx.createGain();
    var start = ctx.currentTime + (delay || 0);
    source.buffer = this.noiseBuffer;
    filter.type = "bandpass";
    filter.frequency.value = 1800;
    filter.Q.value = 0.7;
    gain.gain.setValueAtTime(volume, start);
    gain.gain.exponentialRampToValueAtTime(0.0001, start + duration);
    source.connect(filter); filter.connect(gain); gain.connect(ctx.destination);
    source.start(start); source.stop(start + duration + 0.01);
  };
  SynthAudio.prototype.play = function (name, combo) {
    if (!this.enabled || this.failed || !this.unlock()) return;
    try {
      if (name === "pick") { this.noise(0.045, 0.035, 0); this.tone(620, 0.055, 0.035, "triangle", 0, 780); }
      else if (name === "zone") { this.tone(440, 0.075, 0.04, "sine", 0, 560); }
      else if (name === "return") { this.tone(360, 0.08, 0.035, "triangle", 0, 250); }
      else if (name === "beep") { this.tone(1040, 0.10, 0.05, "square", 0); }
      else if (name === "print") { this.noise(0.26, 0.05, 0); this.tone(125, 0.22, 0.025, "sawtooth", 0); }
      else if (name === "bag") { this.noise(0.14, 0.06, 0); this.tone(520, 0.12, 0.035, "triangle", 0.05, 680); }
      else if (name === "combo") {
        var base = 620 + Math.min(combo || 1, 10) * 28;
        this.tone(base, 0.09, 0.04, "sine", 0); this.tone(base * 1.25, 0.12, 0.035, "sine", 0.055);
      } else if (name === "magnet") { this.tone(280, 0.28, 0.045, "sine", 0, 960); }
      else if (name === "complete") {
        this.tone(523, 0.16, 0.045, "triangle", 0); this.tone(659, 0.16, 0.045, "triangle", 0.12);
        this.tone(784, 0.24, 0.05, "triangle", 0.24); this.tone(1047, 0.30, 0.045, "sine", 0.36);
      } else if (name === "fail") { this.tone(260, 0.22, 0.045, "triangle", 0, 180); this.tone(180, 0.3, 0.04, "sine", 0.18, 120); }
    } catch (error) { this.failed = true; }
  };
  SynthAudio.prototype.suspend = function () {
    if (!this.context || typeof this.context.suspend !== "function") return;
    try {
      var result = this.context.suspend();
      if (result && typeof result.catch === "function") result.catch(function () {});
    } catch (error) {}
  };
  SDD.SynthAudio = SynthAudio;
}());
