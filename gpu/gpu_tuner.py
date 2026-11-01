#!/usr/bin/env python3
"""
gpu_tuner.py: automated NVIDIA GPU overclock / undervolt search for Windows.

It automates the manual procedure from the guide:
  1. Max the power limit.
  2. Baseline run at stock settings.
  3. Core offset search: +75 MHz first, then +15 MHz steps (12.5 on Pascal),
     stepping back on failure.
  4. Memory offset search: start +500 MHz, coarse steps then fine steps, using a
     benchmark score to detect error correction regressions (GDDR6X).
  5. Optional undervolt mode: lock the core clock to a target and search the
     highest offset (lowest voltage on the V/F curve) that stays stable.
  6. Long soak of the final combination, stepping back if it fails.

Backends:
  afterburner : edits one dedicated MSI Afterburner profile slot and applies it
                with "MSIAfterburner.exe -ProfileN".
  nvml        : sets offsets directly through NVML (no Afterburner needed).

Requirements: Windows, NVIDIA driver, Python 3.9+, "pip install nvidia-ml-py",
an elevated (Administrator) prompt, and a stress tool such as OCCT.
"""
from __future__ import annotations

import argparse
import ctypes
import glob
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

try:
    import pynvml
except ImportError:  # reported in Gpu.__init__
    pynvml = None


# ----------------------------------------------------------------------------
# Errors, logging, configuration
# ----------------------------------------------------------------------------
class TunerError(RuntimeError):
    pass


class BackendError(TunerError):
    pass


class ConfigError(TunerError):
    pass


class FatalGpuError(TunerError):
    pass


