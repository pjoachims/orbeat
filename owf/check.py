#!/usr/bin/env python3
"""Reference OWF parser + golden-file self-check. Run: python3 check.py"""
import json
from pathlib import Path


def parse_owf(text):
    """Parse OWF text -> (header, samples, events). Truncated last line is dropped."""
    lines = text.split("\n")
    records = []
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            if i == len(lines) - 1:  # crash-truncated final line: discard, keep the rest
                break
            raise
    header, body = records[0], records[1:]
    assert header["owf"] == "0.1" and "start" in header and header["channels"]
    samples = sorted((r for r in body if "ev" not in r), key=lambda r: r["t"])
    events = sorted((r for r in body if "ev" in r), key=lambda r: r["t"])
    for r in body:
        assert isinstance(r["t"], (int, float)) and r["t"] >= 0
    return header, samples, events


def demo():
    g = Path(__file__).parent / "golden"
    read = lambda name: parse_owf((g / name).read_text())

    header, samples, events = read("valid.owf")
    assert header["sport"] == "cycling" and header["channels"]["pwr"] == "W"
    assert len(samples) == 6 and len(events) == 3
    assert "pwr" not in samples[1], "missing channel must stay missing, not zero"

    _, samples, _ = read("minimal.owf")
    assert samples == [{"t": 0, "hr": 72}]

    _, samples, _ = read("sparse.owf")
    assert sum("pwr" in s for s in samples) == 5, "two power dropouts expected"

    _, _, events = read("events.owf")
    assert [e["ev"] for e in events] == ["marker", "lap", "lap", "pause", "resume", "custom_sensor_event"]
    assert events[0]["x-note"] == "warmup done", "x- extension keys survive parsing"

    _, samples, _ = read("truncated.owf")
    assert len(samples) == 2, "truncated final line dropped, earlier lines kept"

    # merge: two recorders, align on absolute time (start delta = 1.5 s)
    (h_mac, s_mac, _), (h_ph, s_ph, _) = read("merge-mac.owf"), read("merge-phone.owf")
    merged = sorted(s_mac + [{**s, "t": s["t"] + 1.5} for s in s_ph], key=lambda s: s["t"])
    assert len(merged) == 7 and {"lat", "pwr"} < set(k for s in merged for k in s)

    print("owf check: all golden files pass")


if __name__ == "__main__":
    demo()
