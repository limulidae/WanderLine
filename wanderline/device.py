"""連 iPhone、掛開發者映像檔、改位置。

iOS 17 以上：要先有 tunneld（start.bat 會用系統管理員身分開），透過它拿到 RSD 連線，再走 DVT 的 LocationSimulation。
iOS 16 以下：直接走 lockdown 的 com.apple.dt.simulatelocation。
"""
import asyncio
import contextlib
import logging

from pymobiledevice3.exceptions import AlreadyMountedError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.services.simulate_location import DtSimulateLocation
from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid

log = logging.getLogger(__name__)


class DeviceError(Exception):
    """給使用者看的錯誤（中文說明下一步怎麼做）"""


class Device:
    def __init__(self):
        self.lock = asyncio.Lock()
        self.sim = None
        self.stack = None
        self.info = None          # {"name", "ios", "udid"}
        self.position = None      # 目前送出去的假位置 (lat, lng)

    async def _connect(self):
        if self.sim is not None:
            return
        try:
            lockdown = await create_using_usbmux(autopair=True)
        except Exception as e:
            raise DeviceError("找不到 iPhone：請用傳輸線接上電腦、解鎖手機，跳出「要信任這部電腦嗎？」時按「信任」。") from e

        ios = lockdown.product_version
        major = int(ios.split(".")[0])
        self.info = {"name": lockdown.display_name or "iPhone", "ios": ios, "udid": lockdown.udid}

        if major >= 16:
            with contextlib.suppress(Exception):
                if not await lockdown.get_developer_mode_status():
                    with contextlib.suppress(Exception):
                        await AmfiService(lockdown).reveal_developer_mode_option_in_ui()
                    raise DeviceError("iPhone 還沒打開「開發者模式」：到 設定 → 隱私權與安全性 → 開發者模式 打開，手機會重開機，"
                                      "重開後再按一次「開啟」。")

        stack = contextlib.AsyncExitStack()
        try:
            if major >= 17:
                rsd = None
                for _ in range(15):   # tunneld 剛開或手機剛接上時要等一下
                    with contextlib.suppress(Exception):
                        rsd = await get_tunneld_device_by_udid(lockdown.udid)
                    if rsd:
                        break
                    await asyncio.sleep(1)
                if rsd is None:
                    raise DeviceError("連不上 iPhone 的開發者通道：請確定是用 start.bat 開的（要按「是」給系統管理員權限），"
                                      "手機保持解鎖，再按一次「重新連線」。")
                stack.push_async_callback(rsd.close)
                await self._mount(rsd)
                dvt = await stack.enter_async_context(DvtProvider(rsd))
                self.sim = await stack.enter_async_context(LocationSimulation(dvt))
            else:
                await self._mount(lockdown)
                self.sim = DtSimulateLocation(lockdown)
        except BaseException:
            await stack.aclose()
            self.sim = None
            raise
        self.stack = stack

    async def _mount(self, provider):
        try:
            await auto_mount(provider)
        except AlreadyMountedError:
            pass
        except Exception as e:
            raise DeviceError(f"掛載開發者映像檔失敗（第一次要從網路下載，請確認有網路、手機解鎖）：{e}") from e

    async def disconnect(self):
        async with self.lock:
            await self._drop()

    async def _drop(self):
        if self.stack is not None:
            with contextlib.suppress(Exception):
                await self.stack.aclose()
        self.stack = None
        self.sim = None

    async def connect(self):
        async with self.lock:
            await self._drop()
            await self._connect()
            return self.info

    async def set(self, lat: float, lng: float):
        async with self.lock:
            for attempt in range(2):
                await self._connect()
                try:
                    await self.sim.set(lat, lng)
                    self.position = (lat, lng)
                    return
                except DeviceError:
                    raise
                except Exception as e:
                    log.warning("改位置失敗，重新連線：%s", e)
                    await self._drop()
                    if attempt:
                        raise DeviceError(f"改位置失敗：{e}") from e

    async def clear(self):
        async with self.lock:
            await self._connect()
            try:
                await self.sim.clear()
            finally:
                self.position = None
