#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""列出进程为 JSON（供 taskmgr.nvim 使用）。

**必须安装 psutil**：`pip install psutil`（Win / Linux / macOS 唯一后端）

CPU%：全逻辑核心合计 = 100%（与常见任务管理器一致）。
内存 mem：
  - Windows：提交大小（vms ≈ PagefileUsage）
  - Linux/macOS：优先 USS，其次 PSS，再次 RSS
gpu：nvidia-smi（跨平台）；Windows 另可走 GPU Engine 计数器。

stdout JSON:
{ ok, procs, total_mem, mem_used, commit_limit, sys_cpu, sys_gpu, cpu_count, backend, platform }
"""
from __future__ import annotations

import json
import platform
import subprocess
import sys
import time

_IS_WIN = platform.system().lower() == "windows"
_IS_LINUX = platform.system().lower() == "linux"
_IS_DARWIN = platform.system().lower() == "darwin"


def _out(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))
    sys.stdout.flush()


def _run_kwargs() -> dict:
    """subprocess 公共参数：仅 Windows 隐藏控制台。"""
    kw: dict = {
        "capture_output": True,
        "text": True,
        "encoding": "utf-8",
        "errors": "replace",
    }
    if _IS_WIN:
        kw["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    return kw


def _one_line(s: str, limit: int = 240) -> str:
    if not s:
        return ""
    s = str(s).replace("\r\n", " ").replace("\r", " ").replace("\n", " ").replace("\0", " ")
    if len(s) > limit:
        s = s[:limit]
    return s


def _norm_cpu(raw: float, cpu_count: int) -> float:
    n = max(1, int(cpu_count or 1))
    v = float(raw or 0.0) / n
    if v < 0:
        v = 0.0
    if v > 100.0:
        v = 100.0
    return round(v, 1)


def _is_idle_name(name: str) -> bool:
    n = (name or "").lower()
    return (
        n in ("system idle process", "idle", "system idle", "swapper", "swapper/0")
        or "idle process" in n
        or n.startswith("swapper/")
        or n == "idle"
    )


def _win_commit_limit() -> int:
    if not _IS_WIN:
        return 0
    try:
        import ctypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        stat = MEMORYSTATUSEX()
        stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
            return int(stat.ullTotalPageFile)
    except Exception:
        pass
    return 0


def _sys_gpu_nvidia() -> float | None:
    try:
        r = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=utilization.gpu",
                "--format=csv,noheader,nounits",
            ],
            timeout=3,
            **_run_kwargs(),
        )
        if r.returncode != 0:
            return None
        vals = []
        for line in (r.stdout or "").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                vals.append(float(line.split(",")[0].strip()))
            except ValueError:
                pass
        if not vals:
            return None
        return round(sum(vals) / len(vals), 1)
    except Exception:
        return None


def _nvidia_gpu_by_pid() -> dict[int, float]:
    """nvidia-smi pmon：跨平台 per-pid SM 利用率（有 NVIDIA 驱动时）。"""
    try:
        r = subprocess.run(
            ["nvidia-smi", "pmon", "-c", "1", "-s", "u"],
            timeout=4,
            **_run_kwargs(),
        )
        if r.returncode != 0:
            return {}
        out: dict[int, float] = {}
        for line in (r.stdout or "").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or line.lower().startswith("gpu"):
                continue
            # 格式示例: 0  12345  C  12  5  -  -  python
            parts = line.split()
            if len(parts) < 4:
                continue
            try:
                pid = int(parts[1])
            except ValueError:
                continue
            if pid <= 0:
                continue
            sm = 0.0
            try:
                # parts[2] type, parts[3] sm
                sm = float(parts[3])
            except ValueError:
                # sm 可能为 -
                sm = 0.0
            if sm < 0:
                sm = 0.0
            prev = out.get(pid, 0.0)
            # 多 GPU 时取较大 SM%
            if sm > prev:
                out[pid] = min(100.0, sm)
        return out
    except Exception:
        return {}


def _win_gpu_by_pid() -> dict[int, float]:
    if not _IS_WIN:
        return {}
    ps = r"""
