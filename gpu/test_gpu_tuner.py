import pytest
import gpu_tuner as g


def fake(limit):
    calls = []

    def passes(x):
        calls.append(x)
        return x <= limit
    return passes, calls


def test_core_ascends_to_first_failure():
    p, calls = fake(135)
    assert g.search_up(p, 75, 15, None, 0, 300) == 135
    assert calls == [75, 90, 105, 120, 135, 150]


def test_core_descends_when_start_fails():
    p, _ = fake(50)
    assert g.search_up(p, 75, 15, None, 0, 300) == 45


def test_core_falls_back_to_stock():
    p, _ = fake(0)
    assert g.search_up(p, 75, 15, None, 0, 300) == 0


def test_core_respects_ceiling():
    p, _ = fake(9999)
    assert g.search_up(p, 75, 15, None, 0, 300) == 300


def test_memory_coarse_then_fine():
    p, calls = fake(770)
    assert g.search_up(p, 500, 100, 50, 0, 1500) == 750
    assert calls == [500, 600, 700, 800, 750]


def test_memory_descends_then_refines():
    p, _ = fake(230)
    assert g.search_up(p, 500, 100, 50, 0, 1500) == 200


def test_pascal_half_steps():
    p, _ = fake(87.5)
    assert g.search_up(p, 75, 12.5, None, 0, 300) == 87.5


PROFILE = ("[Startup]\r\nFormat=2\r\n\r\n[Profile4]\r\nCoreClkBoost=1\r\n\r\n"
           "[Profile5]\r\nCoreClkBoost=0\r\nVFCurve=ABCDEF\r\nMemClkBoost=0\r\nFanMode=1\r\n\r\n"
           "[Other]\r\nX=1\r\n")


def test_profile_editor_changes_only_target_section():
    out = g.set_profile_keys(PROFILE, "Profile5",
                             {"CoreClkBoost": "90000", "MemClkBoost": "700000", "PowerLimit": "110"},
                             remove=("vfcurve",))
    assert "CoreClkBoost=90000" in out and "MemClkBoost=700000" in out and "PowerLimit=110" in out
    assert "VFCurve" not in out
    assert "[Profile4]\r\nCoreClkBoost=1" in out and "X=1" in out
    assert "FanMode=1" in out and "\r\n" in out


def test_profile_editor_missing_section_raises():
    with pytest.raises(g.BackendError):
        g.set_profile_keys(PROFILE, "Profile9", {"a": "1"})


def test_snap_to_clock_bins():
    assert g.snap(1893, 15) == 1890
    assert g.snap(1893, 12.5) == 1888


def test_config_roundtrip(tmp_path):
    import dataclasses, json
    p = tmp_path / "c.json"
    p.write_text(json.dumps(dataclasses.asdict(g.Config())))
    cfg = g.load_config(p)
    assert isinstance(cfg.stress, g.RunnerConfig) and cfg.benchmark.duration_s == 300


def test_unknown_config_key_rejected(tmp_path):
    p = tmp_path / "c.json"
    p.write_text('{"nonsense": 1}')
    with pytest.raises(g.ConfigError):
        g.load_config(p)


# ---- Afterburner profile handling (curve layout inferred from a real RTX 2070 file) ----
import glob
import os
import struct


def make_curve(offset=0.0, cap=None):
    head = bytes.fromhex("00000200" "80000000" "00000000")
    body = b""
    for i in range(128):
        volt = 450.0 + 6.25 * i
        base = 465.0 + 12.0 * i
        off = offset
        if cap is not None and base + off > cap:
            off = cap - base
        body += struct.pack("<3f", volt, base, off)
    return (head + body + bytes(8)).hex().upper()


SYNTH = ("[Defaults]\r\nPowerLimit=100\r\nCoreClkBoost=0\r\nVFCurve=" + make_curve() + "\r\nMemClkBoost=0\r\n"
         "[Startup]\r\nCoreClkBoost=1\r\nVFCurve=" + make_curve(90, 1900) + "\r\n"
         "[Profile5]\r\nFormat=2\r\nPowerLimit=\r\nCoreClkBoost=\r\nVFCurve=\r\nMemClkBoost=\r\nFanMode=\r\n")


def test_build_profile_always_writes_stock_curve():
    out = g.build_profile_text(SYNTH, 5, 75, 500, 110)
    sec = g.read_section(out, "Profile5")
    assert sec["CoreClkBoost"] == "75000" and sec["MemClkBoost"] == "500000" and sec["PowerLimit"] == "110"
    assert sec["VFCurve"] == g.read_section(SYNTH, "Defaults")["VFCurve"]
    assert sec["FanMode"] == ""                      # fan settings stay untouched
    assert g.read_section(out, "Startup") == g.read_section(SYNTH, "Startup")


def test_build_profile_requires_slot_and_defaults():
    with pytest.raises(g.BackendError):
        g.build_profile_text(SYNTH, 4, 0, 0, None)
    with pytest.raises(g.BackendError):
        g.build_profile_text("[Profile5]\r\nCoreClkBoost=\r\n", 5, 0, 0, None)


def test_decode_and_describe_curve():
    stock = g.decode_vfcurve(make_curve())
    assert len(stock) == 128 and stock[0] == (450.0, 465.0, 0.0)
    capped = g.decode_vfcurve(make_curve(90, 1900))
    assert g.describe_curve(capped).startswith("peak 1900 MHz")
    with pytest.raises(g.BackendError):
        g.decode_vfcurve("00" * 20)


REAL = glob.glob("/mnt/user-data/uploads/VEN_10DE*DEV_1F07*.cfg")


@pytest.mark.skipif(not REAL, reason="real Afterburner profile not present")
def test_real_profile_file():
    text = open(REAL[0], "rb").read().decode("latin-1")
    assert g.describe_curve(g.decode_vfcurve(g.read_section(text, "Defaults")["VFCurve"])) == "peak 1995 MHz, first reached at 1168.8 mV"
    assert g.describe_curve(g.decode_vfcurve(g.read_section(text, "Startup")["VFCurve"])) == "peak 2010 MHz, first reached at 1031.2 mV"
    new = g.build_profile_text(text, 5, 90, 700, 120)
    assert len(new.splitlines()) == len(text.splitlines())
    for name in ("Defaults", "Startup", "Profile1", "Profile2", "Profile3"):
        assert g.read_section(new, name) == g.read_section(text, name)
