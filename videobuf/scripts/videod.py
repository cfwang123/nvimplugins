#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Long-lived video daemon for videobuf.nvim (stdin/stdout JSON lines).

Protocol — one JSON object per line.

Request (nvim → python):
  {"cmd":"open","path":"...","fps":10,"cols":120,"rows":30,"scale":"fit","volume":70,"start":0,"mode":"half"}
  {"cmd":"play"} | {"cmd":"pause"} | {"cmd":"toggle"} | {"cmd":"stop"}
  {"cmd":"seek","position":12.3}
  {"cmd":"volume","volume":50}
  {"cmd":"fps","fps":12}
  {"cmd":"resize","cols":100,"rows":28,"scale":"fit","mode":"half"}
  {"cmd":"loop","loop":true}
  {"cmd":"status"} | {"cmd":"quit"} | {"cmd":"ping"}

Response (python → nvim):
  {"ok":true,"event":"ready"}
  {"ok":true,"event":"status", ...}
  {"ok":true,"event":"frame","format":"ansi","cols":C,"rows":R,"seq":N,"position":P,"data":"..."}
  {"ok":true,"event":"ended","path":"..."}
  {"ok":false,"error":"..."}
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Dict, List, Optional, Tuple

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"

try:
    sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)  # type: ignore[attr-defined]
    sys.stderr.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except Exception:
    pass

# nvim 在 Windows 上经常收不到 job stdout；同时写事件文件供轮询
_EVENT_PATH = os.environ.get("VIDEOBUF_EVENTS", "").strip()
_EVENT_LOCK = threading.Lock()
_BOOT_LOG = os.environ.get("VIDEOBUF_BOOT_LOG", "").strip()


def _boot_log(msg: str) -> None:
    if not _BOOT_LOG:
        return
    try:
        with open(_BOOT_LOG, "a", encoding="utf-8") as f:
            f.write(f"{time.time():.3f} {msg}\n")
    except Exception:
        pass


def emit(obj: Dict[str, Any]) -> None:
    line = json.dumps(obj, ensure_ascii=False) + "\n"
    try:
        sys.stdout.write(line)
        sys.stdout.flush()
    except Exception:
        pass
    if _EVENT_PATH:
        try:
            with _EVENT_LOCK:
                with open(_EVENT_PATH, "a", encoding="utf-8", newline="\n") as f:
                    f.write(line)
        except Exception as exc:
            _boot_log(f"event write fail: {exc}")


def which(name: str) -> Optional[str]:
    return shutil.which(name)


def probe_duration(path: str) -> Optional[float]:
    ffprobe = which("ffprobe")
    if not ffprobe:
        return None
    try:
        out = subprocess.check_output(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                path,
            ],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=12,
        )
        n = float(out.strip())
        return n if n > 0 else None
    except Exception:
        return None


def probe_size(path: str) -> Tuple[Optional[int], Optional[int]]:
    ffprobe = which("ffprobe")
    if not ffprobe:
        return None, None
    try:
        out = subprocess.check_output(
            [
                ffprobe,
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=width,height",
                "-of",
                "csv=p=0:s=x",
                path,
            ],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=12,
        )
        out = out.strip()
        if "x" in out:
            a, b = out.split("x", 1)
            return int(a), int(b)
    except Exception:
        pass
    return None, None


# ── audio engines (video file → wav extract) ──────────────────────────


class JustPlaybackEngine:
    """miniaudio 后端。注意：通常不能直接播 mp4 内 aac，需先解 wav。"""

    name = "just_playback"

    def __init__(self) -> None:
        from just_playback import Playback  # type: ignore

        self._Playback = Playback
        self._pb = Playback()
        self._path: Optional[str] = None
        self._volume = 0.7
        self._status = "idle"
        self._duration: Optional[float] = None

    def _fresh(self) -> None:
        try:
            self._pb = self._Playback()
        except Exception:
            from just_playback import Playback  # type: ignore

            self._Playback = Playback
            self._pb = Playback()

    def load_only(self, path: str, volume: int = 70) -> None:
        """只加载不播放，避免 play+立即 pause 的竞态（会导致之后无声）。"""
        self._path = path
        self._volume = max(0.0, min(1.0, volume / 100.0))
        self._fresh()
        self._pb.load_file(path)
        self._loaded_path = path
        self._duration = float(self._pb.duration) if self._pb.duration else None
        self._pb.set_volume(self._volume)
        self._status = "paused"

    def play(self, path: str, start: float = 0.0, volume: int = 70) -> None:
        self._path = path
        self._volume = max(0.0, min(1.0, volume / 100.0))
        try:
            # 路径变了或未加载则重载
            if getattr(self, "_loaded_path", None) != path:
                self._pb.load_file(path)
                self._loaded_path = path
        except Exception:
            self._fresh()
            self._pb.load_file(path)
            self._loaded_path = path
        self._duration = float(self._pb.duration) if self._pb.duration else None
        self._pb.set_volume(self._volume)
        try:
            self._pb.stop()
        except Exception:
            pass
        self._pb.play()
        if start and start > 0.02:
            try:
                self._pb.seek(float(start))
            except Exception:
                pass
        self._status = "playing"

    def pause(self) -> None:
        """立即静音并暂停（先 set_volume(0) 切断输出缓冲）。"""
        pos = self.position()
        try:
            self._pb.set_volume(0.0)
        except Exception:
            pass
        try:
            self._pb.pause()
        except Exception:
            try:
                self._pb.stop()
            except Exception:
                pass
        self._paused_at = pos
        self._status = "paused"

    def resume(self) -> None:
        if self._status == "paused" and self._path:
            start = getattr(self, "_paused_at", None)
            if start is None:
                start = self.position()
            # 完整 play 更稳：resume 后有时仍会拖尾
            self.play(self._path, start=float(start or 0), volume=int(self._volume * 100))
        elif self._status in ("stopped", "idle") and self._path:
            self.play(self._path, start=self.position(), volume=int(self._volume * 100))

    def stop(self) -> None:
        try:
            self._pb.set_volume(0.0)
        except Exception:
            pass
        try:
            self._pb.stop()
        except Exception:
            pass
        try:
            self._pb.set_volume(self._volume)
        except Exception:
            pass
        self._status = "stopped"

    def seek(self, position: float) -> None:
        position = max(0.0, float(position))
        if self._duration is not None:
            position = min(position, self._duration)
        self._pb.seek(position)
        if self._status == "stopped":
            self._status = "paused"

    def set_volume(self, volume: int) -> None:
        self._volume = max(0.0, min(1.0, volume / 100.0))
        self._pb.set_volume(self._volume)

    def position(self) -> float:
        try:
            return float(self._pb.curr_pos or 0.0)
        except Exception:
            return 0.0

    def duration(self) -> Optional[float]:
        try:
            d = float(self._pb.duration) if self._pb.duration else None
            if d and d > 0:
                self._duration = d
        except Exception:
            pass
        return self._duration

    def status(self) -> str:
        try:
            if self._status == "playing" and not self._pb.playing and not self._pb.active:
                self._status = "stopped"
        except Exception:
            pass
        return self._status

    def check_ended(self) -> bool:
        if self._status != "playing":
            return False
        try:
            if not self._pb.playing and not self._pb.active:
                self._status = "stopped"
                return True
            dur = self.duration()
            pos = self.position()
            if dur and pos >= dur - 0.15 and not self._pb.playing:
                self._status = "stopped"
                return True
        except Exception:
            pass
        return False


