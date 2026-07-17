# -*- coding: utf-8 -*-
"""Windows SAPI TTS daemon for tts.nvim (JSON lines over stdin/stdout).

依赖: pywin32 (win32com)

Request:
  {"cmd":"voices"}
  {"cmd":"speak","segments":["..."],"voice":"...","volume":80,"rate":0,"start":0}
  {"cmd":"stop"} | {"cmd":"pause"} | {"cmd":"resume"} | {"cmd":"toggle"}
  {"cmd":"goto","index":2}
  {"cmd":"volume","volume":50}   # 0-100
  {"cmd":"rate","rate":0}        # -10..10
  {"cmd":"voice","voice":"name or index"}
  {"cmd":"status"} | {"cmd":"quit"} | {"cmd":"ping"}

Events:
  {"ok":true,"event":"ready","voices":[{name,id,culture,gender},...]}
  {"ok":true,"event":"segment","index":0,"total":n,"text":"..."}
  {"ok":true,"event":"status","status":"playing|paused|stopped|idle",...}
  {"ok":true,"event":"ended"}
  {"ok":false,"error":"..."}
"""
from __future__ import annotations

import json
import re
import sys
import threading
import time
from typing import Any, Dict, List, Optional

try:
    sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)  # type: ignore
    sys.stderr.reconfigure(encoding="utf-8")  # type: ignore
except Exception:
    pass


