"""Makes the two call sounds in assets/sounds/.

ring.wav      the incoming-call ring: a soft rising chime, twice, then a
              pause. Loops.
ringback.wav  what the caller hears while it rings: a quiet two-tone beep,
              then a pause. Loops.

Made here rather than downloaded so there is no licence to worry about.
Run from the repo root: python3 tools/make_call_sounds.py
"""
import math
import struct
import wave

SR = 22050


def write(name, samples):
    w = wave.open(name, 'wb')
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(b''.join(
        struct.pack('<h', max(-32767, min(32767, int(s * 32767))))
        for s in samples))
    w.close()


def note(freq, dur, vol, decay):
    out = []
    for i in range(int(SR * dur)):
        t = i / SR
        env = math.exp(-t * decay) * min(1, t * 400)
        # A marimba-like tone: the note plus a soft, quickly fading overtone.
        s = (math.sin(2 * math.pi * freq * t)
             + 0.25 * math.sin(2 * math.pi * freq * 4 * t) * math.exp(-t * decay * 3))
        out.append(s * env * vol)
    return out


def mix(base, add, at):
    start = int(at * SR)
    if len(base) < start + len(add):
        base += [0.0] * (start + len(add) - len(base))
    for i, s in enumerate(add):
        base[start + i] += s
    return base


ring = [0.0] * int(SR * 3.2)
for rep in (0, 0.8):
    for k, f in enumerate([659.25, 830.61, 987.77, 1318.51]):
        ring = mix(ring, note(f, 0.9, 0.22, 5.5), rep + k * 0.12)
write('assets/sounds/ring.wav', ring[:int(SR * 3.2)])

ringback = []
for i in range(int(SR * 1.2)):
    t = i / SR
    env = min(1, t / 0.05) * min(1, (1.2 - t) / 0.08)
    ringback.append((math.sin(2 * math.pi * 440 * t)
                     + math.sin(2 * math.pi * 480 * t)) * 0.09 * env)
ringback += [0.0] * int(SR * 2.8)
write('assets/sounds/ringback.wav', ringback)