class PygameEngine:
    name = "pygame"

    def __init__(self) -> None:
        import pygame

        self._pg = pygame
        if not pygame.mixer.get_init():
            pygame.mixer.init(frequency=44100, size=-16, channels=2, buffer=2048)
        self._path: Optional[str] = None
        self._volume = 0.7
        self._status = "idle"
        self._duration: Optional[float] = None
        self._base_pos = 0.0
        self._play_t0 = 0.0
        self._paused_pos = 0.0

    def play(self, path: str, start: float = 0.0, volume: int = 70) -> None:
        self._path = path
        self.set_volume(volume)
        music = self._pg.mixer.music
        music.load(path)
        music.set_volume(self._volume)
        start = max(0.0, float(start or 0.0))
        try:
            music.play(loops=0, start=start)
        except Exception:
            music.play(loops=0)
            if start > 0.05:
                try:
                    music.set_pos(start)
                except Exception:
                    pass
        self._base_pos = start
        self._play_t0 = time.monotonic()
        self._status = "playing"

    def pause(self) -> None:
        if self._status == "playing":
            self._paused_pos = self.position()
            try:
                self._pg.mixer.music.set_volume(0.0)
            except Exception:
                pass
            try:
                self._pg.mixer.music.pause()
            except Exception:
                try:
                    self._pg.mixer.music.stop()
                except Exception:
                    pass
            self._status = "paused"

    def resume(self) -> None:
        if self._status == "paused":
            try:
                self._pg.mixer.music.set_volume(self._volume)
            except Exception:
                pass
            try:
                self._pg.mixer.music.unpause()
                self._base_pos = self._paused_pos
                self._play_t0 = time.monotonic()
                self._status = "playing"
            except Exception:
                self.play(self._path or "", start=self._paused_pos or 0.0, volume=int(self._volume * 100))
        elif self._status in ("stopped", "idle") and self._path:
            self.play(self._path, start=self._paused_pos or 0.0, volume=int(self._volume * 100))

    def stop(self) -> None:
        try:
            self._pg.mixer.music.stop()
        except Exception:
            pass
        self._paused_pos = 0.0
        self._base_pos = 0.0
        self._status = "stopped"

    def seek(self, position: float) -> None:
        position = max(0.0, float(position))
        if self._duration is not None:
            position = min(position, self._duration)
        was = self._status == "playing"
        music = self._pg.mixer.music
        if not self._path:
            return
        music.stop()
        music.load(self._path)
        music.set_volume(self._volume)
        try:
            music.play(loops=0, start=position)
        except Exception:
            music.play(loops=0)
            try:
                music.set_pos(position)
            except Exception:
                pass
        self._base_pos = position
        self._play_t0 = time.monotonic()
        self._paused_pos = position
        if was:
            self._status = "playing"
        else:
            music.pause()
            self._status = "paused"

    def set_volume(self, volume: int) -> None:
        self._volume = max(0.0, min(1.0, volume / 100.0))
        try:
            self._pg.mixer.music.set_volume(self._volume)
        except Exception:
            pass

    def position(self) -> float:
        if self._status == "paused":
            return self._paused_pos
        if self._status != "playing":
            return self._base_pos
        return self._base_pos + (time.monotonic() - self._play_t0)

    def duration(self) -> Optional[float]:
        return self._duration

    def set_duration(self, d: Optional[float]) -> None:
        self._duration = d

    def status(self) -> str:
        if self._status == "playing":
            try:
                if not self._pg.mixer.music.get_busy():
                    dur = self._duration
                    pos = self.position()
                    if dur is None or pos >= (dur - 0.2):
                        self._status = "stopped"
            except Exception:
                pass
        return self._status

    def check_ended(self) -> bool:
        if self._status != "playing":
            return False
        try:
            if not self._pg.mixer.music.get_busy():
                dur = self._duration
                pos = self.position()
                if dur is None or pos >= (dur - 0.2):
                    self._status = "stopped"
                    return True
        except Exception:
            pass
        return False


def make_audio_engine() -> Tuple[Any, str]:
    try:
        eng = JustPlaybackEngine()
        return eng, eng.name
    except Exception:
        pass
    try:
        eng = PygameEngine()
        return eng, eng.name
    except Exception as exc:
        return None, f"no audio engine: {exc}"


# ── ANSI frame render（chafa 风格，纯 Python，不调 chafa）──────────────
# solid=整格 █/空格  half=半块 ▀  block=1/4 方块 ▘▝▖▗▀▄…

RGB = Tuple[int, int, int]
BLOCK_CHARS = (
    " ",
    "▘",
    "▝",
    "▀",
    "▖",
    "▌",
    "▞",
    "▛",
    "▗",
    "▚",
    "▐",
    "▜",
    "▄",
    "▙",
    "▟",
    "█",
)


def _clamp_mode(mode: str) -> str:
    m = (mode or "half").lower()
    if m in ("1", "solid", "full", "space"):
        return "solid"
    if m in ("2", "half"):
        return "half"
    if m in ("3", "4", "block", "quarter"):
        return "block"
    return "half"


def _px(pixels: bytes, w: int, h: int, x: int, y: int) -> RGB:
    x = 0 if x < 0 else (w - 1 if x >= w else x)
    y = 0 if y < 0 else (h - 1 if y >= h else y)
    i = (y * w + x) * 3
    return pixels[i], pixels[i + 1], pixels[i + 2]


def _avg(cols: List[RGB]) -> RGB:
    if not cols:
        return (0, 0, 0)
    n = len(cols)
    return (
        sum(c[0] for c in cols) // n,
        sum(c[1] for c in cols) // n,
        sum(c[2] for c in cols) // n,
    )