def emit(obj: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class SapiEngine:
    def __init__(self) -> None:
        import pythoncom
        import win32com.client

        self._pythoncom = pythoncom
        self._win32com = win32com
        pythoncom.CoInitialize()
        self.voice = win32com.client.Dispatch("SAPI.SpVoice")
        self.volume = 80
        self.rate = 0
        self.voice_name = ""
        self.segments: List[str] = []
        self.index = 0
        self.status = "idle"  # idle|playing|paused|stopped
        self._stop_flag = threading.Event()
        self._pause_flag = threading.Event()  # set = paused
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._cmd_q: List[Dict[str, Any]] = []
        # 播放世代：goto/重开时递增，旧线程事件全部丢弃
        self._speak_gen: int = 0
        # 默认设备 id 缓存，避免每段都起 PowerShell
        self._cached_def_id: str = ""
        self._cached_def_ts: float = 0.0
        self._apply_voice_defaults()

    def _apply_voice_defaults(self) -> None:
        try:
            self.voice.Volume = int(self.volume)
            self.voice.Rate = int(self.rate)
            desc = self.voice.Voice.GetDescription()
            self.voice_name = str(desc)
        except Exception:
            pass
        self._bind_default_audio(self.voice)

    def _get_windows_default_endpoint_id(self, force: bool = False) -> str:
        """WASAPI 默认播放设备 ID，形如 {0.0.0.00000000}.{guid}（缓存 60s）"""
        now = time.time()
        if (
            not force
            and self._cached_def_id
            and (now - self._cached_def_ts) < 60.0
        ):
            return self._cached_def_id
        try:
            import subprocess

            ps = r"""
$ErrorActionPreference='Stop'
$code = @'
using System;
using System.Runtime.InteropServices;
public static class DefAudio {
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int _VtblGap1_1();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IntPtr ppEndpoint);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IntPtr ppInterface);
    int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
  }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
  class MMDeviceEnumerator {}
  public static string GetDefaultId() {
    var en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
    IntPtr pDev;
    en.GetDefaultAudioEndpoint(0, 0, out pDev); // eRender, eConsole
    var dev = (IMMDevice)Marshal.GetObjectForIUnknown(pDev);
    string id;
    dev.GetId(out id);
    return id;
  }
}
'@
Add-Type -TypeDefinition $code -ErrorAction Stop
[DefAudio]::GetDefaultId()
"""
            r = subprocess.run(
                ["powershell", "-NoProfile", "-Command", ps],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=8,
            )
            s = (r.stdout or "").strip()
            if s.startswith("{") and "}" in s:
                self._cached_def_id = s.splitlines()[-1].strip()
                self._cached_def_ts = now
                return self._cached_def_id
        except Exception:
            pass
        return self._cached_def_id or ""

    def _bind_default_audio(self, sp) -> None:
        """绑定到 Windows 当前默认播放设备（仅会话开始时调用一次）。

        注意：不要在每一段 Speak 前重复绑定。重设 AudioOutput/Stream
        会让 WaitUntilDone 立刻返回，高亮 index 狂飙、与真实播放严重错位。

        1) 用 WASAPI 取默认 endpoint id，匹配 SAPI GetAudioOutputs
        2) 回退：SpMMAudioOut.DeviceId = -1（WAVE_MAPPER，跟随系统默认）
        失败则不动，避免设坏导致静音。
        """
        try:
            # 方案 A：匹配默认 endpoint
            def_id = self._get_windows_default_endpoint_id()
            if def_id:
                outs = sp.GetAudioOutputs()
                if outs is not None:
                    for i in range(outs.Count):
                        try:
                            tok = outs.Item(i)
                            tid = str(tok.Id or "")
                            if def_id.lower() in tid.lower():
                                sp.AudioOutput = tok
                                return
                        except Exception:
                            continue
            # 方案 B：WAVE_MAPPER = 系统默认波形设备
            mm = self._win32com.client.Dispatch("SAPI.SpMMAudioOut")
            mm.DeviceId = -1
            sp.AudioOutputStream = mm
        except Exception:
            pass

    def _is_speaking(self, sp) -> bool:
        """SPRS_IS_SPEAKING = 2"""
        try:
            return int(sp.Status.RunningState) == 2
        except Exception:
            return False

    def _wait_segment_done(self, sp) -> None:
        """等当前段播完；可被 stop / pause 打断。

        不把异常或「瞬时 done」当成结束，避免 index 超前于音频。
        """
        SVSFPurgeBeforeSpeak = 2
        # 给引擎一点时间进入 SPEAKING（避免 Start 前 WaitUntilDone 假完成）
        t_deadline = time.time() + 0.6
        saw_speak = False
        while time.time() < t_deadline and not self._stop_flag.is_set():
            if self._pause_flag.is_set():
                break
            if self._is_speaking(sp):
                saw_speak = True
                break
            time.sleep(0.02)

        while not self._stop_flag.is_set():
            if self._pause_flag.is_set():
                try:
                    sp.Pause()
                except Exception:
                    pass
                while self._pause_flag.is_set() and not self._stop_flag.is_set():
                    time.sleep(0.05)
                if self._stop_flag.is_set():
                    break
                try:
                    sp.Resume()
                except Exception:
                    pass
                continue

            try:
                done = bool(sp.WaitUntilDone(120))
            except Exception:
                # 异常时用 RunningState 兜底，绝不直接当完成
                done = not self._is_speaking(sp)
                if not done:
                    time.sleep(0.05)
                    continue

            if not done:
                continue

            # WaitUntilDone 报完成：若仍在说则继续等
            if self._is_speaking(sp):
                continue

            # 从未进入 SPEAKING 且几乎瞬间结束：短句也可能如此，再确认一次
            if not saw_speak:
                time.sleep(0.05)
                if self._is_speaking(sp):
                    saw_speak = True
                    continue
            break

        if self._stop_flag.is_set():
            try:
                sp.Speak("", SVSFPurgeBeforeSpeak)
            except Exception:
                pass

    def list_voices(self) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        try:
            voices = self.voice.GetVoices()
            for i in range(voices.Count):
                v = voices.Item(i)
                desc = str(v.GetDescription())
                # Attribute id  for culture: often in description
                culture = ""
                m = re.search(r"\(([^)]+)\)\s*$", desc)
                if m:
                    culture = m.group(1)
                gender = "unknown"
                low = desc.lower()
                if "female" in low or "zira" in low or "huihui" in low or "hazel" in low:
                    gender = "female"
                elif "male" in low or "david" in low or "mark" in low:
                    gender = "male"
                out.append(
                    {
                        "index": i,
                        "name": desc,
                        "id": str(v.Id) if hasattr(v, "Id") else str(i),
                        "culture": culture,
                        "gender": gender,
                    }
                )
        except Exception as e:
            emit({"ok": False, "error": f"list voices: {e}"})
        return out

    def set_volume(self, vol: int) -> None:
        self.volume = max(0, min(100, int(vol)))
        try:
            self.voice.Volume = self.volume
        except Exception:
            pass

    def set_rate(self, rate: int) -> None:
        self.rate = max(-10, min(10, int(rate)))
        try:
            self.voice.Rate = self.rate
        except Exception:
            pass

    def set_voice(self, name_or_index: Any) -> bool:
        try:
            voices = self.voice.GetVoices()
            if isinstance(name_or_index, int) or (
                isinstance(name_or_index, str) and name_or_index.isdigit()
            ):
                idx = int(name_or_index)
                if 0 <= idx < voices.Count:
                    self.voice.Voice = voices.Item(idx)
                    self.voice_name = str(voices.Item(idx).GetDescription())
                    return True
            name = str(name_or_index or "")
            if not name:
                return False
            # exact / substring match
            for i in range(voices.Count):
                v = voices.Item(i)
                desc = str(v.GetDescription())
                if desc == name or name.lower() in desc.lower():
                    self.voice.Voice = v
                    self.voice_name = desc
                    return True
        except Exception as e:
            emit({"ok": False, "error": f"set voice: {e}"})
        return False

    def status_payload(self) -> Dict[str, Any]:
        return {
            "ok": True,
            "event": "status",
            "status": self.status,
            "index": self.index,
            "total": len(self.segments),
            "volume": self.volume,
            "rate": self.rate,
            "voice": self.voice_name,
            "text": self.segments[self.index] if 0 <= self.index < len(self.segments) else "",
            "gen": self._speak_gen,
        }

    def stop(self) -> None:
        self._stop_flag.set()
        self._pause_flag.clear()
        try:
            self.voice.Speak("", 3)  # SVSFPurgeBeforeSpeak | skip
        except Exception:
            pass
        try:
            # 0 = purge
            self.voice.Skip("Sentence", 9999)
        except Exception:
            pass
        with self._lock:
            self.status = "stopped"
        emit(self.status_payload())

    def pause(self) -> None:
        if self.status != "playing":
            return
        self._pause_flag.set()
        try:
            self.voice.Pause()
        except Exception:
            pass
        with self._lock:
            self.status = "paused"
        emit(self.status_payload())

    def resume(self) -> None:
        if self.status != "paused":
            return
        self._pause_flag.clear()
        try:
            self.voice.Resume()
        except Exception:
            pass
        with self._lock:
            self.status = "playing"
        emit(self.status_payload())

    def toggle(self) -> None:
        if self.status == "playing":
            self.pause()
        elif self.status == "paused":
            self.resume()

    def goto(self, index: int) -> None:
        if not self.segments:
            return
        index = max(0, min(len(self.segments) - 1, int(index)))
        # 重启播放线程从 index
        segs = list(self.segments)
        vol, rate, voice = self.volume, self.rate, self.voice_name
        self.stop()
        time.sleep(0.05)
        self.speak(segs, voice=voice, volume=vol, rate=rate, start=index)

    def speak(
        self,
        segments: List[str],
        voice: Optional[str] = None,
        volume: Optional[int] = None,
        rate: Optional[int] = None,
        start: int = 0,
    ) -> None:
        self.stop()
        # 等旧线程结束
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)

        self._stop_flag.clear()
        self._pause_flag.clear()
        # 严禁过滤空段：index 必须与 Lua 高亮 ranges 一一对应
        self.segments = [str(s) if s is not None else "" for s in segments]
        if not any(str(s).strip() for s in self.segments):
            emit({"ok": False, "error": "empty text"})
            return
        if volume is not None:
            self.set_volume(volume)
        if rate is not None:
            self.set_rate(rate)
        if voice:
            self.set_voice(voice)
        self.index = max(0, min(len(self.segments) - 1, int(start or 0)))
        self._speak_gen += 1
        gen = self._speak_gen

        def worker() -> None:
            self._pythoncom.CoInitialize()
            try:
                # 线程内新建 SpVoice，避免跨线程 COM 问题
                sp = self._win32com.client.Dispatch("SAPI.SpVoice")
                sp.Volume = int(self.volume)
                sp.Rate = int(self.rate)
                # 复制 voice
                try:
                    voices = sp.GetVoices()
                    for i in range(voices.Count):
                        if str(voices.Item(i).GetDescription()) == self.voice_name:
                            sp.Voice = voices.Item(i)
                            break
                except Exception:
                    pass
                # 只在会话开始绑一次默认设备（中途重绑会打乱 WaitUntilDone）
                self._bind_default_audio(sp)

                if gen != self._speak_gen:
                    return

                with self._lock:
                    self.status = "playing"
                emit(self.status_payload())

                SVSFlagsAsync = 1
                i = self.index
                total = len(self.segments)
                while i < total:
                    if self._stop_flag.is_set() or gen != self._speak_gen:
                        break
                    while self._pause_flag.is_set() and not self._stop_flag.is_set():
                        if gen != self._speak_gen:
                            break
                        time.sleep(0.05)
                    if self._stop_flag.is_set() or gen != self._speak_gen:
                        break

                    with self._lock:
                        self.index = i
                    text = self.segments[i]
                    if gen == self._speak_gen:
                        emit(
                            {
                                "ok": True,
                                "event": "segment",
                                "index": i,
                                "total": total,
                                "text": text,
                                "gen": gen,
                            }
                        )
                        emit(self.status_payload())

                    try:
                        sp.Volume = int(self.volume)
                        sp.Rate = int(self.rate)
                        if str(text).strip() == "":
                            # 空段：保持 index 对齐，不朗读
                            i += 1
                            continue
                        if gen != self._speak_gen:
                            break
                        sp.Speak(str(text), SVSFlagsAsync)
                        self._wait_segment_done(sp)
                    except Exception as e:
                        if gen == self._speak_gen:
                            emit({"ok": False, "error": f"speak: {e}"})
                    if self._stop_flag.is_set() or gen != self._speak_gen:
                        break
                    i += 1

                # 仅本世代线程可写最终状态，避免旧线程覆盖新播放
                if gen != self._speak_gen:
                    return

                if not self._stop_flag.is_set():
                    with self._lock:
                        self.status = "stopped"
                        if self.segments:
                            self.index = min(self.index, len(self.segments) - 1)
                    emit({"ok": True, "event": "ended", "gen": gen})
                    emit(self.status_payload())
                else:
                    with self._lock:
                        if self.status != "paused":
                            self.status = "stopped"
                    emit(self.status_payload())
            finally:
                try:
                    self._pythoncom.CoUninitialize()
                except Exception:
                    pass

        self._thread = threading.Thread(target=worker, daemon=True)
        self._thread.start()


