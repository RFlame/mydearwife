#!/usr/bin/env python3
"""程序化合成《零食叮叮咚》音效：收银台 ASMR 风格，22050Hz 16bit mono WAV。
用法：python3 -I tools/make_sfx.py
"""
import math
import os
import random
import struct
import wave

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sfx")
random.seed(7)


def env_exp(n, decay):
    return [math.exp(-decay * i / n) for i in range(n)]


def sine(freq, n, phase=0.0):
    return [math.sin(2 * math.pi * freq * i / SR + phase) for i in range(n)]


def mix(parts):
    n = max(len(p) for p in parts)
    out = [0.0] * n
    for p in parts:
        for i, v in enumerate(p):
            out[i] += v
    return out


def at(samples, offset):
    return [0.0] * offset + list(samples)


def noise(n):
    return [random.uniform(-1, 1) for _ in range(n)]


def lowpass(samples, alpha):
    out, y = [], 0.0
    for v in samples:
        y += alpha * (v - y)
        out.append(y)
    return out


def gain(samples, g):
    if isinstance(g, list):
        return [v * w for v, w in zip(samples, g)]
    return [v * g for v in samples]


def normalize(samples, peak=0.85):
    m = max(1e-9, max(abs(v) for v in samples))
    return [v / m * peak for v in samples]


def save(name, samples):
    samples = normalize(samples)
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in samples))
    print("wrote", name, "%.2fs" % (len(samples) / SR))


def main():
    os.makedirs(OUT, exist_ok=True)

    # 咔哒：短噪声 + 高频 blip
    n = int(SR * 0.07)
    click = mix([gain(lowpass(noise(n), 0.5), env_exp(n, 9)), gain(sine(2400, n), env_exp(n, 14))])
    save("pick.wav", gain(click, 0.7))

    # 电子秤滴：干净方感正弦双泛音
    n = int(SR * 0.16)
    beep = mix([sine(1760, n), gain(sine(3520, n), 0.25)])
    beep = [v * e for v, e in zip(beep, env_exp(n, 6))]
    save("beep.wav", beep)

    # 价签刺啦：带通感噪声扫频
    n = int(SR * 0.22)
    pr = lowpass(noise(n), 0.35)
    pr = [v * (0.6 + 0.4 * math.sin(2 * math.pi * 60 * i / SR)) for i, v in enumerate(pr)]
    pr = [v * e for v, e in zip(pr, env_exp(n, 4))]
    save("print.wav", gain(pr, 0.8))

    # 塑料袋唰：低通噪声
    n = int(SR * 0.18)
    bag = lowpass(noise(n), 0.12)
    bag = [v * e for v, e in zip(bag, env_exp(n, 5))]
    save("bag.wav", bag)

    # 收银机叮：金属泛音列
    n = int(SR * 0.8)
    ding = mix([sine(1568, n), gain(sine(2093, n), 0.5), gain(sine(3136, n), 0.3), gain(sine(4186, n), 0.15)])
    ding = [v * e for v, e in zip(ding, env_exp(n, 5))]
    save("ding.wav", ding)

    # 硬币哗啦：随机时序金属 blip
    parts = []
    for _ in range(7):
        off = random.randint(0, int(SR * 0.35))
        f = random.choice([2500, 3100, 3700, 4300])
        n = int(SR * 0.12)
        blip = mix([sine(f, n), gain(sine(f * 1.51, n), 0.4)])
        parts.append(at(gain([v * e for v, e in zip(blip, env_exp(n, 9))], 0.6), off))
    save("coins.wav", mix(parts))

    # 连击 blip（引擎按五声音阶变调）
    n = int(SR * 0.1)
    combo = mix([sine(880, n), gain(sine(1760, n), 0.3)])
    combo = [v * e for v, e in zip(combo, env_exp(n, 8))]
    save("combo.wav", combo)

    # 过关琶音：C5 E5 G5 C6
    parts = []
    for i, f in enumerate([523.25, 659.25, 783.99, 1046.5]):
        n = int(SR * 0.35)
        tone = mix([sine(f, n), gain(sine(f * 2, n), 0.3)])
        parts.append(at([v * e for v, e in zip(tone, env_exp(n, 5))], int(i * SR * 0.11)))
    save("complete.wav", mix(parts))

    # 失败下行
    n = int(SR * 0.45)
    fail = [math.sin(2 * math.pi * (320 - 140 * i / n) * i / SR) for i in range(n)]
    fail = [v * e for v, e in zip(fail, env_exp(n, 5))]
    save("fail.wav", gain(fail, 0.6))

    # 吸附嗖：上行扫频 + 轻噪声
    n = int(SR * 0.28)
    sweep = [math.sin(2 * math.pi * (400 + 1400 * i / n) * i / SR) for i in range(n)]
    whoosh = mix([sweep, gain(lowpass(noise(n), 0.2), 0.4)])
    whoosh = [v * e for v, e in zip(whoosh, env_exp(n, 3))]
    save("magnet.wav", whoosh)


if __name__ == "__main__":
    main()