def _dist2(a: RGB, b: RGB) -> float:
    dr, dg, db = a[0] - b[0], a[1] - b[1], a[2] - b[2]
    return float(dr * dr + dg * dg + db * db)


def _best_quarter(pix: List[RGB]) -> Tuple[str, RGB, RGB]:
    """2x2 → 最佳 1/4 方块字符 + fg/bg（对齐 imgbuf/chafa block）。"""
    best_err = float("inf")
    best: Tuple[str, RGB, RGB] = (" ", _avg(pix), _avg(pix))
    for mask in range(16):
        on = [pix[i] for i in range(4) if mask & (1 << i)]
        off = [pix[i] for i in range(4) if not (mask & (1 << i))]
        if mask == 0:
            bg = _avg(pix)
            ch, fg = " ", bg
            err = sum(_dist2(p, bg) for p in pix)
        elif mask == 0xF:
            fg = _avg(pix)
            ch, bg = "█", fg
            err = sum(_dist2(p, fg) for p in pix)
        else:
            fg, bg = _avg(on), _avg(off)
            ch = BLOCK_CHARS[mask]
            err = 0.0
            for i, p in enumerate(pix):
                err += _dist2(p, fg if (mask & (1 << i)) else bg)
        if err < best_err:
            best_err = err
            best = (ch, fg, bg)
    return best


def _cell_ansi(ch: str, fg: RGB, bg: RGB) -> str:
    if ch == " " or ch == "█":
        # 纯色：用背景空格 / 前景全方块
        if ch == " ":
            return f"\033[48;2;{bg[0]};{bg[1]};{bg[2]}m "
        return f"\033[38;2;{fg[0]};{fg[1]};{fg[2]}m\033[48;2;{fg[0]};{fg[1]};{fg[2]}m█"
    return (
        f"\033[38;2;{fg[0]};{fg[1]};{fg[2]}m"
        f"\033[48;2;{bg[0]};{bg[1]};{bg[2]}m{ch}"
    )