def main() -> int:
    try:
        eng = SapiEngine()
    except Exception as e:
        emit({"ok": False, "error": f"SAPI init failed: {e} (need pywin32 on Windows)"})
        return 1

    voices = eng.list_voices()
    emit({"ok": True, "event": "ready", "voices": voices, "voice": eng.voice_name})

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
                emit({"ok": True, "event": "pong"})
            elif cmd == "voices":
                emit({"ok": True, "event": "voices", "voices": eng.list_voices()})
            elif cmd == "speak":
                segs = msg.get("segments")
                if not segs:
                    text = msg.get("text") or ""
                    segs = [text] if text else []
                eng.speak(
                    list(segs),
                    voice=msg.get("voice"),
                    volume=msg.get("volume"),
                    rate=msg.get("rate"),
                    start=int(msg.get("start") or 0),
                )
            elif cmd == "stop":
                eng.stop()
            elif cmd == "pause":
                eng.pause()
            elif cmd == "resume":
                eng.resume()
            elif cmd == "toggle":
                eng.toggle()
            elif cmd == "goto":
                eng.goto(int(msg.get("index") or 0))
            elif cmd == "volume":
                eng.set_volume(int(msg.get("volume") or eng.volume))
                emit(eng.status_payload())
            elif cmd == "rate":
                eng.set_rate(int(msg.get("rate") or eng.rate))
                emit(eng.status_payload())
            elif cmd == "voice":
                ok = eng.set_voice(msg.get("voice"))
                emit(eng.status_payload() if ok else {"ok": False, "error": "voice not found"})
            elif cmd == "status":
                emit(eng.status_payload())
            elif cmd == "quit":
                eng.stop()
                emit({"ok": True, "event": "bye"})
                return 0
            else:
                emit({"ok": False, "error": f"unknown cmd: {cmd}"})
        except Exception as e:
            emit({"ok": False, "error": str(e)})
    eng.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
