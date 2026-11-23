"""本機網頁：http://127.0.0.1:8777（只聽本機，不對外）"""
import json
import urllib.parse
import urllib.request
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

from .device import Device, DeviceError
from .walker import Walker

WEB = Path(__file__).parent / "web"
UA = "wanderline/1.0 (personal use)"

app = FastAPI()
device = Device()
walker = Walker(device)


class Point(BaseModel):
    lat: float
    lng: float


class Route(BaseModel):
    points: list[list[float]]
    speed_kmh: float = 4.5
    mode: str = "once"
    jitter_m: float = 0.0


def fail(e: Exception):
    if isinstance(e, (DeviceError, ValueError)):
        return JSONResponse({"error": str(e)}, status_code=400)
    return JSONResponse({"error": f"{type(e).__name__}: {e}"}, status_code=500)


@app.get("/")
def index():
    return FileResponse(WEB / "index.html")


@app.get("/api/status")
def status():
    return {"device": device.info, "connected": device.sim is not None,
            "position": device.position, "walk": walker.status()}


@app.post("/api/connect")
async def connect():
    try:
        return {"device": await device.connect()}
    except Exception as e:
        return fail(e)


@app.post("/api/set")
async def set_location(p: Point):
    try:
        await walker.stop()
        await device.set(p.lat, p.lng)
        return {"ok": True}
    except Exception as e:
        return fail(e)


@app.post("/api/nudge")
async def nudge(p: Point):
    """方向鍵移動用：不停掉路線以外的東西，只送位置"""
    try:
        if walker.task:
            await walker.stop()
        await device.set(p.lat, p.lng)
        return {"ok": True}
    except Exception as e:
        return fail(e)


@app.post("/api/clear")
async def clear():
    try:
        await walker.stop()
        await device.clear()
        return {"ok": True}
    except Exception as e:
        return fail(e)


@app.post("/api/walk")
async def walk(r: Route):
    try:
        await walker.start(r.points, r.speed_kmh, r.mode, r.jitter_m)
        return {"ok": True}
    except Exception as e:
        return fail(e)


@app.post("/api/walk/pause")
async def pause():
    walker.paused = not walker.paused
    return {"paused": walker.paused}


@app.post("/api/walk/stop")
async def stop():
    await walker.stop()
    return {"ok": True}


@app.post("/api/snap")
def snap(r: Route):
    """把點過的點連成沿著街道走的路（OpenStreetMap 德國站的步行路線服務）"""
    if len(r.points) < 2:
        raise HTTPException(400, "至少兩個點")
    coords = ";".join(f"{lng:.6f},{lat:.6f}" for lat, lng in r.points)
    url = f"https://routing.openstreetmap.de/routed-foot/route/v1/foot/{coords}?overview=full&geometries=geojson"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
        line = data["routes"][0]["geometry"]["coordinates"]
        return {"points": [[lat, lng] for lng, lat in line], "distance_m": data["routes"][0]["distance"]}
    except Exception as e:
        return JSONResponse({"error": f"找不到沿路走的路線：{e}"}, status_code=502)


@app.get("/api/search")
def search(q: str):
    url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode({"q": q, "format": "json", "limit": 6})
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "zh-TW,en"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            return [{"name": x["display_name"], "lat": float(x["lat"]), "lng": float(x["lon"])} for x in json.load(resp)]
    except Exception as e:
        return JSONResponse({"error": f"搜尋失敗：{e}"}, status_code=502)


@app.on_event("shutdown")
async def shutdown():
    await walker.stop()
    await device.disconnect()