def rgb_to_ansi_block(pixels: bytes, w: int, h: int, cols: int, rows: int, mode: str) -> str:
    """RGB24 → 终端色块。mode: solid | half | block。始终铺满 cols×rows。"""
    if w <= 0 or h <= 0 or cols <= 0 or rows <= 0 or not pixels:
        return ""
    mode = _clamp_mode(mode)
    lines: List[str] = []

    if mode == "solid":
        # 1 采样/格：全方块或背景空格
        for cy in range(rows):
            y = min(h - 1, (cy * h + h // 2) // rows)
            parts: List[str] = []
            for cx in range(cols):
                x = min(w - 1, (cx * w + w // 2) // cols)
                r, g, b = _px(pixels, w, h, x, y)
                parts.append(f"\033[48;2;{r};{g};{b}m ")
            parts.append("\033[0m")
            lines.append("".join(parts))

    elif mode == "half":
        # 1/2：上下两像素 → ▀
        for cy in range(rows):
            y0 = min(h - 1, (cy * 2) * h // max(1, rows * 2))
            y1 = min(h - 1, (cy * 2 + 1) * h // max(1, rows * 2))
            parts = []
            for cx in range(cols):
                x = min(w - 1, (cx * w + w // 2) // cols)
                top = _px(pixels, w, h, x, y0)
                bot = _px(pixels, w, h, x, y1)
                parts.append(_cell_ansi("▀", top, bot))
            parts.append("\033[0m")
            lines.append("".join(parts))

    else:
        # 1/4：2×2 → 方块字符
        for cy in range(rows):
            y0 = min(h - 1, (cy * 2) * h // max(1, rows * 2))
            y1 = min(h - 1, (cy * 2 + 1) * h // max(1, rows * 2))
            parts = []
            for cx in range(cols):
                x0 = min(w - 1, (cx * 2) * w // max(1, cols * 2))
                x1 = min(w - 1, (cx * 2 + 1) * w // max(1, cols * 2))
                pix = [
                    _px(pixels, w, h, x0, y0),
                    _px(pixels, w, h, x1, y0),
                    _px(pixels, w, h, x0, y1),
                    _px(pixels, w, h, x1, y1),
                ]
                ch, fg, bg = _best_quarter(pix)
                parts.append(_cell_ansi(ch, fg, bg))
            parts.append("\033[0m")
            lines.append("".join(parts))

    return "\r\n".join(lines)


def pixel_size(cols: int, rows: int, mode: str) -> Tuple[int, int]:
    """为模式准备采样分辨率（再映射到 cols×rows 格）。"""
    mode = _clamp_mode(mode)
    cols = max(2, int(cols))
    rows = max(2, int(rows))
    if mode == "solid":
        return cols, rows
    if mode == "half":
        return cols, rows * 2
    # block quarter
    return cols * 2, rows * 2


def resize_rgb24(pixels: bytes, src_w: int, src_h: int, dst_w: int, dst_h: int) -> bytes:
    """Nearest-neighbor resize RGB24（fill 拉伸铺满）。"""
    if src_w == dst_w and src_h == dst_h:
        return pixels
    if src_w <= 0 or src_h <= 0 or dst_w <= 0 or dst_h <= 0:
        return b""
    out = bytearray(dst_w * dst_h * 3)
    for y in range(dst_h):
        sy = min(src_h - 1, y * src_h // dst_h)
        for x in range(dst_w):
            sx = min(src_w - 1, x * src_w // dst_w)
            si = (sy * src_w + sx) * 3
            di = (y * dst_w + x) * 3
            out[di] = pixels[si]
            out[di + 1] = pixels[si + 1]
            out[di + 2] = pixels[si + 2]
    return bytes(out)


# ── Video decoders (PyAV / OpenCV / ffmpeg CLI) ───────────────────────


class VideoDecoder:
    """Decode video frames via library (preferred) or ffmpeg CLI.

    Order: PyAV (libav*) → OpenCV → ffmpeg executable.
    This is the robust path on machines whose `ffmpeg` CLI is ancient.
    """

    def __init__(self) -> None:
        self.path: Optional[str] = None
        self.backend = "none"
        self.duration: Optional[float] = None
        self.width: Optional[int] = None
        self.height: Optional[int] = None
        self._av_c = None
        self._av_stream = None
        self._av_iter = None  # sequential decode iterator
        self._av_last_t = -1.0
        self._cv = None
        self._cv_last_t = -1.0
        self._lock = threading.RLock()

    def close(self) -> None:
        with self._lock:
            if self._av_c is not None:
                try:
                    self._av_c.close()
                except Exception:
                    pass
            self._av_c = None
            self._av_stream = None
            self._av_iter = None
            self._av_last_t = -1.0
            if self._cv is not None:
                try:
                    self._cv.release()
                except Exception:
                    pass
            self._cv = None
            self._cv_last_t = -1.0
            self.backend = "none"
            self.path = None

    def open(self, path: str) -> str:
        """Open path; return backend name or raise."""
        self.close()
        path = os.path.abspath(path)
        if not os.path.isfile(path):
            raise FileNotFoundError(path)

        # 1) PyAV — direct libavcodec/libavformat (ffmpeg libraries)
        try:
            import av  # type: ignore

            c = av.open(path)
            if not c.streams.video:
                c.close()
                raise RuntimeError("no video stream")
            stream = c.streams.video[0]
            stream.thread_type = "AUTO"
            self._av_c = c
            self._av_stream = stream
            self._av_iter = None
            self._av_last_t = -1.0
            self.path = path
            self.backend = "pyav"
            try:
                if stream.duration is not None and stream.time_base is not None:
                    self.duration = float(stream.duration * stream.time_base)
                elif c.duration is not None:
                    self.duration = float(c.duration) / av.time_base
            except Exception:
                self.duration = None
            self.width = int(stream.codec_context.width or 0) or None
            self.height = int(stream.codec_context.height or 0) or None
            return self.backend
        except Exception:
            self._av_c = None
            self._av_stream = None

        # 2) OpenCV (often FFmpeg-backed)
        try:
            import cv2  # type: ignore

            cap = cv2.VideoCapture(path)
            if not cap.isOpened():
                cap.release()
                raise RuntimeError("cv2 open failed")
            self._cv = cap
            self._cv_last_t = -1.0
            self.path = path
            self.backend = "opencv"
            fps = cap.get(cv2.CAP_PROP_FPS) or 0
            n = cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0
            if fps > 0 and n > 0:
                self.duration = float(n / fps)
            self.width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0) or None
            self.height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0) or None
            return self.backend
        except Exception:
            self._cv = None

        # 3) CLI ffmpeg fallback
        if which("ffmpeg"):
            self.path = path
            self.backend = "ffmpeg_cli"
            self.duration = probe_duration(path)
            w, h = probe_size(path)
            self.width, self.height = w, h
            return self.backend

        raise RuntimeError("no video decoder (install av or opencv-python, or ffmpeg)")

    def _av_seek(self, at: float) -> None:
        import av  # type: ignore

        c = self._av_c
        stream = self._av_stream
        if c is None or stream is None:
            return
        at = max(0.0, float(at))
        try:
            tb = stream.time_base
            if tb is not None:
                offset = int(at / float(tb))
                c.seek(offset, stream=stream, any_frame=False, backward=True)
            else:
                c.seek(int(at * av.time_base))
        except Exception:
            try:
                c.seek(0)
            except Exception:
                pass
        self._av_iter = c.decode(stream)
        self._av_last_t = -1.0

    def _av_next(self):
        """Next (frame, time_sec) or (None, None)."""
        it = self._av_iter
        stream = self._av_stream
        if it is None or stream is None:
            return None, None
        try:
            frame = next(it)
        except StopIteration:
            self._av_iter = None
            return None, None
        except Exception:
            self._av_iter = None
            return None, None
        t = 0.0
        try:
            if frame.pts is not None and stream.time_base is not None:
                t = float(frame.pts * stream.time_base)
            elif frame.time is not None:
                t = float(frame.time)
        except Exception:
            t = max(0.0, self._av_last_t)
        return frame, t

    def _frame_to_rgb(self, frame, pw: int, ph: int) -> Optional[bytes]:
        try:
            # 库内缩放比 Python 重采样快
            try:
                fr = frame.reformat(width=pw, height=ph, format="rgb24")
                arr = fr.to_ndarray()
                return arr.tobytes()
            except Exception:
                arr = frame.to_ndarray(format="rgb24")
                h, w = arr.shape[0], arr.shape[1]
                return resize_rgb24(arr.tobytes(), w, h, pw, ph)
        except Exception:
            return None

    def _frame_pyav(self, at: float, pw: int, ph: int) -> Optional[bytes]:
        """顺序解码：前进只 next；回退/大跳跃才 seek。"""
        with self._lock:
            if self._av_c is None or self._av_stream is None:
                return None
            at = max(0.0, float(at))
            # 需要 seek：首次 / 回退 / 大幅超前（避免空转太久）
            if (
                self._av_iter is None
                or at < self._av_last_t - 0.15
                or (self._av_last_t >= 0 and at > self._av_last_t + 3.0)
            ):
                self._av_seek(max(0.0, at - 0.05))

            best = None
            # 向前丢帧直到到达目标时间（或略过）
            guard = 0
            while guard < 90:
                guard += 1
                frame, t = self._av_next()
                if frame is None:
                    break
                self._av_last_t = t
                best = frame
                if t + 1e-3 >= at:
                    break
            if best is None:
                return None
            return self._frame_to_rgb(best, pw, ph)

    def _frame_cv(self, at: float, pw: int, ph: int) -> Optional[bytes]:
        import cv2  # type: ignore

        with self._lock:
            cap = self._cv
            if cap is None:
                return None
            at = max(0.0, float(at))
            try:
                # 回退或大跳才 set；否则顺序 read（快很多）
                if self._cv_last_t < 0 or at < self._cv_last_t - 0.15 or at > self._cv_last_t + 3.0:
                    cap.set(cv2.CAP_PROP_POS_MSEC, at * 1000.0)
                    self._cv_last_t = at

                frame = None
                guard = 0
                while guard < 90:
                    guard += 1
                    ok, fr = cap.read()
                    if not ok or fr is None:
                        if frame is None:
                            # 重试 seek
                            cap.set(cv2.CAP_PROP_POS_MSEC, at * 1000.0)
                            ok, fr = cap.read()
                            if not ok or fr is None:
                                return None
                            frame = fr
                        break
                    frame = fr
                    # OpenCV 位置不一定准，用累计估计
                    msec = cap.get(cv2.CAP_PROP_POS_MSEC) or 0
                    t = float(msec) / 1000.0
                    self._cv_last_t = t
                    if t + 0.02 >= at:
                        break

                if frame is None:
                    return None
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                if rgb.shape[1] != pw or rgb.shape[0] != ph:
                    rgb = cv2.resize(rgb, (pw, ph), interpolation=cv2.INTER_NEAREST)
                return rgb.tobytes()
            except Exception:
                return None

    def _frame_cli(self, at: float, pw: int, ph: int) -> Optional[bytes]:
        if not self.path or not which("ffmpeg"):
            return None
        ff = which("ffmpeg") or "ffmpeg"
        cmd = [
            ff,
            "-loglevel",
            "error",
            "-ss",
            f"{max(0.0, at):.3f}",
            "-i",
            self.path,
            "-an",
            "-frames:v",
            "1",
            "-s",
            f"{pw}x{ph}",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "-",
        ]
        try:
            kwargs: Dict[str, Any] = {"timeout": 8, "stderr": subprocess.DEVNULL}
            if os.name == "nt":
                kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            out = subprocess.check_output(cmd, **kwargs)
            need = pw * ph * 3
            if len(out) < need:
                out = out + (b"\x00" * (need - len(out)))
            return out[:need]
        except Exception:
            return None

    def get_rgb(self, at: float, pw: int, ph: int) -> Optional[bytes]:
        pw = max(2, int(pw))
        ph = max(2, int(ph))
        if self.backend == "pyav":
            return self._frame_pyav(at, pw, ph)
        if self.backend == "opencv":
            return self._frame_cv(at, pw, ph)
        if self.backend == "ffmpeg_cli":
            return self._frame_cli(at, pw, ph)
        return None


# ── Session ───────────────────────────────────────────────────────────


class Session:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.path: Optional[str] = None
        self.audio_path: Optional[str] = None
        self.audio_tmp: Optional[str] = None
        self.status = "idle"
        self.volume = 30
        self.loop = False
        self.fps = 10.0
        self.cols = 80
        self.rows = 24
        self.scale = "fit"
        self.mode = "half"
        self.duration: Optional[float] = None
        self.v_width: Optional[int] = None
        self.v_height: Optional[int] = None
        self.position = 0.0
        self.seq = 0
        self.audio = None
        self.audio_name = "none"
        self.play_wall0 = 0.0
        self.play_pos0 = 0.0
        self.use_audio_clock = False
        self._stop_frame = threading.Event()
        self._frame_thread: Optional[threading.Thread] = None
        self._ffmpeg = which("ffmpeg")
        self._tmpdir = tempfile.mkdtemp(prefix="videobuf_")
        self.vdec = VideoDecoder()
        self.video_backend = "none"
        self._frame_fail = 0

    def cleanup_tmp(self) -> None:
        if self.audio_tmp and os.path.isfile(self.audio_tmp):
            try:
                os.remove(self.audio_tmp)
            except Exception:
                pass
            self.audio_tmp = None
        try:
            shutil.rmtree(self._tmpdir, ignore_errors=True)
        except Exception:
            pass

    def stop_frame_loop(self) -> None:
        self._stop_frame.set()
        t = self._frame_thread
        if t and t.is_alive() and t is not threading.current_thread():
            t.join(timeout=1.5)
        self._frame_thread = None

    def has_audio_stream(self, path: str) -> Optional[bool]:
        """True/False if known; None if probe inconclusive (still try extract)."""
        ffprobe = which("ffprobe")
        if not ffprobe:
            return None
        try:
            outp = subprocess.check_output(
                [
                    ffprobe,
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=codec_type",
                    "-of",
                    "csv=p=0",
                    path,
                ],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=8,
            )
            s = str(outp).strip().lower()
            if not s:
                return False
            return "audio" in s or s.isdigit() or len(s) > 0
        except Exception:
            return None

    def extract_audio_pyav(self, path: str) -> Optional[str]:
        """用 PyAV 解出 pcm wav（不依赖 ffmpeg CLI，设备无关）。"""
        try:
            import av  # type: ignore
            import wave
        except Exception:
            return None
        try:
            c = av.open(path)
            stream = next((s for s in c.streams if s.type == "audio"), None)
            if stream is None:
                c.close()
                return None
            resampler = av.audio.resampler.AudioResampler(
                format="s16", layout="stereo", rate=44100
            )
            parts: List[bytes] = []
            for frame in c.decode(stream):
                for f in resampler.resample(frame):
                    parts.append(bytes(f.planes[0]))
            for f in resampler.resample(None):
                parts.append(bytes(f.planes[0]))
            c.close()
            raw = b"".join(parts)
            if len(raw) < 1000:
                return None
            out = os.path.join(self._tmpdir, "audio_pyav.wav")
            with wave.open(out, "wb") as w:
                w.setnchannels(2)
                w.setsampwidth(2)
                w.setframerate(44100)
                w.writeframes(raw)
            return out
        except Exception as exc:
            emit({"ok": True, "event": "warn", "error": f"pyav audio extract: {exc}"})
            return None

    def extract_audio(self, path: str) -> Optional[str]:
        """抽出可播放音轨。just_playback 不能直接播 mp4 内 aac。"""
        # 1) ffmpeg CLI
        if self._ffmpeg:
            candidates = [
                (
                    "audio.wav",
                    [
                        self._ffmpeg,
                        "-y",
                        "-loglevel",
                        "error",
                        "-i",
                        path,
                        "-vn",
                        "-ac",
                        "2",
                        "-ar",
                        "44100",
                        "-f",
                        "wav",
                    ],
                ),
                (
                    "audio.wav",
                    [
                        self._ffmpeg,
                        "-y",
                        "-loglevel",
                        "error",
                        "-i",
                        path,
                        "-vn",
                        "-acodec",
                        "pcm_s16le",
                        "-ac",
                        "2",
                        "-ar",
                        "44100",
                    ],
                ),
            ]
            for name, base in candidates:
                out = os.path.join(self._tmpdir, name)
                cmd = list(base) + [out]
                try:
                    kwargs: Dict[str, Any] = {"timeout": 180, "capture_output": True}
                    if os.name == "nt":
                        kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
                    r = subprocess.run(cmd, **kwargs)
                    if r.returncode == 0 and os.path.isfile(out) and os.path.getsize(out) > 1000:
                        emit(
                            {
                                "ok": True,
                                "event": "warn",
                                "error": f"audio extracted ffmpeg ({os.path.getsize(out)} bytes)",
                            }
                        )
                        return out
                except Exception:
                    continue
        # 2) PyAV 兜底
        out = self.extract_audio_pyav(path)
        if out:
            emit(
                {
                    "ok": True,
                    "event": "warn",
                    "error": f"audio extracted pyav ({os.path.getsize(out)} bytes)",
                }
            )
            return out
        return None

    def grab_still(self, at: float) -> Optional[str]:
        """Decode one frame at time → ANSI（拉伸铺满 cols×rows）。"""
        if not self.path:
            return None
        cols = max(8, int(self.cols))
        rows = max(2, int(self.rows))
        # fill：采样缓冲按模式放大后拉伸到满格；fit 也先做满格（预览优先铺满）
        pw, ph = pixel_size(cols, rows, self.mode)
        raw = self.vdec.get_rgb(at, pw, ph)
        if not raw:
            return None
        return rgb_to_ansi_block(raw, pw, ph, cols, rows, self.mode)

    def emit_frame(self, ansi: str, pos: float) -> None:
        """写固定帧文件 + 短 JSON（双缓冲文件名，避免读写冲突）。"""
        self.seq += 1
        body = ansi.replace("\r\n", "\n").replace("\r", "\n")
        # 交替两个文件，nvim 读上一份时 python 写下一份
        fpath = os.path.join(self._tmpdir, f"frame_{self.seq % 2}.ansi")
        try:
            with open(fpath, "w", encoding="utf-8", newline="\n") as f:
                f.write(body)
        except Exception as exc:
            emit({"ok": False, "error": f"write frame failed: {exc}"})
            return

        fpath_out = fpath.replace("\\", "/")
        emit(
            {
                "ok": True,
                "event": "frame",
                "format": "ansi",
                "cols": self.cols,
                "rows": self.rows,
                "seq": self.seq,
                "position": float(pos or 0),
                "backend": self.video_backend,
                "mode": self.mode,
                "file": fpath_out,
                "bytes": len(body),
            }
        )

    def clock_pos(self) -> float:
        if self.use_audio_clock and self.audio is not None:
            try:
                return float(self.audio.position())
            except Exception:
                pass
        if self.status == "playing":
            return self.play_pos0 + (time.monotonic() - self.play_wall0)
        return self.position

    def status_payload(self) -> Dict[str, Any]:
        pos = self.clock_pos()
        self.position = pos
        return {
            "ok": True,
            "event": "status",
            "status": self.status,
            "path": self.path or "",
            "position": pos,
            "duration": self.duration,
            "volume": self.volume,
            "loop": self.loop,
            "fps": self.fps,
            "cols": self.cols,
            "rows": self.rows,
            "scale": self.scale,
            "mode": self.mode,
            "width": self.v_width,
            "height": self.v_height,
            "audio": self.audio_name,
            "backend": self.video_backend or "none",
        }

    def emit_status(self) -> None:
        emit(self.status_payload())

    def _handle_ended_locked(self) -> bool:
        """Return True if ended (and handled). Caller holds lock."""
        if self.loop and self.path:
            self.position = 0.0
            self.play_pos0 = 0.0
            self.play_wall0 = time.monotonic()
            if self.audio is not None and self.audio_path:
                try:
                    self.audio.play(self.audio_path, start=0.0, volume=self.volume)
                    self.use_audio_clock = True
                except Exception:
                    pass
            return False
        self.status = "stopped"
        self.position = self.duration or self.position
        emit({"ok": True, "event": "ended", "path": self.path or ""})
        self.emit_status()
        return True

    def frame_loop(self) -> None:
        """按音频时钟取帧；顺序解码，落后时丢帧追赶。"""
        while not self._stop_frame.is_set():
            t0 = time.monotonic()
            with self.lock:
                if self.status != "playing":
                    break
                fps_now = max(1.0, float(self.fps))
                interval = 1.0 / fps_now
                pos = self.clock_pos()
                if self.duration is not None and pos >= self.duration - 0.05:
                    if self._handle_ended_locked():
                        break
                    pos = 0.0
                    # 循环：强制解码器 seek
                    try:
                        if self.vdec.backend == "pyav":
                            self.vdec._av_seek(0.0)  # type: ignore[attr-defined]
                        elif self.vdec.backend == "opencv" and self.vdec._cv is not None:
                            import cv2  # type: ignore

                            self.vdec._cv.set(cv2.CAP_PROP_POS_MSEC, 0)
                            self.vdec._cv_last_t = -1.0
                    except Exception:
                        pass
                if self.audio is not None and self.use_audio_clock:
                    try:
                        if self.audio.check_ended():
                            if self._handle_ended_locked():
                                break
                            pos = 0.0
                    except Exception:
                        pass
                self.position = pos
                path = self.path

            if not path:
                break

            ansi = self.grab_still(pos)
            if self._stop_frame.is_set():
                break
            with self.lock:
                if self.status != "playing":
                    break
                if ansi:
                    self._frame_fail = 0
                    self.emit_frame(ansi, pos)
                else:
                    self._frame_fail += 1
                    if self._frame_fail == 1 or self._frame_fail % 30 == 0:
                        emit(
                            {
                                "ok": True,
                                "event": "warn",
                                "error": f"frame decode fail x{self._frame_fail} @ {pos:.2f}s ({self.video_backend})",
                            }
                        )

            # 若解码超时，立刻进入下一轮追赶（少 sleep）
            elapsed = time.monotonic() - t0
            sleep_t = interval - elapsed
            if sleep_t > 0.002:
                self._stop_frame.wait(timeout=sleep_t)
            # 落后音频超过 2 帧则完全不 sleep
            with self.lock:
                lag = self.clock_pos() - pos
            if lag > (2.0 / max(1.0, fps_now)):
                continue

    def start_playback_threads(self) -> None:
        self.stop_frame_loop()
        self._stop_frame.clear()
        # 先推一帧，避免 play 后短暂黑屏
        ansi = self.grab_still(self.position)
        if ansi:
            self.emit_frame(ansi, self.position)
        self._frame_thread = threading.Thread(target=self.frame_loop, name="videobuf-frames", daemon=True)
        self._frame_thread.start()

    def open(
        self,
        path: str,
        fps: float,
        cols: int,
        rows: int,
        scale: str,
        mode: str,
        volume: int,
        start: float,
        loop: bool,
        auto_play: bool = False,
    ) -> None:
        want_auto = False
        with self.lock:
            self.stop_frame_loop()
            if self.audio is not None:
                try:
                    self.audio.stop()
                except Exception:
                    pass
            self.cleanup_tmp()
            self._tmpdir = tempfile.mkdtemp(prefix="videobuf_")
            path = os.path.abspath(path)
            if not os.path.isfile(path):
                emit({"ok": False, "error": f"file not found: {path}"})
                return
            self.path = path
            self.fps = max(1.0, min(30.0, float(fps or 10)))
            # 限制终端格数，保证首帧快、IPC 小
            # 铺满视频窗；上限略放宽
            self.cols = max(8, min(200, int(cols or 80)))
            self.rows = max(2, min(80, int(rows or 24)))
            self.scale = scale if scale in ("fit", "fill") else "fill"
            self.mode = _clamp_mode(mode or "half")
            self.volume = max(0, min(100, int(volume)))
            self.loop = bool(loop)
            self.position = max(0.0, float(start or 0.0))
            self._frame_fail = 0

            # 1) 视频解码器
            try:
                self.video_backend = self.vdec.open(path)
            except Exception as exc:
                emit({"ok": False, "error": f"video open failed: {exc}"})
                return
            emit(
                {
                    "ok": True,
                    "event": "status",
                    "status": "opening",
                    "path": path,
                    "backend": self.video_backend,
                    "fps": self.fps,
                    "volume": self.volume,
                    "mode": self.mode,
                    "scale": self.scale,
                }
            )
            emit({"ok": True, "event": "warn", "error": f"video decoder: {self.video_backend}"})

            self.duration = self.vdec.duration or probe_duration(path)
            self.v_width = self.vdec.width
            self.v_height = self.vdec.height
            if self.v_width is None or self.v_height is None:
                w, h = probe_size(path)
                self.v_width = self.v_width or w
                self.v_height = self.v_height or h

            # 2) 同步抽音频并 load（进入 play 时必须已有 audio_path，避免「先画面后无声」）
            self.audio, self.audio_name = make_audio_engine()
            self.audio_tmp = None
            self.audio_path = None
            self.use_audio_clock = False
            self._want_audio_play = False
            emit({"ok": True, "event": "warn", "error": "extracting audio…"})
            ext = os.path.splitext(path)[1].lower()
            video_ext = {
                ".mp4",
                ".mkv",
                ".webm",
                ".avi",
                ".mov",
                ".m4v",
                ".wmv",
                ".flv",
                ".ts",
                ".mpeg",
                ".mpg",
            }
            audio_src = None
            audio_kind = ""
            try:
                if self.audio is None:
                    emit({"ok": True, "event": "warn", "error": f"no audio engine ({self.audio_name})"})
                elif ext not in video_ext:
                    try:
                        if hasattr(self.audio, "load_only"):
                            self.audio.load_only(path, volume=self.volume)
                        else:
                            self.audio.play(path, start=0, volume=self.volume)
                            self.audio.pause()
                        audio_src, audio_kind = path, "direct"
                    except Exception as exc:
                        emit({"ok": True, "event": "warn", "error": f"direct audio fail: {exc}"})
                if audio_src is None and self.audio is not None:
                    extracted = self.extract_audio(path)
                    self.audio_tmp = extracted
                    if extracted:
                        try:
                            if isinstance(self.audio, PygameEngine):
                                self.audio.set_duration(self.duration)
                            if hasattr(self.audio, "load_only"):
                                self.audio.load_only(extracted, volume=self.volume)
                            else:
                                if isinstance(self.audio, JustPlaybackEngine):
                                    self.audio._fresh()  # type: ignore[attr-defined]
                                self.audio.play(extracted, start=0, volume=self.volume)
                                self.audio.pause()
                            audio_src, audio_kind = extracted, "wav"
                        except Exception as exc:
                            emit({"ok": True, "event": "warn", "error": f"audio load failed: {exc}"})
                    else:
                        emit({"ok": True, "event": "warn", "error": "audio extract failed"})
                if audio_src:
                    self.audio_path = audio_src
                    self.use_audio_clock = True
                    emit(
                        {
                            "ok": True,
                            "event": "warn",
                            "error": f"audio ready ({self.audio_name}, {audio_kind}) vol={self.volume}%",
                        }
                    )
            except Exception as exc:
                emit({"ok": True, "event": "warn", "error": f"audio setup: {exc}"})

            # 3) 首帧（音频已就绪）
            self.status = "paused"
            ansi = self.grab_still(self.position)
            if ansi:
                self.emit_frame(ansi, self.position)
            else:
                emit(
                    {
                        "ok": True,
                        "event": "warn",
                        "error": f"failed to decode first frame (backend={self.video_backend})",
                    }
                )
            self.emit_status()
            want_auto = bool(auto_play)

        # 锁外自动播放，避免持锁 start 帧线程
        if want_auto:
            self.play()

    def _begin_play_locked(self) -> None:
        """已持有 self.lock。从 paused/stopped 进入 playing。"""
        self._want_audio_play = True
        if self.status == "playing":
            if self.audio is not None and self.audio_path:
                try:
                    st = self.audio.status()
                    if st != "playing":
                        self.audio.play(
                            self.audio_path,
                            start=self.clock_pos(),
                            volume=self.volume,
                        )
                        self.use_audio_clock = True
                except Exception as exc:
                    emit({"ok": True, "event": "warn", "error": f"audio re-arm: {exc}"})
            self.emit_status()
            return
        self.status = "playing"
        self.play_pos0 = self.position
        self.play_wall0 = time.monotonic()
        if self.audio is not None and self.audio_path:
            try:
                self.audio.play(self.audio_path, start=self.position, volume=self.volume)
                self.use_audio_clock = True
                emit(
                    {
                        "ok": True,
                        "event": "warn",
                        "error": f"audio playing @ {self.position:.1f}s vol={self.volume}%",
                    }
                )
            except Exception as exc:
                self.use_audio_clock = False
                emit({"ok": True, "event": "warn", "error": f"audio play: {exc}"})
        else:
            self.use_audio_clock = False
            emit({"ok": True, "event": "warn", "error": "NO audio_path — silent"})
        self.start_playback_threads()
        self.emit_status()

    def play(self) -> None:
        with self.lock:
            if not self.path:
                emit({"ok": False, "error": "no video open"})
                return
            self._begin_play_locked()

    def pause(self) -> None:
        # 关键顺序：先停音频（不长时间占锁），再停帧线程，避免 1–2s 拖尾
        with self.lock:
            if self.status != "playing":
                self.emit_status()
                return
            self.position = self.clock_pos()
            self.status = "paused"
            self._want_audio_play = False
            audio = self.audio
        # 锁外立刻静音/暂停
        if audio is not None:
            try:
                audio.pause()
            except Exception:
                try:
                    audio.stop()
                except Exception:
                    pass
        # 再停画面线程（可能 join 稍久，但声音已停）
        self.stop_frame_loop()
        with self.lock:
            try:
                ansi = self.grab_still(self.position)
                if ansi:
                    self.emit_frame(ansi, self.position)
            except Exception:
                pass
            self.emit_status()

    def toggle(self) -> None:
        if self.status == "playing":
            self.pause()
        else:
            self.play()

    def stop(self) -> None:
        with self.lock:
            self.stop_frame_loop()
            self.position = 0.0
            self.status = "stopped"
            if self.audio is not None:
                try:
                    self.audio.stop()
                except Exception:
                    pass
            ansi = self.grab_still(0.0)
            if ansi:
                self.emit_frame(ansi, 0.0)
            self.emit_status()

    def seek(self, position: float) -> None:
        with self.lock:
            position = max(0.0, float(position))
            if self.duration is not None:
                position = min(position, self.duration)
            was_playing = self.status == "playing"
            self.stop_frame_loop()
            self.position = position
            self.play_pos0 = position
            self.play_wall0 = time.monotonic()
            if self.audio is not None and self.audio_path:
                try:
                    # 播放中：完整 play 到目标位置（比单独 seek 更稳）
                    if was_playing or self._want_audio_play:
                        self.audio.play(self.audio_path, start=position, volume=self.volume)
                        self.use_audio_clock = True
                    else:
                        try:
                            self.audio.seek(position)
                        except Exception:
                            self.audio.play(self.audio_path, start=position, volume=self.volume)
                            self.audio.pause()
                except Exception as exc:
                    emit({"ok": True, "event": "warn", "error": f"audio seek: {exc}"})
            if was_playing:
                self.status = "playing"
                self.start_playback_threads()
            else:
                if self.status == "playing":
                    self.status = "paused"
                ansi = self.grab_still(position)
                if ansi:
                    self.emit_frame(ansi, position)
            self.emit_status()

    def set_volume(self, volume: int) -> None:
        with self.lock:
            self.volume = max(0, min(100, int(volume)))
            if self.audio is not None:
                try:
                    self.audio.set_volume(self.volume)
                except Exception:
                    pass
            self.emit_status()

    def set_fps(self, fps: float) -> None:
        with self.lock:
            self.fps = max(1.0, min(30.0, float(fps)))
            was = self.status == "playing"
            if was:
                self.position = self.clock_pos()
                self.play_pos0 = self.position
                self.play_wall0 = time.monotonic()
                self.stop_frame_loop()
                self.start_playback_threads()
            self.emit_status()

    def resize(self, cols: int, rows: int, scale: Optional[str] = None, mode: Optional[str] = None) -> None:
        with self.lock:
            self.cols = max(8, min(200, int(cols)))
            self.rows = max(2, min(80, int(rows)))
            if scale in ("fit", "fill"):
                self.scale = scale
            if mode is not None:
                self.mode = _clamp_mode(mode)
            was = self.status == "playing"
            if was:
                self.position = self.clock_pos()
                self.play_pos0 = self.position
                self.play_wall0 = time.monotonic()
                self.stop_frame_loop()
                self.start_playback_threads()
            else:
                ansi = self.grab_still(self.position)
                if ansi:
                    self.emit_frame(ansi, self.position)
            self.emit_status()

    def set_loop(self, loop: bool) -> None:
        with self.lock:
            self.loop = bool(loop)
            self.emit_status()

    def quit(self) -> None:
        with self.lock:
            self.stop_frame_loop()
            if self.audio is not None:
                try:
                    self.audio.stop()
                except Exception:
                    pass
            try:
                self.vdec.close()
            except Exception:
                pass
            self.cleanup_tmp()
            self.status = "idle"


def handle(cmd: Dict[str, Any], sess: Session) -> None:
    c = (cmd.get("cmd") or "").lower()
    if c == "ping":
        emit({"ok": True, "event": "pong"})
        return
    if c == "quit":
        sess.quit()
        emit({"ok": True, "event": "bye"})
        raise SystemExit(0)
    if c == "status":
        sess.emit_status()
        return
    if c == "open":
        sess.open(
            path=str(cmd.get("path") or ""),
            fps=float(cmd.get("fps") or 10),
            cols=int(cmd.get("cols") or 80),
            rows=int(cmd.get("rows") or 24),
            scale=str(cmd.get("scale") or "fill"),
            mode=str(cmd.get("mode") or "half"),
            volume=int(cmd.get("volume") if cmd.get("volume") is not None else 30),
            start=float(cmd.get("start") or 0),
            loop=bool(cmd.get("loop") or False),
            auto_play=bool(cmd.get("auto_play") or False),
        )
        return
    if c == "play":
        sess.play()
        return
    if c == "pause":
        sess.pause()
        return
    if c == "toggle":
        sess.toggle()
        return
    if c == "stop":
        sess.stop()
        return
    if c == "seek":
        sess.seek(float(cmd.get("position") or 0))
        return
    if c == "volume":
        sess.set_volume(int(cmd.get("volume") or 0))
        return
    if c == "fps":
        sess.set_fps(float(cmd.get("fps") or 10))
        return
    if c == "resize":
        sess.resize(
            cols=int(cmd.get("cols") or sess.cols),
            rows=int(cmd.get("rows") or sess.rows),
            scale=cmd.get("scale"),
            mode=cmd.get("mode"),
        )
        return
    if c == "loop":
        sess.set_loop(bool(cmd.get("loop")))
        return
    emit({"ok": False, "error": f"unknown cmd: {c}"})


def main() -> None:
    _boot_log(f"main start events={_EVENT_PATH!r}")
    sess = Session()
    backends = []
    try:
        import av  # noqa: F401

        backends.append("pyav")
        _boot_log("av ok")
    except Exception as exc:
        _boot_log(f"av no: {exc}")
    try:
        import cv2  # noqa: F401

        backends.append("opencv")
        _boot_log("cv2 ok")
    except Exception as exc:
        _boot_log(f"cv2 no: {exc}")
    if which("ffmpeg"):
        backends.append("ffmpeg_cli")
    emit(
        {
            "ok": True,
            "event": "ready",
            "backend": backends[0] if backends else "none",
            "decoders": backends,
            "ffmpeg": bool(which("ffmpeg")),
            "events": _EVENT_PATH or "",
        }
    )
    _boot_log(f"ready emitted backends={backends}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except Exception as exc:
            emit({"ok": False, "error": f"bad json: {exc}"})
            continue
        if not isinstance(cmd, dict):
            emit({"ok": False, "error": "cmd must be object"})
            continue
        try:
            handle(cmd, sess)
        except SystemExit:
            raise
        except Exception as exc:
            emit({"ok": False, "error": str(exc)})
    sess.quit()


if __name__ == "__main__":
    main()
