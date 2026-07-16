#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Long-lived audio player for music.nvim (stdin/stdout JSON lines).

Protocol — one JSON object per line.

Request (nvim → python):
  {"cmd":"play","path":"...","start":0.0,"volume":70,"loop":false}
  {"cmd":"pause"} | {"cmd":"resume"} | {"cmd":"toggle"} | {"cmd":"stop"}
  {"cmd":"seek","position":12.3}          # absolute seconds
  {"cmd":"volume","volume":50}            # 0–100
  {"cmd":"loop","loop":true}
  {"cmd":"status"} | {"cmd":"quit"} | {"cmd":"ping"}

Response (python → nvim):
  {"ok":true,"event":"status","status":"playing|paused|stopped|idle",
   "path":"...","position":1.2,"duration":180.0,"volume":70,"loop":false,"backend":"pygame"}
  {"ok":true,"event":"ended","path":"..."}
  {"ok":true,"event":"ready","backend":"pygame"}
  {"ok":false,"error":"..."}
"""

from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
from typing import Any, Dict, Optional

# Must be set before any pygame import (including transitive)
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"

# Force unbuffered-ish line IO
try:
    sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)  # type: ignore[attr-defined]
    sys.stderr.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except Exception:
    pass


def emit(obj: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def probe_duration(path: str) -> Optional[float]:
    """Best-effort duration in seconds."""
    # WAV
    try:
        import wave

        with wave.open(path, "rb") as w:
            frames = w.getnframes()
            rate = w.getframerate()
            if rate > 0:
                return frames / float(rate)
    except Exception:
        pass

    # mutagen (optional)
    try:
        from mutagen import File as MFile  # type: ignore

        m = MFile(path)
        if m is not None and getattr(m, "info", None) is not None:
            length = getattr(m.info, "length", None)
            if length and length > 0:
                return float(length)
    except Exception:
        pass

    # ffprobe (optional)
    import shutil
    import subprocess

    ffprobe = shutil.which("ffprobe")
    if ffprobe:
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
                timeout=8,
            )
            n = float(out.strip())
            if n > 0:
                return n
        except Exception:
            pass

    return None


class JustPlaybackEngine:
    """Preferred engine: seek + volume + position are reliable."""

    name = "just_playback"

    def __init__(self) -> None:
        from just_playback import Playback  # type: ignore

        self._pb = Playback()
        self._path: Optional[str] = None
        self._loop = False
        self._volume = 0.7
        self._status = "idle"
        self._duration: Optional[float] = None

    def play(self, path: str, start: float = 0.0, volume: int = 70, loop: bool = False) -> None:
        self._path = path
        self._loop = loop
        self._volume = max(0.0, min(1.0, volume / 100.0))
        self._pb.load_file(path)
        self._duration = float(self._pb.duration) if self._pb.duration else probe_duration(path)
        self._pb.set_volume(self._volume)
        self._pb.play()
        if start and start > 0.05:
            try:
                self._pb.seek(start)
            except Exception:
                pass
        if loop:
            try:
                self._pb.loop_at_end(True)  # type: ignore[attr-defined]
            except Exception:
                pass
        self._status = "playing"

    def pause(self) -> None:
        if self._status == "playing":
            self._pb.pause()
            self._status = "paused"

    def resume(self) -> None:
        if self._status == "paused":
            self._pb.resume()
            self._status = "playing"
        elif self._status in ("stopped", "idle") and self._path:
            self.play(self._path, start=self.position(), volume=int(self._volume * 100), loop=self._loop)

    def stop(self) -> None:
        try:
            self._pb.stop()
        except Exception:
            pass
        self._status = "stopped"

    def seek(self, position: float) -> None:
        position = max(0.0, float(position))
        if self._duration is not None:
            position = min(position, self._duration)
        try:
            self._pb.seek(position)
        except Exception as exc:
            raise RuntimeError(f"seek failed: {exc}") from exc
        if self._status == "stopped":
            self._status = "paused"

    def set_volume(self, volume: int) -> None:
        self._volume = max(0.0, min(1.0, volume / 100.0))
        self._pb.set_volume(self._volume)

    def set_loop(self, loop: bool) -> None:
        self._loop = bool(loop)
        try:
            self._pb.loop_at_end(self._loop)  # type: ignore[attr-defined]
        except Exception:
            pass

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
        # detect natural end
        try:
            active = bool(self._pb.active)
            playing = bool(self._pb.playing)
            if self._status == "playing" and not playing and not active:
                self._status = "stopped"
            elif self._status == "playing" and not playing and active:
                # paused internally?
                pass
        except Exception:
            pass
        return self._status

    def path(self) -> Optional[str]:
        return self._path

    def volume_pct(self) -> int:
        return int(round(self._volume * 100))

    def loop(self) -> bool:
        return self._loop

    def check_ended(self) -> bool:
        if self._status != "playing":
            return False
        try:
            if self._loop:
                return False
            if not self._pb.playing and not self._pb.active:
                self._status = "stopped"
                return True
            # near end fallback
            dur = self.duration()
            pos = self.position()
            if dur and pos >= dur - 0.15 and not self._pb.playing:
                self._status = "stopped"
                return True
        except Exception:
            pass
        return False


class PygameEngine:
    """Fallback using pygame.mixer.music (widely available)."""

    name = "pygame"

    def __init__(self) -> None:
        os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
        # Prevent "Hello from the pygame community" on stdout (breaks JSON IPC)
        os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
        import pygame

        self._pg = pygame
        if not pygame.mixer.get_init():
            pygame.mixer.init(frequency=44100, size=-16, channels=2, buffer=2048)
        self._path: Optional[str] = None
        self._loop = False
        self._volume = 0.7
        self._status = "idle"
        self._duration: Optional[float] = None
        self._base_pos = 0.0  # absolute seconds at last play/seek/resume
        self._play_t0 = 0.0  # wall time when play/resume started
        self._paused_pos = 0.0

    def play(self, path: str, start: float = 0.0, volume: int = 70, loop: bool = False) -> None:
        self._path = path
        self._loop = loop
        self.set_volume(volume)
        self._duration = probe_duration(path)
        music = self._pg.mixer.music
        music.load(path)
        music.set_volume(self._volume)
        start = max(0.0, float(start or 0.0))
        loops = -1 if loop else 0
        # pygame 2: play(start=seconds) for supported formats
        try:
            music.play(loops=loops, start=start)
        except TypeError:
            music.play(loops=loops)
            if start > 0.05:
                try:
                    music.set_pos(start)
                except Exception:
                    pass
        except Exception:
            music.play(loops=loops)
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
            self._pg.mixer.music.pause()
            self._status = "paused"

    def resume(self) -> None:
        if self._status == "paused":
            self._pg.mixer.music.unpause()
            self._base_pos = self._paused_pos
            self._play_t0 = time.monotonic()
            self._status = "playing"
        elif self._status in ("stopped", "idle") and self._path:
            self.play(self._path, start=self._paused_pos or 0.0, volume=self.volume_pct(), loop=self._loop)

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
        was_playing = self._status == "playing"
        music = self._pg.mixer.music
        if not self._path:
            raise RuntimeError("no track loaded")
        # Restart from position (most reliable across formats)
        music.stop()
        music.load(self._path)
        music.set_volume(self._volume)
        loops = -1 if self._loop else 0
        try:
            music.play(loops=loops, start=position)
        except Exception:
            music.play(loops=loops)
            try:
                music.set_pos(position)
            except Exception:
                pass
        self._base_pos = position
        self._play_t0 = time.monotonic()
        self._paused_pos = position
        if was_playing:
            self._status = "playing"
        else:
            music.pause()
            self._status = "paused"

    def set_volume(self, volume: int) -> None:
        self._volume = max(0.0, min(1.0, int(volume) / 100.0))
        try:
            self._pg.mixer.music.set_volume(self._volume)
        except Exception:
            pass

    def set_loop(self, loop: bool) -> None:
        # pygame loop is set at play(); store flag for next play/seek
        self._loop = bool(loop)

    def position(self) -> float:
        if self._status == "paused":
            return max(0.0, self._paused_pos)
        if self._status != "playing":
            return max(0.0, self._base_pos)
        # Prefer mixer get_pos (ms since play/unpause); fall back to wall clock
        ms = self._pg.mixer.music.get_pos()
        if ms is not None and ms >= 0:
            pos = self._base_pos + ms / 1000.0
        else:
            pos = self._base_pos + (time.monotonic() - self._play_t0)
        if self._duration is not None:
            pos = min(pos, self._duration)
        return max(0.0, pos)

    def duration(self) -> Optional[float]:
        return self._duration

    def status(self) -> str:
        return self._status

    def path(self) -> Optional[str]:
        return self._path

    def volume_pct(self) -> int:
        return int(round(self._volume * 100))

    def loop(self) -> bool:
        return self._loop

    def check_ended(self) -> bool:
        if self._status != "playing":
            return False
        if self._loop:
            # pygame -1 loops forever
            return False
        busy = self._pg.mixer.music.get_busy()
        if not busy:
            # get_busy can be false briefly; confirm with position near end or stop
            pos = self.position()
            dur = self._duration
            if dur is None or pos >= max(0.0, dur - 0.35) or pos < 0.05:
                # if just started and not busy — treat as ended only if pos large or dur known short
                if dur is not None and pos >= max(0.0, dur - 0.35):
                    self._status = "stopped"
                    self._base_pos = dur
                    return True
                if dur is None and pos > 0.5:
                    self._status = "stopped"
                    return True
                # not busy at start can mean load failure — report ended only after some progress
                if dur is not None and dur <= 0.5:
                    self._status = "stopped"
                    return True
        return False


def create_engine():
    try:
        eng = JustPlaybackEngine()
        return eng
    except Exception:
        pass
    try:
        eng = PygameEngine()
        return eng
    except Exception as exc:
        emit({"ok": False, "error": f"no audio backend: install pygame or just_playback ({exc})"})
        raise SystemExit(2) from exc


class PlayerApp:
    def __init__(self) -> None:
        self.engine = create_engine()
        self._cmd_q: "queue.Queue[str]" = queue.Queue()
        self._running = True

    def snapshot(self, event: str = "status") -> Dict[str, Any]:
        eng = self.engine
        return {
            "ok": True,
            "event": event,
            "status": eng.status(),
            "path": eng.path(),
            "position": eng.position(),
            "duration": eng.duration(),
            "volume": eng.volume_pct(),
            "loop": eng.loop(),
            "backend": eng.name,
        }

    def handle(self, msg: Dict[str, Any]) -> None:
        cmd = (msg.get("cmd") or "").lower()
        eng = self.engine

        if cmd == "ping":
            emit({"ok": True, "event": "pong", "backend": eng.name})
            return
        if cmd == "quit":
            eng.stop()
            self._running = False
            emit({"ok": True, "event": "bye"})
            return
        if cmd == "status":
            emit(self.snapshot("status"))
            return
        if cmd == "play":
            path = msg.get("path") or ""
            if not path or not os.path.isfile(path):
                emit({"ok": False, "error": f"file not found: {path}"})
                return
            start = float(msg.get("start") or 0.0)
            volume = int(msg.get("volume") if msg.get("volume") is not None else eng.volume_pct())
            loop = bool(msg.get("loop") if msg.get("loop") is not None else eng.loop())
            eng.play(path, start=start, volume=volume, loop=loop)
            emit(self.snapshot("status"))
            return
        if cmd == "pause":
            eng.pause()
            emit(self.snapshot("status"))
            return
        if cmd == "resume":
            eng.resume()
            emit(self.snapshot("status"))
            return
        if cmd == "toggle":
            if eng.status() == "playing":
                eng.pause()
            else:
                eng.resume()
            emit(self.snapshot("status"))
            return
        if cmd == "stop":
            eng.stop()
            emit(self.snapshot("status"))
            return
        if cmd == "seek":
            pos = msg.get("position")
            if pos is None:
                emit({"ok": False, "error": "seek requires position"})
                return
            try:
                eng.seek(float(pos))
            except Exception as exc:
                emit({"ok": False, "error": str(exc)})
                return
            emit(self.snapshot("status"))
            return
        if cmd == "volume":
            vol = msg.get("volume")
            if vol is None:
                emit({"ok": False, "error": "volume required"})
                return
            eng.set_volume(int(vol))
            emit(self.snapshot("status"))
            return
        if cmd == "loop":
            eng.set_loop(bool(msg.get("loop")))
            emit(self.snapshot("status"))
            return

        emit({"ok": False, "error": f"unknown cmd: {cmd}"})

    def stdin_reader(self) -> None:
        for line in sys.stdin:
            if not self._running:
                break
            self._cmd_q.put(line)

    def run(self) -> int:
        emit({"ok": True, "event": "ready", "backend": self.engine.name})
        t = threading.Thread(target=self.stdin_reader, daemon=True)
        t.start()

        last_status_emit = 0.0
        while self._running:
            try:
                line = self._cmd_q.get(timeout=0.05)
            except queue.Empty:
                line = None

            if line is not None:
                line = line.strip()
                if line:
                    try:
                        msg = json.loads(line)
                        if not isinstance(msg, dict):
                            emit({"ok": False, "error": "message must be object"})
                        else:
                            self.handle(msg)
                    except json.JSONDecodeError as exc:
                        emit({"ok": False, "error": f"bad json: {exc}"})
                    except Exception as exc:
                        emit({"ok": False, "error": str(exc)})

            # natural end detection
            try:
                if self.engine.check_ended():
                    emit(self.snapshot("ended"))
            except Exception:
                pass

            # light periodic status while playing (helps UI even if Lua poll lags)
            now = time.monotonic()
            if self.engine.status() == "playing" and now - last_status_emit > 0.25:
                last_status_emit = now
                # optional: don't spam; Lua will poll via "status" cmd
                # emit(self.snapshot("status"))

        try:
            self.engine.stop()
        except Exception:
            pass
        return 0


def main() -> int:
    try:
        return PlayerApp().run()
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
        return code
    except Exception as exc:
        emit({"ok": False, "error": f"fatal: {exc}"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