def log(msg: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


@dataclass
class RunnerConfig:
    # Command line as a list. The token {duration} is replaced by seconds.
    cmd: list = field(default_factory=list)
    cwd: str = ""
    duration_s: int = 600
    grace_s: int = 90                 # extra time allowed before declaring a hang
    kill_after_duration: bool = False  # for tools that never exit by themselves
    min_runtime_fraction: float = 0.8  # exiting earlier than this counts as failure
    error_regex: str = ""             # regex searched in output/log; a match means failure
    score_regex: str = ""             # regex with one group capturing the score
    log_file: str = ""                # optional glob of a log file the tool writes


@dataclass
class Config:
    gpu_index: int = 0
    backend: str = "afterburner"      # "afterburner" or "nvml"
    mode: str = "oc"                  # "oc" or "uv"
    tune_memory: bool = True
    allow_unscored_memory: bool = False

    afterburner_exe: str = r"C:\Program Files (x86)\MSI Afterburner\MSIAfterburner.exe"
    afterburner_profile_dir: str = r"C:\Program Files (x86)\MSI Afterburner\Profiles"
    afterburner_profile_file: str = ""  # set to override auto detection
    afterburner_slot: int = 5
    afterburner_settle_s: int = 5

    # NVML memory offset = Afterburner offset * scale. Windows tools use a 1x value and reports say
    # Linux style 2x values can crash the GPU, so 1.0 is the conservative default. Verify before changing.
    nvml_mem_scale: float = 1.0

    clock_step_mhz: float = 15.0      # 12.5 for Pascal
    core_start_mhz: float = 75.0
    core_max_mhz: float = 300.0
    mem_start_mhz: float = 500.0
    mem_coarse_mhz: float = 100.0
    mem_fine_mhz: float = 50.0
    mem_max_mhz: float = 1500.0

    uv_target_mhz: int = 0            # 0 = use the baseline sustained clock
    uv_start_offset_mhz: float = 45.0
    uv_max_offset_mhz: float = 300.0

    max_power_limit: bool = True
    temp_limit_c: int = 80
    cooldown_target_c: int = 55
    cooldown_max_s: int = 180
    soak_duration_s: int = 3600
    score_tolerance: float = 0.003
    check_driver_events: bool = True

    state_file: str = "gpu_tuner_state.json"
    result_file: str = "gpu_tuner_result.json"

    stress: RunnerConfig = field(default_factory=lambda: RunnerConfig(duration_s=600))
    benchmark: RunnerConfig = field(default_factory=lambda: RunnerConfig(duration_s=300))


def load_config(path: Path) -> Config:
    cfg = Config()
    if not path.exists():
        return cfg
    raw = json.loads(path.read_text(encoding="utf-8"))
    for key, value in raw.items():
        if key in ("stress", "benchmark"):
            setattr(cfg, key, RunnerConfig(**value))
        elif hasattr(cfg, key):
            setattr(cfg, key, value)
        else:
            raise ConfigError(f"Unknown config key: {key}")
    return cfg


def require_admin() -> None:
    if os.name != "nt":
        raise TunerError("This tool targets Windows.")
    if not ctypes.windll.shell32.IsUserAnAdmin():
        raise TunerError("Run this from an elevated (Administrator) prompt.")


# ----------------------------------------------------------------------------
# NVML wrapper and telemetry
# ----------------------------------------------------------------------------
@dataclass
class Sample:
    temp: int
    power_w: float
    clock: int
    mem_clock: int
    util: int
    reasons: int


class Gpu:
    PWR_MASK = 0x04 | 0x80    # SW power cap, HW power brake
    THERM_MASK = 0x20 | 0x40  # SW thermal slowdown, HW thermal slowdown

    def __init__(self, index: int):
        if pynvml is None:
            raise TunerError("NVML bindings missing. Run: pip install nvidia-ml-py")
        self.index = index
        self._open()

    def _open(self) -> None:
        pynvml.nvmlInit()
        self.handle = pynvml.nvmlDeviceGetHandleByIndex(self.index)

    def reinit(self) -> None:
        try:
            pynvml.nvmlShutdown()
        except Exception:
            pass
        self._open()

    @staticmethod
    def _s(value):
        return value.decode() if isinstance(value, bytes) else value

    @property
    def name(self) -> str:
        return self._s(pynvml.nvmlDeviceGetName(self.handle))

    @property
    def uuid(self) -> str:
        return self._s(pynvml.nvmlDeviceGetUUID(self.handle))

    @property
    def pci_device_id(self) -> int:
        return pynvml.nvmlDeviceGetPciInfo(self.handle).pciDeviceId >> 16

    @property
    def pci_bus(self) -> int:
        return pynvml.nvmlDeviceGetPciInfo(self.handle).bus

    def power_limits(self) -> tuple[int, int, int]:
        """Returns (min, default, max) in milliwatts."""
        lo, hi = pynvml.nvmlDeviceGetPowerManagementLimitConstraints(self.handle)
        default = pynvml.nvmlDeviceGetPowerManagementDefaultLimit(self.handle)
        return lo, default, hi

    def power_limit_mw(self) -> int:
        return pynvml.nvmlDeviceGetPowerManagementLimit(self.handle)

    def set_power_limit_mw(self, mw: int) -> None:
        pynvml.nvmlDeviceSetPowerManagementLimit(self.handle, int(mw))

    def min_graphics_clock(self) -> int:
        try:
            mem = pynvml.nvmlDeviceGetClockInfo(self.handle, pynvml.NVML_CLOCK_MEM)
            return int(min(pynvml.nvmlDeviceGetSupportedGraphicsClocks(self.handle, mem)))
        except pynvml.NVMLError:
            return 210

    def lock_clock(self, mhz: int, pin: bool = True) -> None:
        """pin=True fixes the clock exactly (deterministic search trials).
        pin=False caps the clock but lets the GPU idle down (final use)."""
        floor = int(mhz) if pin else min(self.min_graphics_clock(), int(mhz))
        pynvml.nvmlDeviceSetGpuLockedClocks(self.handle, floor, int(mhz))

    def unlock_clock(self) -> None:
        try:
            pynvml.nvmlDeviceResetGpuLockedClocks(self.handle)
        except pynvml.NVMLError as exc:
            log(f"warning: could not reset locked clocks: {exc}")

    def get_offsets(self) -> Optional[tuple[int, int]]:
        try:
            return (pynvml.nvmlDeviceGetGpcClkVfOffset(self.handle),
                    pynvml.nvmlDeviceGetMemClkVfOffset(self.handle))
        except (AttributeError, pynvml.NVMLError):
            return None

    def set_offsets(self, core_mhz: float, mem_raw: float) -> None:
        for fn in ("nvmlDeviceSetGpcClkVfOffset", "nvmlDeviceSetMemClkVfOffset"):
            if not hasattr(pynvml, fn):
                raise BackendError(f"Installed nvidia-ml-py lacks {fn}. Upgrade it or use the afterburner backend.")
        try:
            pynvml.nvmlDeviceSetGpcClkVfOffset(self.handle, int(round(core_mhz)))
            pynvml.nvmlDeviceSetMemClkVfOffset(self.handle, int(round(mem_raw)))
        except pynvml.NVMLError as exc:
            raise BackendError(f"NVML refused the offset change: {exc}") from exc

    def _reasons(self) -> int:
        fn = (getattr(pynvml, "nvmlDeviceGetCurrentClocksEventReasons", None)
              or getattr(pynvml, "nvmlDeviceGetCurrentClocksThrottleReasons"))
        return int(fn(self.handle))

    def sample(self) -> Sample:
        h = self.handle
        return Sample(
            temp=pynvml.nvmlDeviceGetTemperature(h, pynvml.NVML_TEMPERATURE_GPU),
            power_w=pynvml.nvmlDeviceGetPowerUsage(h) / 1000.0,
            clock=pynvml.nvmlDeviceGetClockInfo(h, pynvml.NVML_CLOCK_GRAPHICS),
            mem_clock=pynvml.nvmlDeviceGetClockInfo(h, pynvml.NVML_CLOCK_MEM),
            util=pynvml.nvmlDeviceGetUtilizationRates(h).gpu,
            reasons=self._reasons(),
        )


class Monitor(threading.Thread):
    """Samples telemetry while a stress test runs and flags NVML failures and overheating."""

    def __init__(self, gpu: Gpu, temp_limit_c: int, interval: float = 1.0):
        super().__init__(daemon=True)
        self.gpu = gpu
        self.temp_limit_c = temp_limit_c
        self.interval = interval
        self.samples: list[Sample] = []
        self.error: Optional[str] = None
        self.thermal_exceeded = False
        self._stop_evt = threading.Event()
        self._hot = 0

    def run(self) -> None:
        while not self._stop_evt.is_set():
            try:
                s = self.gpu.sample()
            except Exception as exc:  # an NVML failure means the driver or GPU faulted
                self.error = f"{type(exc).__name__}: {exc}"
                return
            self.samples.append(s)
            self._hot = self._hot + 1 if s.temp > self.temp_limit_c else 0
            if self._hot >= 3:
                self.thermal_exceeded = True
            self._stop_evt.wait(self.interval)

    def stop(self) -> None:
        self._stop_evt.set()
        self.join(timeout=5)

    def summary(self) -> dict:
        load = [s for s in self.samples if s.util >= 80] or self.samples
        if not load:
            return {}
        n = len(load)
        return {
            "samples": n,
            "avg_clock_mhz": round(sum(s.clock for s in load) / n, 1),
            "avg_power_w": round(sum(s.power_w for s in load) / n, 1),
            "avg_temp_c": round(sum(s.temp for s in load) / n, 1),
            "max_temp_c": max(s.temp for s in load),
            "power_throttle_pct": round(100.0 * sum(1 for s in load if s.reasons & Gpu.PWR_MASK) / n, 1),
            "thermal_throttle_pct": round(100.0 * sum(1 for s in load if s.reasons & Gpu.THERM_MASK) / n, 1),
        }


def driver_events_since(since: datetime) -> list[str]:
    """NVIDIA driver errors (nvlddmkm) and TDR resets (event 4101) from the Windows System log."""
    if os.name != "nt":
        return []
    ts = (since - timedelta(seconds=2)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    query = (f"*[System[(Provider[@Name='nvlddmkm'] or EventID=4101) "
             f"and TimeCreated[@SystemTime>='{ts}']]]")
    try:
        r = subprocess.run(["wevtutil", "qe", "System", f"/q:{query}", "/c:3", "/f:text"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return []
    out = r.stdout.strip()
    return [out[:400]] if out else []


# ----------------------------------------------------------------------------
# External test runners (OCCT, Superposition, anything with a command line)
# ----------------------------------------------------------------------------
@dataclass
class RunOutcome:
    ok: bool
    reason: str = ""
    score: Optional[float] = None
    tail: str = ""


def kill_tree(proc: subprocess.Popen) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
    else:
        proc.kill()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        pass


class CommandRunner:
    def __init__(self, cfg: RunnerConfig, label: str):
        self.cfg = cfg
        self.label = label

    @property
    def configured(self) -> bool:
        return bool(self.cfg.cmd)

    def run(self, monitor: Monitor, duration_s: Optional[int] = None) -> RunOutcome:
        if not self.configured:
            raise ConfigError(f"The '{self.label}' command is not set in the config file.")
        duration = duration_s or self.cfg.duration_s
        cmd = [str(a).replace("{duration}", str(duration)) for a in self.cfg.cmd]
        started = time.time()
        logf = tempfile.NamedTemporaryFile("w+b", suffix=".log", delete=False)
        try:
            proc = subprocess.Popen(cmd, cwd=self.cfg.cwd or None, stdout=logf, stderr=subprocess.STDOUT)
        except OSError as exc:
            logf.close()
            return RunOutcome(False, f"cannot start {self.label}: {exc}")

        forced: Optional[str] = None
        killed_by_us = False
        deadline = started + duration + self.cfg.grace_s
        while proc.poll() is None:
            now = time.time()
            if monitor.error:
                forced = f"driver or GPU fault: {monitor.error}"
            elif monitor.thermal_exceeded:
                forced = f"core temperature exceeded {monitor.temp_limit_c} C"
            elif self.cfg.kill_after_duration and now - started >= duration:
                killed_by_us = True
                kill_tree(proc)
                break
            elif now > deadline:
                forced = "test hung or overran its time limit"
            if forced:
                kill_tree(proc)
                break
            time.sleep(1)

        elapsed = time.time() - started
        logf.flush()
        logf.close()
        text = Path(logf.name).read_text(encoding="utf-8", errors="replace")
        try:
            os.unlink(logf.name)
        except OSError:
            pass
        if self.cfg.log_file:
            fresh = [p for p in glob.glob(self.cfg.log_file) if os.path.getmtime(p) >= started - 2]
            if fresh:
                newest = max(fresh, key=os.path.getmtime)
                text += "\n" + Path(newest).read_text(encoding="utf-8", errors="replace")
        tail = text[-500:]

        if forced:
            return RunOutcome(False, forced, None, tail)
        rc = proc.returncode
        if not killed_by_us and rc not in (0, None):
            return RunOutcome(False, f"{self.label} exited with code {rc}", None, tail)
        if not killed_by_us and elapsed < duration * self.cfg.min_runtime_fraction:
            return RunOutcome(False, f"{self.label} ended after {elapsed:.0f}s, expected {duration}s", None, tail)
        if self.cfg.error_regex:
            m = re.search(self.cfg.error_regex, text, re.IGNORECASE | re.MULTILINE)
            if m:
                return RunOutcome(False, f"{self.label} reported an error: {m.group(0)[:120]}", None, tail)
        score = None
        if self.cfg.score_regex:
            matches = list(re.finditer(self.cfg.score_regex, text))
            if matches:
                try:
                    score = float(matches[-1].group(1).replace(",", ""))
                except (ValueError, IndexError):
                    score = None
        return RunOutcome(True, "", score, tail)


# ----------------------------------------------------------------------------
# Backends
# ----------------------------------------------------------------------------
def set_profile_keys(text: str, section: str, values: dict, remove: tuple = ()) -> str:
    """Edit one INI section in place, preserving every other line byte for byte."""
    nl = "\r\n" if "\r\n" in text else "\n"
    header = f"[{section}]".lower()
    out: list[str] = []
    in_sec = found = False
    done: set[str] = set()

    def flush_missing() -> None:
        for k, v in values.items():
            if k not in done:
                out.append(f"{k}={v}")

    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            if in_sec:
                flush_missing()
                in_sec = False
            if s.lower() == header:
                in_sec = found = True
            out.append(line)
            continue
        if in_sec and "=" in s:
            key = s.split("=", 1)[0].strip().lower()
            if key in remove:
                continue
            match = next((k for k in values if k.lower() == key), None)
            if match:
                out.append(f"{match}={values[match]}")
                done.add(match)
                continue
        out.append(line)
    if in_sec:
        flush_missing()
    if not found:
        raise BackendError(f"Section [{section}] not found in the Afterburner profile file.")
    return nl.join(out) + nl


def section_names(text: str) -> list:
    return [l.strip()[1:-1] for l in text.splitlines()
            if l.strip().startswith("[") and l.strip().endswith("]")]


def read_section(text: str, section: str) -> dict:
    out: dict = {}
    in_sec = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_sec = s.lower() == f"[{section}]".lower()
            continue
        if in_sec and "=" in s:
            key, value = s.split("=", 1)
            out[key.strip()] = value.strip()
    return out


def build_profile_text(text: str, slot: int, core_mhz: float, mem_mhz: float,
                       power_pct: Optional[int]) -> str:
    """Return the profile file text with the tool's slot set to a pure offset profile.

    The slot always receives the stock curve stored in [Defaults]. An empty VFCurve
    means "leave unchanged" in Afterburner profiles, which would stack the offset on
    top of any custom curve already active (for example the one in [Startup]).
    """
    section = f"Profile{slot}"
    if section.lower() not in [n.lower() for n in section_names(text)]:
        raise BackendError(f"[{section}] is missing from the Afterburner profile file. Open "
                           f"Afterburner, click Save, then slot {slot}, once, and retry.")
    stock = read_section(text, "Defaults").get("VFCurve", "")
    if not stock:
        raise BackendError("[Defaults] has no VFCurve, so the stock curve is unknown. Open "
                           "Afterburner, click Reset, then Apply, and retry.")
    values = {"CoreClkBoost": str(int(round(core_mhz * 1000))),
              "MemClkBoost": str(int(round(mem_mhz * 1000))),
              "VFCurve": stock}
    if power_pct:
        values["PowerLimit"] = str(power_pct)
    return set_profile_keys(text, section, values)


# Curve layout inferred from one Turing profile file (RTX 2070): a 12 byte header, then
# 128 records of three little endian float32 values (voltage mV, base MHz, offset MHz),
# then data this tool never touches. The effective clock per point is base + offset.
CURVE_POINTS = 128
CURVE_HEADER = 12


def decode_vfcurve(hexstr: str) -> list:
    raw = bytes.fromhex(hexstr)
    if len(raw) < CURVE_HEADER + CURVE_POINTS * 12:
        raise BackendError("VFCurve is shorter than the layout this tool understands.")
    return [struct.unpack_from("<3f", raw, CURVE_HEADER + i * 12) for i in range(CURVE_POINTS)]


def describe_curve(points: list) -> str:
    eff = [(v, b + o) for v, b, o in points if v > 0]
    peak = max(f for _, f in eff)
    cap_v = min(v for v, f in eff if f >= peak)
    return f"peak {peak:.0f} MHz, first reached at {cap_v:.1f} mV"


class AfterburnerBackend:
    def __init__(self, cfg: Config, gpu: Gpu):
        self.cfg = cfg
        self.gpu = gpu
        self.exe = Path(cfg.afterburner_exe)
        if not self.exe.exists():
            raise BackendError(f"MSI Afterburner not found at {self.exe}")
        self.profile = self._find_profile()
        self.section = f"Profile{cfg.afterburner_slot}"
        build_profile_text(self.profile.read_bytes().decode("latin-1"),
                           cfg.afterburner_slot, 0, 0, None)  # fail fast on a bad file
        self.power_pct: Optional[int] = None
        if cfg.max_power_limit:
            _, default, hi = gpu.power_limits()
            self.power_pct = int(round(100.0 * hi / default))
        backup = self.profile.with_name(self.profile.name + ".gpu_tuner.bak")
        if not backup.exists():
            backup.write_bytes(self.profile.read_bytes())
            log(f"Backed up Afterburner profile file to {backup.name}")

    def _find_profile(self) -> Path:
        if self.cfg.afterburner_profile_file:
            p = Path(self.cfg.afterburner_profile_file)
            if not p.exists():
                raise BackendError(f"Profile file not found: {p}")
            return p
        folder = Path(self.cfg.afterburner_profile_dir)
        dev = self.gpu.pci_device_id
        found = []
        for p in folder.glob("VEN_10DE*.cfg"):
            m = re.search(r"DEV_([0-9A-Fa-f]{4})", p.name)
            if m and int(m.group(1), 16) == dev:
                found.append(p)
        if len(found) > 1:
            bus = self.gpu.pci_bus
            found = [p for p in found if re.search(rf"BUS_(?:{bus}|{bus:X})(?![0-9A-Za-z])", p.name)] or found
        if len(found) != 1:
            names = ", ".join(p.name for p in found) or "none"
            raise BackendError("Could not pick the Afterburner profile file automatically "
                               f"(candidates: {names}). Set afterburner_profile_file in the config.")
        return found[0]

    def apply(self, core_mhz: float, mem_mhz: float) -> None:
        for attempt in (1, 2):
            text = self.profile.read_bytes().decode("latin-1")
            new = build_profile_text(text, self.cfg.afterburner_slot, core_mhz, mem_mhz, self.power_pct)
            tmp = self.profile.with_name(self.profile.name + ".tmp")
            tmp.write_bytes(new.encode("latin-1"))
            os.replace(tmp, self.profile)
            try:
                subprocess.run([str(self.exe), f"-Profile{self.cfg.afterburner_slot}"],
                               capture_output=True, timeout=30)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise BackendError(f"Could not invoke Afterburner: {exc}") from exc
            time.sleep(self.cfg.afterburner_settle_s)
            offsets = self.gpu.get_offsets()
            if offsets is None:
                if attempt == 1:
                    log("warning: NVML cannot read back offsets, applied values are unverified")
                return
            if abs(offsets[0] - core_mhz) <= 8:
                return
            log(f"warning: core offset reads {offsets[0]} MHz, expected {core_mhz:.0f}; retrying")
        raise BackendError("Afterburner did not apply the requested core offset. Check that the "
                           f"profile slot {self.cfg.afterburner_slot} was saved once in Afterburner.")


class NvmlBackend:
    def __init__(self, cfg: Config, gpu: Gpu):
        self.cfg = cfg
        self.gpu = gpu

    def apply(self, core_mhz: float, mem_mhz: float) -> None:
        self.gpu.set_offsets(core_mhz, mem_mhz * self.cfg.nvml_mem_scale)
        time.sleep(1)


def make_backend(cfg: Config, gpu: Gpu):
    if cfg.backend == "afterburner":
        return AfterburnerBackend(cfg, gpu)
    if cfg.backend == "nvml":
        return NvmlBackend(cfg, gpu)
    raise ConfigError(f"Unknown backend: {cfg.backend}")


# ----------------------------------------------------------------------------
# State, trials, evaluator
# ----------------------------------------------------------------------------
@dataclass
class TrialResult:
    key: str
    tag: str
    core: float
    mem: float
    lock: Optional[int]
    passed: bool
    reason: str
    score: Optional[float]
    stats: dict
    ts: str


class State:
    def __init__(self, path: str, gpu_uuid: str, fresh: bool):
        self.path = Path(path)
        self.data: dict = {"gpu": gpu_uuid, "trials": [], "pending": None}
        if self.path.exists() and not fresh:
            try:
                loaded = json.loads(self.path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                loaded = None
            if loaded and loaded.get("gpu") == gpu_uuid:
                self.data = loaded

    def save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, indent=2), encoding="utf-8")
        os.replace(tmp, self.path)

    def find(self, key: str) -> Optional[TrialResult]:
        for t in self.data["trials"]:
            if t["key"] == key:
                return TrialResult(**t)
        return None

    def set_pending(self, pending: dict) -> None:
        self.data["pending"] = pending
        self.save()

    def finish(self, result: TrialResult) -> None:
        self.data["trials"].append(asdict(result))
        self.data["pending"] = None
        self.save()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Evaluator:
    def __init__(self, cfg: Config, gpu: Gpu, backend, state: State,
                 stress: CommandRunner, bench: CommandRunner):
        self.cfg, self.gpu, self.backend, self.state = cfg, gpu, backend, state
        self.stress, self.bench = stress, bench

    # -- lifecycle -----------------------------------------------------------
    def prepare(self) -> None:
        if self.cfg.max_power_limit:
            try:
                _, _, hi = self.gpu.power_limits()
                self.gpu.set_power_limit_mw(hi)
                log(f"Power limit set to maximum ({hi / 1000:.0f} W)")
            except pynvml.NVMLError as exc:
                log(f"warning: could not raise the power limit: {exc}")
        pending = self.state.data.get("pending")
        if pending:
            log(f"Previous run ended during trial {pending['key']}: recording it as a crash.")
            self.state.finish(TrialResult(
                key=pending["key"], tag=pending["tag"], core=pending["core"], mem=pending["mem"],
                lock=pending["lock"], passed=False, reason="system crash or reboot during trial",
                score=None, stats={}, ts=now_iso()))
        self.safe_reset()

    def safe_reset(self) -> None:
        self.gpu.unlock_clock()
        self.backend.apply(0, 0)

    def _recover(self) -> None:
        deadline = time.time() + 120
        while True:
            try:
                self.gpu.reinit()
                self.gpu.sample()
                self.safe_reset()
                return
            except Exception as exc:
                if time.time() > deadline:
                    raise FatalGpuError("The GPU did not recover. Reboot and run 'tune' again; "
                                        "the run resumes from the saved state.") from exc
                time.sleep(5)

    def _cooldown(self) -> None:
        deadline = time.time() + self.cfg.cooldown_max_s
        while time.time() < deadline:
            try:
                if self.gpu.sample().temp <= self.cfg.cooldown_target_c:
                    return
            except Exception:
                return
            time.sleep(5)

    # -- one trial -----------------------------------------------------------
    def trial(self, core: float, mem: float, lock: Optional[int],
              duration: Optional[int], want_score: bool, tag: str) -> TrialResult:
        key = f"{tag}|{core}|{mem}|{lock}|{duration}|{int(want_score)}"
        cached = self.state.find(key)
        if cached:
            log(f"[{tag}] core=+{core:g} mem=+{mem:g} lock={lock}: cached "
                f"{'PASS' if cached.passed else 'FAIL'} ({cached.reason or 'ok'})")
            return cached

        log(f"[{tag}] testing core=+{core:g} MHz mem=+{mem:g} MHz lock={lock}")
        self._cooldown()
        self.state.set_pending({"key": key, "tag": tag, "core": core, "mem": mem, "lock": lock})
        started = datetime.now(timezone.utc)
        passed, reason, score, stats = False, "", None, {}
        monitor: Optional[Monitor] = None
        try:
            self.backend.apply(core, mem)
            if lock:
                self.gpu.lock_clock(lock, pin=(tag != "soak"))
            else:
                self.gpu.unlock_clock()
            monitor = Monitor(self.gpu, self.cfg.temp_limit_c)
            monitor.start()
            out = self.stress.run(monitor, duration)
            passed, reason = out.ok, out.reason
            if passed and want_score:
                out2 = self.bench.run(monitor)
                passed, reason, score = out2.ok, out2.reason, out2.score
                if passed and score is None:
                    passed, reason = False, "benchmark produced no score (check score_regex)"
        except (BackendError, pynvml.NVMLError) as exc:
            passed, reason = False, f"{type(exc).__name__}: {exc}"
        finally:
            if monitor:
                monitor.stop()
                stats = monitor.summary()
        if passed and self.cfg.check_driver_events:
            events = driver_events_since(started)
            if events:
                passed, reason = False, f"driver event logged: {events[0][:160]}"

        result = TrialResult(key, tag, core, mem, lock, passed, reason, score, stats, now_iso())
        self.state.finish(result)
        log(f"    -> {'PASS' if passed else 'FAIL'} {reason} {stats if stats else ''}"
            f"{f' score={score}' if score is not None else ''}")
        if not passed:
            self._recover()
        return result


# ----------------------------------------------------------------------------
# Search logic (pure functions, independent of hardware)
# ----------------------------------------------------------------------------
def ascend(passes: Callable[[float], bool], good: float, step: float, hi: float):
    cur = round(good + step, 3)
    while cur <= hi:
        if passes(cur):
            good, cur = cur, round(cur + step, 3)
        else:
            return good, cur
    return good, None


def descend(passes: Callable[[float], bool], bad: float, step: float, lo: float):
    cur = round(bad - step, 3)
    while cur > lo:
        if passes(cur):
            return cur, bad
        bad, cur = cur, round(cur - step, 3)
    return lo, bad  # lo is the stock value and is assumed good


def search_up(passes: Callable[[float], bool], start: float, coarse: float,
              fine: Optional[float], lo: float, hi: float) -> float:
    """Highest passing offset. 'lo' must be a known good value (stock)."""
    if passes(start):
        good, bad = ascend(passes, start, coarse, hi)
    else:
        good, bad = descend(passes, start, coarse, lo)
    if bad is not None and fine and fine < coarse:
        cur = round(good + fine, 3)
        while cur < bad:
            if passes(cur):
                good, cur = cur, round(cur + fine, 3)
            else:
                break
    return good


def snap(mhz: float, step: float) -> int:
    return int(round(round(mhz / step) * step))


def tune_memory(ev: Evaluator, cfg: Config, core: float, lock: Optional[int]) -> float:
    use_score = ev.bench.configured
    if not use_score and not cfg.allow_unscored_memory:
        log("Memory phase skipped: no benchmark is configured, so error correction regressions "
            "cannot be detected. Set 'benchmark' or allow_unscored_memory.")
        return 0.0
    best = {"score": None}
    if use_score:
        ref = ev.trial(core, 0, lock, None, True, "mem")
        if not ref.passed or ref.score is None:
            raise TunerError(f"Reference benchmark failed: {ref.reason}")
        best["score"] = ref.score
        log(f"Reference benchmark score: {ref.score}")

    def passes(m: float) -> bool:
        r = ev.trial(core, m, lock, None, use_score, "mem")
        if not r.passed:
            return False
        if use_score:
            if r.score < best["score"] * (1 - cfg.score_tolerance):
                log(f"    score regression at +{m:g} MHz ({r.score} vs best {best['score']})")
                return False
            best["score"] = max(best["score"], r.score)
        return True

    return search_up(passes, cfg.mem_start_mhz, cfg.mem_coarse_mhz, cfg.mem_fine_mhz, 0.0, cfg.mem_max_mhz)


def finalize(ev: Evaluator, cfg: Config, core: float, mem: float, lock: Optional[int]):
    while True:
        r = ev.trial(core, mem, lock, cfg.soak_duration_s, False, "soak")
        if r.passed:
            return core, mem, r
        if core > 0:
            core = max(0.0, round(core - cfg.clock_step_mhz, 3))
        elif mem > 0:
            mem = max(0.0, mem - cfg.mem_fine_mhz)
        else:
            raise TunerError("Even stock offsets fail the soak. Check cooling, power delivery and the test setup.")
        log(f"Soak failed, stepping back to core=+{core:g} mem=+{mem:g}")


# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------
def apply_settings(gpu: Gpu, backend, core: float, mem: float, lock: Optional[int]) -> None:
    backend.apply(core, mem)
    if lock:
        gpu.lock_clock(lock, pin=False)
    else:
        gpu.unlock_clock()


def cmd_tune(cfg: Config, fresh: bool, apply_final: bool) -> None:
    require_admin()
    gpu = Gpu(cfg.gpu_index)
    log(f"GPU: {gpu.name}")
    log("Before continuing: in Afterburner untick 'Apply overclocking at system startup' and save "
        f"profile slot {cfg.afterburner_slot} once. If Windows loops on boot, use Safe Mode.")
    backend = make_backend(cfg, gpu)
    stress, bench = CommandRunner(cfg.stress, "stress"), CommandRunner(cfg.benchmark, "benchmark")
    if not stress.configured:
        raise ConfigError("Set 'stress.cmd' in the config file (your OCCT command line).")
    state = State(cfg.state_file, gpu.uuid, fresh)
    ev = Evaluator(cfg, gpu, backend, state, stress, bench)
    completed = False
    try:
        ev.prepare()
        base = ev.trial(0, 0, None, None, False, "baseline")
        if not base.passed:
            raise TunerError(f"Stock settings failed the baseline: {base.reason}")
        step = cfg.clock_step_mhz
        lock: Optional[int] = None

        if cfg.mode == "oc":
            core = search_up(lambda c: ev.trial(c, 0, None, None, False, "core").passed,
                             cfg.core_start_mhz, step, None, 0.0, cfg.core_max_mhz)
        elif cfg.mode == "uv":
            target = cfg.uv_target_mhz or base.stats.get("avg_clock_mhz")
            if not target:
                raise TunerError("No baseline clock available. Set uv_target_mhz.")
            lock = snap(target, step)
            log(f"Undervolt target: core locked at {lock} MHz")
            core = search_up(lambda c: ev.trial(c, 0, lock, None, False, "uv").passed,
                             cfg.uv_start_offset_mhz, step, None, 0.0, cfg.uv_max_offset_mhz)
        else:
            raise ConfigError(f"Unknown mode: {cfg.mode}")
        log(f"Core search result: +{core:g} MHz")

        mem = tune_memory(ev, cfg, core, lock) if cfg.tune_memory else 0.0
        log(f"Memory search result: +{mem:g} MHz")

        core, mem, soak = finalize(ev, cfg, core, mem, lock)
        result = {
            "gpu": gpu.name, "mode": cfg.mode, "generated": now_iso(),
            "final": {"core_offset_mhz": core, "mem_offset_mhz": mem, "locked_clock_mhz": lock},
            "baseline": base.stats, "soak": soak.stats,
            "delta": {k: round(soak.stats.get(k, 0) - base.stats.get(k, 0), 1)
                      for k in ("avg_clock_mhz", "avg_power_w", "avg_temp_c")},
        }
        Path(cfg.result_file).write_text(json.dumps(result, indent=2), encoding="utf-8")
        log(f"FINAL: core +{core:g} MHz, memory +{mem:g} MHz, locked clock {lock}")
        log(f"Baseline: {base.stats}")
        log(f"Soak:     {soak.stats}")
        log(f"Saved {cfg.result_file}")
        if apply_final:
            apply_settings(gpu, backend, core, mem, lock)
            log("Final settings applied (a clock lock does not survive a reboot; see 'apply').")
        completed = True
    finally:
        if not completed:
            try:
                ev.safe_reset()
                log("Reset to stock settings.")
            except Exception as exc:
                log(f"warning: reset failed, reset manually in Afterburner: {exc}")


def cmd_apply(cfg: Config) -> None:
    require_admin()
    result = json.loads(Path(cfg.result_file).read_text(encoding="utf-8"))["final"]
    gpu = Gpu(cfg.gpu_index)
    backend = make_backend(cfg, gpu)
    if cfg.max_power_limit:
        gpu.set_power_limit_mw(gpu.power_limits()[2])
    apply_settings(gpu, backend, result["core_offset_mhz"], result["mem_offset_mhz"], result["locked_clock_mhz"])
    log(f"Applied: {result}")


def cmd_reset(cfg: Config) -> None:
    require_admin()
    gpu = Gpu(cfg.gpu_index)
    gpu.unlock_clock()
    make_backend(cfg, gpu).apply(0, 0)
    log("Stock offsets restored and clock lock removed.")


def cmd_status(cfg: Config) -> None:
    gpu = Gpu(cfg.gpu_index)
    lo, default, hi = gpu.power_limits()
    s = gpu.sample()
    log(f"GPU {gpu.index}: {gpu.name} (device id {gpu.pci_device_id:04X}, bus {gpu.pci_bus})")
    log(f"Power limit {gpu.power_limit_mw() / 1000:.0f} W (min {lo / 1000:.0f}, default {default / 1000:.0f}, max {hi / 1000:.0f})")
    log(f"Offsets (core, mem raw): {gpu.get_offsets()}")
    log(f"Now: {s.temp} C, {s.power_w:.0f} W, {s.clock} MHz core, {s.mem_clock} MHz mem, util {s.util}%")
    if cfg.backend == "afterburner":
        try:
            backend = AfterburnerBackend(cfg, gpu)
        except TunerError as exc:
            log(f"Afterburner: {exc}")
            return
        log(f"Afterburner profile file: {backend.profile}")
        text = backend.profile.read_bytes().decode("latin-1")
        for name in ["Defaults", "Startup"] + [n for n in section_names(text) if n.startswith("Profile")]:
            sec = read_section(text, name)
            if not sec.get("VFCurve"):
                continue
            try:
                curve = describe_curve(decode_vfcurve(sec["VFCurve"]))
            except (BackendError, ValueError) as exc:
                curve = f"curve unreadable ({exc})"
            mem = int(sec["MemClkBoost"]) // 1000 if sec.get("MemClkBoost", "").lstrip("-").isdigit() else "?"
            log(f"  [{name}] {curve}; memory +{mem} MHz; power limit {sec.get('PowerLimit') or '?'}%")


def main() -> int:
    parser = argparse.ArgumentParser(description="Automated NVIDIA GPU overclock and undervolt tuner")
    parser.add_argument("--config", default="gpu_tuner.json")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init", help="write a default config file")
    t = sub.add_parser("tune", help="run the full search")
    t.add_argument("--fresh", action="store_true", help="ignore saved trial history")
    t.add_argument("--no-apply", action="store_true", help="do not apply the final settings")
    sub.add_parser("apply", help="apply the settings from the last result")
    sub.add_parser("reset", help="restore stock offsets and remove the clock lock")
    sub.add_parser("status", help="show GPU and backend information")
    args = parser.parse_args()
    path = Path(args.config)

    try:
        if args.command == "init":
            if path.exists():
                raise ConfigError(f"{path} already exists.")
            path.write_text(json.dumps(asdict(Config()), indent=2), encoding="utf-8")
            log(f"Wrote {path}. Set stress.cmd (and benchmark.cmd) before running 'tune'.")
            return 0
        cfg = load_config(path)
        if args.command == "tune":
            cmd_tune(cfg, args.fresh, not args.no_apply)
        elif args.command == "apply":
            cmd_apply(cfg)
        elif args.command == "reset":
            cmd_reset(cfg)
        elif args.command == "status":
            cmd_status(cfg)
    except KeyboardInterrupt:
        log("Interrupted.")
        return 130
    except TunerError as exc:
        log(f"ERROR: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