$ErrorActionPreference='SilentlyContinue'
function Sample {
  $map = @{}
  try {
    $c = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
    if ($null -eq $c) { return $map }
    foreach ($s in $c.CounterSamples) {
      $name = [string]$s.InstanceName
      if ($name -match 'pid_(\d+)') {
        $p = [int]$Matches[1]
        $v = 0.0
        try { $v = [double]$s.CookedValue } catch { $v = 0.0 }
        if ($v -lt 0) { $v = 0 }
        if (-not $map.ContainsKey($p)) { $map[$p] = 0.0 }
        $map[$p] = $map[$p] + $v
      }
    }
  } catch {}
  return $map
}
[void](Sample)
Start-Sleep -Milliseconds 250
$m = Sample
$out = @()
foreach ($k in $m.Keys) {
  $g = [Math]::Min(100.0, [Math]::Round([double]$m[$k], 1))
  $out += [ordered]@{ pid = [int]$k; gpu = $g }
}
if ($out.Count -eq 0) { '[]' } else { $out | ConvertTo-Json -Compress -Depth 3 }
"""
    try:
        r = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                ps,
            ],
            timeout=8,
            **_run_kwargs(),
        )
        out_raw = (r.stdout or "").strip()
        if not out_raw:
            return {}
        data = json.loads(out_raw)
    except Exception:
        return {}
    out: dict[int, float] = {}
    if isinstance(data, list):
        for row in data:
            if isinstance(row, dict) and "pid" in row:
                try:
                    out[int(row["pid"])] = float(row.get("gpu") or 0)
                except Exception:
                    pass
    elif isinstance(data, dict) and "pid" in data:
        try:
            out[int(data["pid"])] = float(data.get("gpu") or 0)
        except Exception:
            pass
    return out


def _proc_mem_bytes(p, mi) -> int:
    """
    Windows: 提交大小 (vms/PagefileUsage)
    Linux/macOS: USS > PSS > RSS（更接近「实际占用」）
    """
    if _IS_WIN:
        commit = int(getattr(mi, "vms", 0) or 0)
        if commit <= 0:
            commit = int(getattr(mi, "rss", 0) or 0)
        return commit

    # 需要更高权限时 memory_full_info 会失败
    try:
        full = p.memory_full_info()
        for attr in ("uss", "pss", "rss"):
            v = int(getattr(full, attr, 0) or 0)
            if v > 0:
                return v
    except Exception:
        pass
    return int(getattr(mi, "rss", 0) or 0)


def _mem_limit(total_phys: int) -> int:
    """提交/占用上限：Win=页文件总容量；Linux/mac=物理+swap。"""
    if _IS_WIN:
        cl = _win_commit_limit()
        return cl if cl > 0 else total_phys
    try:
        import psutil  # type: ignore

        swap = int(psutil.swap_memory().total or 0)
        return total_phys + max(0, swap)
    except Exception:
        return total_phys


def list_with_psutil(sample_ms: int = 400) -> dict:
    import psutil  # type: ignore  # 必需依赖

    cpu_count = max(1, psutil.cpu_count(logical=True) or 1)
    psutil.cpu_percent(interval=None)
    for p in psutil.process_iter(["pid"]):
        try:
            p.cpu_percent(interval=None)
        except (psutil.Error, TypeError, AttributeError):
            continue

    time.sleep(max(0.05, sample_ms / 1000.0))

    sys_cpu = float(psutil.cpu_percent(interval=None) or 0.0)
    sys_cpu = max(0.0, min(100.0, sys_cpu))

    vm = psutil.virtual_memory()
    total_mem = int(vm.total)
    # Linux 上 used 含 cache 口径因版本而异；available 更稳
    if _IS_LINUX:
        avail = int(getattr(vm, "available", 0) or 0)
        mem_used = max(0, total_mem - avail) if avail > 0 else int(vm.used)
    else:
        mem_used = int(vm.used)

    commit_limit = _mem_limit(total_mem)

    gpu_map: dict[int, float] = {}
    # 1) NVIDIA pmon（Win/Linux 通用）
    try:
        gpu_map = _nvidia_gpu_by_pid()
    except Exception:
        gpu_map = {}
    # 2) Windows 计数器补充
    if _IS_WIN:
        try:
            win_map = _win_gpu_by_pid()
            for k, v in win_map.items():
                if float(v or 0) > float(gpu_map.get(k, 0) or 0):
                    gpu_map[k] = float(v)
        except Exception:
            pass

    sys_gpu = _sys_gpu_nvidia()
    if sys_gpu is None:
        gsum = sum(float(v or 0) for v in gpu_map.values())
        sys_gpu = round(min(100.0, gsum), 1)

    procs = []
    for p in psutil.process_iter(["pid", "name", "username", "memory_info", "cmdline"]):
        try:
            with p.oneshot():
                pid = p.pid
                raw_cpu = float(p.cpu_percent(interval=None) or 0.0)
                cpu = _norm_cpu(raw_cpu, cpu_count)
                mi = p.info.get("memory_info")
                mem = _proc_mem_bytes(p, mi)
                name = _one_line(p.info.get("name") or "", 120)
                user = _one_line(p.info.get("username") or "", 80)
                try:
                    cmd = _one_line(" ".join(p.info.get("cmdline") or []), 240)
                except (psutil.Error, TypeError):
                    cmd = ""
                mem_pct = (mem / commit_limit * 100.0) if commit_limit > 0 else 0.0
                gpu = float(gpu_map.get(pid, 0.0) or 0.0)
                procs.append(
                    {
                        "pid": pid,
                        "name": name,
                        "cpu": cpu,
                        "mem": mem,
                        "mem_pct": round(mem_pct, 1),
                        "gpu": round(min(100.0, gpu), 1),
                        "user": user,
                        "cmd": cmd,
                        "idle": pid == 0 or _is_idle_name(name),
                    }
                )
        except (psutil.Error, TypeError, AttributeError, OSError):
            continue

    plat = "windows" if _IS_WIN else ("linux" if _IS_LINUX else ("darwin" if _IS_DARWIN else platform.system().lower()))

    return {
        "ok": True,
        "procs": procs,
        "total_mem": total_mem,
        "mem_used": mem_used,
        "commit_limit": commit_limit,
        "sys_cpu": round(sys_cpu, 1),
        "sys_gpu": float(sys_gpu or 0),
        "cpu_count": cpu_count,
        "backend": "psutil",
        "platform": plat,
    }


def main() -> int:
    sample_ms = 400
    if len(sys.argv) > 1:
        try:
            sample_ms = max(50, min(2000, int(sys.argv[1])))
        except ValueError:
            pass

    try:
        import psutil  # noqa: F401
    except ImportError:
        _out(
            {
                "ok": False,
                "procs": [],
                "err": "need_psutil: pip install psutil",
                "backend": "none",
            }
        )
        return 2

    try:
        data = list_with_psutil(sample_ms)
        _out(data)
        return 0
    except Exception as e:
        _out(
            {
                "ok": False,
                "procs": [],
                "err": str(e),
                "backend": "psutil",
            }
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
