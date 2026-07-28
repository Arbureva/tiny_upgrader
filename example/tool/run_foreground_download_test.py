#!/usr/bin/env python3
"""Run the real example app against a local update service."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "99.0.0"
BUILD_VERSION = 999999
PACKAGE_NAME = "com.example.tiny_upgrader_example"
DOWNLOAD_CHUNK_SIZE = 64 * 1024
DOWNLOAD_CHUNK_DELAY_SECONDS = 0.02

# Leave this as None to use adb reverse (recommended). Set a Wi-Fi/LAN address
# such as "192.168.1.20" only when adb reverse is unavailable.
DEFAULT_HOST_IP: str | None = None


class UpdateServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[BaseHTTPRequestHandler],
        apk_path: Path,
    ) -> None:
        super().__init__(server_address, handler_class)
        self.apk_path = apk_path
        self.range_requests = 0


class UpdateHandler(BaseHTTPRequestHandler):
    server: UpdateServer

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/api/apk-manager-v1/latest":
            self._serve_latest()
            return
        if path == "/api/apk-manager-v1/stats":
            self._json({"rangeRequests": self.server.range_requests})
            return
        if path == f"/api/apk-manager-v1/download/{VERSION}":
            self._serve_apk()
            return
        self.send_error(404)

    def _serve_latest(self) -> None:
        apk_path = self.server.apk_path
        if not apk_path.is_file():
            self._json(
                {
                    "error": "The example APK is not ready yet. Wait for "
                    "'Flutter run key commands' and try again."
                },
                status=503,
            )
            return

        self._json(
            {
                "data": {
                    "update_status": 0,
                    "version": VERSION,
                    "build_version": BUILD_VERSION,
                    "modify_content": (
                        "本机模拟更新：请点击下载，然后按 Home 键检查"
                        "通知栏进度和后台下载。"
                    ),
                    "download_url": (
                        f"/api/apk-manager-v1/download/{VERSION}"
                    ),
                    "apk_size": apk_path.stat().st_size,
                    "apk_hash_code": file_md5(apk_path),
                    "apk_hash_algorithm": "md5",
                }
            }
        )

    def _serve_apk(self) -> None:
        apk_path = self.server.apk_path
        if not apk_path.is_file():
            self.send_error(503, "The example APK is not ready yet")
            return

        file_size = apk_path.stat().st_size
        start = self._range_start(file_size)
        if start is None:
            return

        content_length = file_size - start
        self.send_response(206 if start else 200)
        self.send_header(
            "Content-Type",
            "application/vnd.android.package-archive",
        )
        self.send_header("Content-Length", str(content_length))
        self.send_header("Accept-Ranges", "bytes")
        if start:
            self.server.range_requests += 1
            self.send_header(
                "Content-Range",
                f"bytes {start}-{file_size - 1}/{file_size}",
            )
        self.end_headers()

        try:
            with apk_path.open("rb") as apk:
                apk.seek(start)
                while chunk := apk.read(DOWNLOAD_CHUNK_SIZE):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    time.sleep(DOWNLOAD_CHUNK_DELAY_SECONDS)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _range_start(self, file_size: int) -> int | None:
        header = self.headers.get("Range")
        if not header:
            return 0
        if not header.startswith("bytes=") or not header.endswith("-"):
            self.send_error(400, "Only a single open-ended byte range is supported")
            return None
        try:
            start = int(header[6:-1])
        except ValueError:
            self.send_error(400, "Invalid Range header")
            return None
        if start < 0 or start >= file_size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.end_headers()
            return None
        return start

    def log_message(self, format: str, *args: object) -> None:
        print(f"[local update server] {format % args}", flush=True)

    def _json(self, value: object, *, status: int = 200) -> None:
        body = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def file_md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str], cwd: Path) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def detect_wifi_ip() -> str:
    for interface in ("en0", "en1"):
        result = subprocess.run(
            ["ipconfig", "getifaddr", interface],
            check=False,
            capture_output=True,
            text=True,
        )
        value = result.stdout.strip()
        if value:
            return value
    raise SystemExit(
        "Unable to detect the Wi-Fi IP. Pass --host-ip or set DEFAULT_HOST_IP."
    )


def detect_device(adb: str, requested_device: str | None) -> str:
    if requested_device:
        return requested_device
    output = subprocess.check_output([adb, "devices"], text=True)
    devices = [
        line.split()[0]
        for line in output.splitlines()[1:]
        if line.strip().endswith("\tdevice")
    ]
    if not devices:
        raise SystemExit("No running Android device or emulator was found")
    if len(devices) > 1:
        raise SystemExit(
            "Multiple Android devices found; pass -d <device-id>: "
            + ", ".join(devices)
        )
    return devices[0]


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Start a local update service and run the real Flutter example app."
        )
    )
    parser.add_argument("-d", "--device-id")
    parser.add_argument(
        "--host-ip",
        help="Use this host Wi-Fi/LAN IP instead of adb reverse.",
    )
    parser.add_argument(
        "--wifi",
        action="store_true",
        help="Auto-detect the Mac Wi-Fi IP instead of adb reverse.",
    )
    args = parser.parse_args()

    example_dir = Path(__file__).resolve().parents[1]
    apk_path = example_dir / "build/app/outputs/flutter-apk/app-debug.apk"
    adb = shutil.which("adb")
    flutter = shutil.which("flutter")
    if adb is None:
        raise SystemExit("adb was not found in PATH")
    if flutter is None:
        raise SystemExit("flutter was not found in PATH")

    device_id = detect_device(adb, args.device_id)
    host_ip = args.host_ip or DEFAULT_HOST_IP
    if args.wifi and host_ip is None:
        host_ip = detect_wifi_ip()
    use_adb_reverse = host_ip is None

    server = UpdateServer(
        ("127.0.0.1" if use_adb_reverse else "0.0.0.0", 0),
        UpdateHandler,
        apk_path,
    )
    port = server.server_port
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    adb_command = [adb, "-s", device_id]
    try:
        if use_adb_reverse:
            run(
                adb_command + ["reverse", f"tcp:{port}", f"tcp:{port}"],
                example_dir,
            )
            base_url = f"http://127.0.0.1:{port}/"
        else:
            base_url = f"http://{host_ip}:{port}/"

        print(f"\nLocal update service: {base_url}", flush=True)
        print(
            "The real example app will stay open. Tap '更新测试', start the "
            "download, then press Home to inspect background progress.",
            flush=True,
        )
        print(
            "Keep this terminal running; press q in Flutter or Ctrl-C to stop.\n",
            flush=True,
        )
        package_exists = subprocess.run(
            adb_command + ["shell", "pm", "path", PACKAGE_NAME],
            cwd=example_dir,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
        if package_exists:
            subprocess.run(
                adb_command + ["shell", "pm", "clear", PACKAGE_NAME],
                cwd=example_dir,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        run(
            [
                flutter,
                "run",
                "-d",
                device_id,
                f"--dart-define=TINY_UPGRADER_BASE_URL={base_url}",
            ],
            example_dir,
        )
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)
        if use_adb_reverse:
            subprocess.run(
                adb_command + ["reverse", "--remove", f"tcp:{port}"],
                cwd=example_dir,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )


if __name__ == "__main__":
    main()
