"""沿著一串點用固定速度走，每秒送一次位置。"""
import asyncio
import contextlib
import math
import random

R = 6371008.8


def dist(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


class Walker:
    def __init__(self, device):
        self.device = device
        self.task = None
        self.paused = False
        self.state = {"running": False}

    def status(self):
        s = dict(self.state)
        s["paused"] = self.paused
        return s

    async def stop(self):
        if self.task:
            self.task.cancel()
            with contextlib.suppress(BaseException):
                await self.task
        self.task = None
        self.paused = False
        self.state = {"running": False}

    async def start(self, points, speed_kmh, mode="once", jitter_m=0.0):
        """mode: once（走完停在終點）、loop（走完回起點再走）、back（來回走）"""
        await self.stop()
        pts = [(float(p[0]), float(p[1])) for p in points]
        if len(pts) < 2:
            raise ValueError("路線至少要兩個點")
        self.task = asyncio.create_task(self._run(pts, max(0.5, float(speed_kmh)) / 3.6, mode, float(jitter_m)))

    async def _run(self, pts, speed, mode, jitter_m):
        seq = pts
        if mode == "loop" and dist(pts[0], pts[-1]) > 1:
            seq = pts + [pts[0]]
        lap = 0
        try:
            while True:
                legs = [dist(seq[i], seq[i + 1]) for i in range(len(seq) - 1)]
                total = sum(legs)
                done = 0.0
                i, into = 0, 0.0
                while True:
                    while i < len(legs) and into >= legs[i]:
                        into -= legs[i]
                        i += 1
                    if i >= len(legs):
                        pos = seq[-1]
                    else:
                        pos = lerp(seq[i], seq[i + 1], into / legs[i] if legs[i] else 1)
                    if jitter_m > 0 and i < len(legs):
                        # 人走路不會剛好壓在線上：左右晃一點點
                        dlat = random.uniform(-jitter_m, jitter_m) / 111320
                        dlng = random.uniform(-jitter_m, jitter_m) / (111320 * math.cos(math.radians(pos[0])))
                        pos = (pos[0] + dlat, pos[1] + dlng)
                    await self.device.set(*pos)
                    self.state = {"running": True, "lap": lap, "done_m": round(min(done, total)), "total_m": round(total),
                                  "speed_kmh": round(speed * 3.6, 1), "mode": mode}
                    if i >= len(legs):
                        break
                    await asyncio.sleep(1)
                    while self.paused:
                        await asyncio.sleep(0.3)
                    step = speed * random.uniform(0.9, 1.1)
                    into += step
                    done += step
                lap += 1
                if mode == "once":
                    break
                if mode == "back":
                    seq = list(reversed(seq))
            self.state = {"running": False, "finished": True, "total_m": round(total)}
        except asyncio.CancelledError:
            raise
        except Exception as e:
            self.state = {"running": False, "error": str(e)}

