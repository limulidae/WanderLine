"""python -m wanderline：開 tunneld（iOS 17 以上要用）＋本機網頁，再打開瀏覽器。"""
import atexit
import ctypes
import os
import subprocess
import sys
import threading
import time
import webbrowser

import uvicorn

PORT = 8777


def is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return os.geteuid() == 0 if hasattr(os, "geteuid") else False


def main():
    if not is_admin():
        print("提醒：沒有系統管理員權限，iOS 17 以上的 iPhone 會連不上。請用 start.bat 開（跳出視窗時按「是」）。")
    tunneld = subprocess.Popen([sys.executable, "-m", "pymobiledevice3", "remote", "tunneld"],
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    atexit.register(tunneld.terminate)
    threading.Thread(target=lambda: (time.sleep(2), webbrowser.open(f"http://127.0.0.1:{PORT}/")), daemon=True).start()
    print(f"打開瀏覽器：http://127.0.0.1:{PORT}/  （關掉這個視窗就結束，手機會留在最後的位置，記得先按「還原真實位置」）")
    uvicorn.run("wanderline.server:app", host="127.0.0.1", port=PORT, log_level="warning")


if __name__ == "__main__":
    main()
