# -*- coding: utf-8 -*-
"""music.nvim — Windows winmm.dll (MCI) MIDI player daemon (JSON lines).

使用系统自带 winmm.dll 的 sequencer 播放 .mid：
默认走 Microsoft GS Wavetable Synth（或系统当前 MIDI 出端口）。

依赖: 仅 Python3 标准库 + Windows。
协议同前: load / load_preset / play / pause / resume / toggle / stop / volume / status / presets / quit
"""
from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)  # type: ignore
    sys.stderr.reconfigure(encoding="utf-8")  # type: ignore
except Exception:
    pass


def emit(obj: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# winmm.dll MCI
# ---------------------------------------------------------------------------

class WinmmMidi:
    """ctypes wrapper around mciSendStringW for MIDI sequencer."""

    ALIAS = "nvimplugins_music_mid"

    def __init__(self) -> None:
        if sys.platform != "win32":
            raise RuntimeError("winmm MIDI playback requires Windows")
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        self._winmm = ctypes.WinDLL("winmm")
        self._winmm.mciSendStringW.argtypes = [
            wintypes.LPCWSTR,
            wintypes.LPWSTR,
            wintypes.UINT,
            wintypes.HANDLE,
        ]
        self._winmm.mciSendStringW.restype = wintypes.DWORD
        self._winmm.mciGetErrorStringW.argtypes = [
            wintypes.DWORD,
            wintypes.LPWSTR,
            wintypes.UINT,
        ]
        self._winmm.mciGetErrorStringW.restype = wintypes.BOOL
        self._open_path: Optional[str] = None

    def send(self, cmd: str, ignore_error: bool = False) -> str:
        buf = self._ctypes.create_unicode_buffer(1024)
        err = self._winmm.mciSendStringW(cmd, buf, 1023, None)
        if err:
            ebuf = self._ctypes.create_unicode_buffer(512)
            self._winmm.mciGetErrorStringW(err, ebuf, 511)
            if ignore_error:
                return ""
            raise RuntimeError(ebuf.value or f"MCI error {err}: {cmd}")
        return buf.value or ""

    def close(self) -> None:
        self.send(f"close {self.ALIAS}", ignore_error=True)
        self._open_path = None

    def open(self, path: str) -> None:
        path = os.path.abspath(path)
        if not os.path.isfile(path):
            raise FileNotFoundError(path)
        self.close()
        # 路径含空格/中文：加引号
        p = path.replace("/", "\\")
        self.send(f'open "{p}" type sequencer alias {self.ALIAS}')
        self.send(f"set {self.ALIAS} time format milliseconds", ignore_error=True)
        self._open_path = path

    def play(self, from_ms: Optional[int] = None) -> None:
        if from_ms is not None and from_ms > 0:
            self.send(f"play {self.ALIAS} from {int(from_ms)}")
        else:
            self.send(f"play {self.ALIAS}")

    def pause(self) -> None:
        self.send(f"pause {self.ALIAS}", ignore_error=True)

    def resume(self) -> None:
        # 部分系统用 resume，失败则 play
        try:
            self.send(f"resume {self.ALIAS}")
        except Exception:
            self.send(f"play {self.ALIAS}")

    def stop(self) -> None:
        self.send(f"stop {self.ALIAS}", ignore_error=True)
        self.send(f"seek {self.ALIAS} to start", ignore_error=True)

    def mode(self) -> str:
        try:
            return (self.send(f"status {self.ALIAS} mode") or "").strip().lower()
        except Exception:
            return ""

    def position_ms(self) -> int:
        try:
            s = self.send(f"status {self.ALIAS} position")
            return int(float(s or 0))
        except Exception:
            return 0

    def length_ms(self) -> int:
        try:
            s = self.send(f"status {self.ALIAS} length")
            return int(float(s or 0))
        except Exception:
            return 0

    def set_volume(self, vol_0_1000: int) -> None:
        """MCI 音量 0..1000；对 MIDI 设备可能无效，尽力设置。"""
        v = max(0, min(1000, int(vol_0_1000)))
        self.send(f"setaudio {self.ALIAS} volume to {v}", ignore_error=True)


# ---------------------------------------------------------------------------
# Minimal MIDI writer (for presets)
# ---------------------------------------------------------------------------

def _varlen(value: int) -> bytes:
    value = int(value)
    if value < 0:
        value = 0
    buf = [value & 0x7F]
    value >>= 7
    while value:
        buf.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(buf))


def _track_chunk(events: List[Tuple[int, bytes]]) -> bytes:
    """events: list of (abs_tick, event_bytes without delta)."""
    events = sorted(events, key=lambda x: x[0])
    data = bytearray()
    last = 0
    for tick, payload in events:
        delta = max(0, tick - last)
        last = tick
        data += _varlen(delta)
        data += payload
    # end of track
    data += _varlen(0) + bytes([0xFF, 0x2F, 0x00])
    return b"MTrk" + struct.pack(">I", len(data)) + bytes(data)


def write_midi_file(
    path: str,
    tracks: List[Dict[str, Any]],
    tempo_bpm: float = 120.0,
    tpb: int = 480,
) -> None:
    """Write SMF type 1 from preset-like tracks."""
    tempo_bpm = max(40.0, min(240.0, float(tempo_bpm)))
    tpb = int(tpb) or 480
    us_per_qn = int(60_000_000 / tempo_bpm)

    # tempo track
    tempo_ev = [
        (0, bytes([0xFF, 0x51, 0x03, (us_per_qn >> 16) & 0xFF, (us_per_qn >> 8) & 0xFF, us_per_qn & 0xFF])),
    ]
    chunks = [_track_chunk(tempo_ev)]

    for tr in tracks:
        program = int(tr.get("program") or 0) & 0x7F
        channel = int(tr.get("channel") or 0) & 0x0F
        notes = tr.get("notes") or []
        ev: List[Tuple[int, bytes]] = []
        # program change
        ev.append((0, bytes([0xC0 | channel, program])))
        for n in notes:
            tick = int(n["tick"])
            dur = max(1, int(n["dur"]))
            note = int(n["note"]) & 0x7F
            vel = max(1, min(127, int(n.get("vel") or 90)))
            ev.append((tick, bytes([0x90 | channel, note, vel])))
            ev.append((tick + dur, bytes([0x80 | channel, note, 0x40])))
        if len(ev) > 1:
            chunks.append(_track_chunk(ev))

    ntrks = len(chunks)
    header = b"MThd" + struct.pack(">IHHH", 6, 1 if ntrks > 1 else 0, ntrks, tpb)
    Path(path).write_bytes(header + b"".join(chunks))


# ---------------------------------------------------------------------------
# Presets (note data → temp .mid → winmm)
# ---------------------------------------------------------------------------

def _n(tick: int, dur: int, note: int, vel: int = 90) -> Dict[str, int]:
    return {"tick": tick, "dur": dur, "note": note, "vel": vel}


def build_presets() -> Dict[str, Dict[str, Any]]:
    q, e, h = 480, 240, 960
    presets: Dict[str, Dict[str, Any]] = {}

    tw_notes = [
        60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60,
        67, 67, 65, 65, 64, 64, 62, 67, 67, 65, 65, 64, 64, 62,
        60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60,
    ]
    tw_durs = [
        q, q, q, q, q, q, h, q, q, q, q, q, q, h,
        q, q, q, q, q, q, h, q, q, q, q, q, q, h,
        q, q, q, q, q, q, h, q, q, q, q, q, q, h,
    ]
    mel, t = [], 0
    for note, dur in zip(tw_notes, tw_durs):
        mel.append(_n(t, dur, note, 95))
        t += dur
    bass = [_n(i * h, h, root, 70) for i, root in enumerate([48, 48, 53, 48, 50, 43, 48] * 4)]
    presets["twinkle"] = {
        "name": "Twinkle Twinkle",
        "title": "小星星 / Twinkle",
        "tempo": 100,
        "tpb": 480,
        "tracks": [
            {"name": "Melody", "program": 0, "channel": 0, "notes": mel},
            {"name": "Pad", "program": 89, "channel": 1, "notes": bass},
        ],
    }

    ode = [64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 64, 62, 62]
    ode_d = [q, q, q, q, q, q, q, q, q, q, q, q, h, e, e + q]
    mel, t = [], 0
    for note, dur in zip(ode * 2, ode_d * 2):
        mel.append(_n(t, dur, note, 92))
        t += dur
    presets["ode"] = {
        "name": "Ode to Joy",
        "title": "欢乐颂 / Ode to Joy",
        "tempo": 112,
        "tpb": 480,
        "tracks": [
            {"name": "Strings", "program": 48, "channel": 0, "notes": mel},
            {
                "name": "Bass",
                "program": 32,
                "channel": 1,
                "notes": [_n(i * q, q, 48 + (i % 4) * 2, 75) for i in range(len(mel))],
            },
        ],
    }

    scales = []
    t = 0
    for prog, base, ch in [(0, 60, 0), (24, 55, 1), (40, 67, 2), (56, 60, 3), (73, 72, 4)]:
        notes = []
        for i, off in enumerate([0, 2, 4, 5, 7, 9, 11, 12, 11, 9, 7, 5, 4, 2, 0]):
            notes.append(_n(t + i * e, e, base + off, 88))
        scales.append({"name": f"P{prog}", "program": prog, "channel": ch, "notes": notes})
        t += 16 * e
    presets["scales"] = {
        "name": "Instrument Tour",
        "title": "乐器巡演 / Scales",
        "tempo": 120,
        "tpb": 480,
        "tracks": scales,
    }

    groove_mel, t = [], 0
    riff = [60, 63, 65, 63, 60, 58, 60, 63]
    for _ in range(4):
        for note in riff:
            groove_mel.append(_n(t, e, note, 90))
            t += e
    drums = []
    for bar in range(4):
        base = bar * 4 * q
        for beat in range(4):
            tk = base + beat * q
            drums.append(_n(tk, e, 36, 100))
            if beat in (1, 3):
                drums.append(_n(tk, e, 38, 85))
            drums.append(_n(tk, e // 2, 42, 60))
            drums.append(_n(tk + e, e // 2, 42, 45))
    presets["groove"] = {
        "name": "Mini Groove",
        "title": "迷你律动 / Groove",
        "tempo": 100,
        "tpb": 480,
        "tracks": [
            {"name": "Lead", "program": 80, "channel": 0, "notes": groove_mel},
            {
                "name": "Bass",
                "program": 33,
                "channel": 1,
                "notes": [_n(i * q, q, 36 + (i % 2) * 5, 80) for i in range(16)],
            },
            {"name": "Drums", "program": 0, "channel": 9, "notes": drums},
        ],
    }

    sak = [67, 69, 67, 64, 62, 64, 67, 69, 71, 69, 67, 64, 62]
    sak_d = [q, q, q, q, h, q, q, q, q, q, q, q, h]
    mel, t = [], 0
    for note, dur in zip(sak, sak_d):
        mel.append(_n(t, dur, note, 88))
        t += dur
    presets["sakura"] = {
        "name": "Pentatonic Air",
        "title": "五声音韵 / Pentatonic",
        "tempo": 88,
        "tpb": 480,
        "tracks": [
            {"name": "Flute", "program": 73, "channel": 0, "notes": mel},
            {
                "name": "Harp",
                "program": 46,
                "channel": 1,
                "notes": [_n(i * h, h, 50 + (i % 3) * 2, 55) for i in range(8)],
            },
        ],
    }
    return presets


PRESETS = build_presets()


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

def _preset_cache_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("TMP") or tempfile.gettempdir()
    d = Path(base) / "nvimplugins-music-presets"
    d.mkdir(parents=True, exist_ok=True)
    return d


def ensure_preset_mid(key: str, song: Dict[str, Any]) -> str:
    """把预设写成缓存 .mid（已存在则直接复用，避免每次重写）。"""
    path = _preset_cache_dir() / f"{key}.mid"
    if path.is_file() and path.stat().st_size > 32:
        return str(path)
    write_midi_file(
        str(path),
        song.get("tracks") or [],
        tempo_bpm=float(song.get("tempo") or 120),
        tpb=int(song.get("tpb") or 480),
    )
    return str(path)


class MidiEngine:
    def __init__(self) -> None:
        self.midi = WinmmMidi()
        self.volume = 70  # 0..100
        self.status = "idle"
        self.song: Optional[Dict[str, Any]] = None
        self.title = ""
        self.duration = 0.0
        self.position = 0.0
        self._path: Optional[str] = None
        self._temp_files: List[str] = []
        self._stop_flag = threading.Event()
        self._monitor: Optional[threading.Thread] = None
        self._pause_ms = 0
        # 后台预写预设 mid，缩短首次点播等待
        threading.Thread(target=self._warm_presets, daemon=True).start()

    def _warm_presets(self) -> None:
        try:
            for key, song in PRESETS.items():
                ensure_preset_mid(key, song)
        except Exception:
            pass

    def status_payload(self, sync: bool = True) -> Dict[str, Any]:
        if sync:
            self._sync_from_mci()
        tracks = []
        if self.song:
            for tr in self.song.get("tracks") or []:
                tracks.append(
                    {
                        "name": tr.get("name") or "?",
                        "program": tr.get("program") or 0,
                        "channel": tr.get("channel") or 0,
                        "notes": len(tr.get("notes") or []),
                    }
                )
        return {
            "ok": True,
            "event": "status",
            "status": self.status,
            "title": self.title,
            "path": self._path or "",
            "volume": int(self.volume),
            "position": self.position,
            "duration": self.duration,
            "tracks": tracks,
            "preset": (self.song or {}).get("name") or "",
            "backend": "winmm",
        }

    def _sync_from_mci(self) -> None:
        if not self._path:
            return
        mode = self.midi.mode()
        if mode == "playing":
            self.status = "playing"
            self.position = self.midi.position_ms() / 1000.0
        elif mode == "paused":
            self.status = "paused"
            self.position = self.midi.position_ms() / 1000.0
        elif mode in ("stopped", "not ready", ""):
            # 播完也会 stopped
            if self.status == "playing":
                pos = self.midi.position_ms()
                length = self.midi.length_ms()
                if length > 0 and pos >= max(0, length - 50):
                    self.status = "stopped"
                    self.position = length / 1000.0
                    emit({"ok": True, "event": "ended"})
                elif self.status == "playing" and mode == "stopped":
                    # 用户 stop 或自然结束
                    if length > 0 and pos >= max(0, length - 80):
                        self.status = "stopped"
                        self.position = self.duration
                        emit({"ok": True, "event": "ended"})
            if self.duration <= 0:
                ln = self.midi.length_ms()
                if ln > 0:
                    self.duration = ln / 1000.0
        ln = self.midi.length_ms()
        if ln > 0:
            self.duration = ln / 1000.0

    def list_presets(self) -> List[Dict[str, Any]]:
        out = []
        for key, p in PRESETS.items():
            nnotes = sum(len(t.get("notes") or []) for t in p.get("tracks") or [])
            out.append(
                {
                    "id": key,
                    "name": p.get("name") or key,
                    "title": p.get("title") or p.get("name") or key,
                    "tracks": len(p.get("tracks") or []),
                    "notes": nnotes,
                    "tempo": p.get("tempo") or 120,
                }
            )
        return out

    def load_preset(self, name: str) -> None:
        key = (name or "").strip().lower()
        song = PRESETS.get(key)
        if not song:
            for k, p in PRESETS.items():
                if (p.get("name") or "").lower() == key or (p.get("title") or "").lower() == key:
                    song = p
                    key = k
                    break
        if not song:
            raise ValueError(f"unknown preset: {name}")
        mid_path = ensure_preset_mid(key, song)
        meta = dict(song)
        meta["name"] = key
        meta["path"] = mid_path
        self._load_mid_path(
            mid_path,
            title=song.get("title") or song.get("name") or key,
            song_meta=meta,
        )

    def load_path(self, path: str) -> None:
        path = os.path.abspath(path)
        if not os.path.isfile(path):
            raise FileNotFoundError(path)
        ext = Path(path).suffix.lower()
        if ext not in (".mid", ".midi"):
            raise ValueError("winmm backend only supports .mid / .midi files")
        meta = {
            "name": Path(path).stem,
            "title": Path(path).name,
            "path": path,
            "tracks": [],  # 不解析详情；UI 只显示文件名
        }
        self._load_mid_path(path, title=Path(path).name, song_meta=meta)

    def _load_mid_path(self, path: str, title: str, song_meta: Dict[str, Any]) -> None:
        path = os.path.abspath(path)
        # 同一文件已打开：只 seek，避免 close/open 的秒级延迟
        if self._path and os.path.normcase(self._path) == os.path.normcase(path):
            try:
                self.midi.stop()
            except Exception:
                pass
            self.song = song_meta
            self.title = title
            self._pause_ms = 0
            self.position = 0.0
            self.status = "stopped"
            ln = self.midi.length_ms()
            if ln > 0:
                self.duration = ln / 1000.0
            emit(self.status_payload())
            return

        emit({"ok": True, "event": "status", "status": "loading", "title": title, "backend": "winmm"})
        # 先关旧的再开新的（stop 不 close，加快切换）
        try:
            self.midi.stop()
        except Exception:
            pass
        try:
            self.midi.close()
        except Exception:
            pass
        self.midi.open(path)
        self._path = path
        self.song = song_meta
        self.title = title
        self._pause_ms = 0
        length = self.midi.length_ms()
        self.duration = (length / 1000.0) if length > 0 else 0.0
        self.position = 0.0
        self.status = "stopped"
        # volume 对部分 MIDI 设备无效，失败忽略，勿拖慢加载
        try:
            self.midi.set_volume(int(self.volume * 10))
        except Exception:
            pass
        emit(self.status_payload())

    def set_volume(self, vol: int) -> None:
        self.volume = max(0, min(100, int(vol)))
        try:
            self.midi.set_volume(int(self.volume * 10))
        except Exception:
            pass
        emit(self.status_payload())

    def play(self) -> None:
        if not self._path:
            raise RuntimeError("no song loaded")
        self._stop_flag.clear()
        mode = self.midi.mode()
        if self.status == "paused" or mode == "paused":
            self.midi.resume()
        else:
            # 从暂停点或开头
            if self._pause_ms > 0 and self.status != "stopped":
                self.midi.play(from_ms=self._pause_ms)
            else:
                self.midi.play(from_ms=0)
            self._pause_ms = 0
        self.status = "playing"
        emit(self.status_payload())
        self._ensure_monitor()

    def pause(self) -> None:
        if self.status != "playing":
            return
        self._pause_ms = self.midi.position_ms()
        self.midi.pause()
        self.status = "paused"
        self.position = self._pause_ms / 1000.0
        emit(self.status_payload())

    def resume(self) -> None:
        if self.status == "paused":
            self.play()

    def toggle(self) -> None:
        if self.status == "playing":
            self.pause()
        else:
            self.play()

    def stop_playback(self, close: bool = False) -> None:
        self._stop_flag.set()
        try:
            self.midi.stop()
        except Exception:
            pass
        if close:
            try:
                self.midi.close()
            except Exception:
                pass
            self._path = None
        self.status = "stopped"
        self.position = 0.0
        self._pause_ms = 0

    def stop(self) -> None:
        self.stop_playback(close=False)
        emit(self.status_payload())

    def _ensure_monitor(self) -> None:
        if self._monitor and self._monitor.is_alive():
            return

        def mon() -> None:
            while not self._stop_flag.is_set():
                time.sleep(0.4)
                if self.status not in ("playing", "paused"):
                    break
                prev = self.status
                self._sync_from_mci()
                # sync 已在上面做，payload 不再重复 MCI 查询
                emit(self.status_payload(sync=False))
                if self.status == "stopped" and prev == "playing":
                    break

        self._monitor = threading.Thread(target=mon, daemon=True)
        self._monitor.start()

    def cleanup(self) -> None:
        self.stop_playback(close=True)
        for f in self._temp_files:
            try:
                os.remove(f)
            except Exception:
                pass
        self._temp_files.clear()


def main() -> int:
    if sys.platform != "win32":
        emit({"ok": False, "error": "music winmm backend requires Windows"})
        return 1
    try:
        eng = MidiEngine()
    except Exception as e:
        emit({"ok": False, "error": f"music midi init failed: {e}"})
        return 1

    emit(
        {
            "ok": True,
            "event": "ready",
            "presets": eng.list_presets(),
            "backend": "winmm",
        }
    )

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            emit({"ok": False, "error": f"bad json: {e}"})
            continue
        cmd = (msg.get("cmd") or "").lower()
        try:
            if cmd == "ping":
                emit({"ok": True, "event": "pong", "backend": "winmm"})
            elif cmd == "presets":
                emit({"ok": True, "event": "presets", "presets": eng.list_presets()})
            elif cmd == "load_preset":
                eng.load_preset(str(msg.get("name") or msg.get("preset") or ""))
            elif cmd == "load":
                eng.load_path(str(msg.get("path") or ""))
            elif cmd == "play":
                eng.play()
            elif cmd == "pause":
                eng.pause()
            elif cmd == "resume":
                eng.resume()
            elif cmd == "toggle":
                eng.toggle()
            elif cmd == "stop":
                eng.stop()
            elif cmd == "volume":
                eng.set_volume(int(msg.get("volume") or eng.volume))
            elif cmd == "status":
                emit(eng.status_payload())
            elif cmd == "quit":
                eng.cleanup()
                emit({"ok": True, "event": "bye"})
                return 0
            else:
                emit({"ok": False, "error": f"unknown cmd: {cmd}"})
        except Exception as e:
            emit({"ok": False, "error": str(e)})
    eng.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
