"""The bundled pre-filled maps: complete, loadable, and free of credentials."""
import json
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from savantsniffer.devicemap import DeviceMap
from savantsniffer.report import build_markdown

ROOT = os.path.dirname(os.path.dirname(__file__))
YAML = os.path.join(ROOT, "savantsniffer", "data", "devices.savant.yaml")
FINDINGS = os.path.join(ROOT, "savantsniffer", "data", "savant_findings.json")
SWIFT = os.path.join(ROOT, "macapp", "Sources", "SavantSniffer", "Resources", "savant.prefill.json")

SECRET_MARKERS = ("avi123", "admin:", "@192.168")   # the camera login never ships


def test_python_prefill_loads_and_has_no_secrets():
    text = open(YAML).read()
    assert not any(m in text.lower() for m in SECRET_MARKERS)
    dmap = DeviceMap(yaml.safe_load(text))
    assert dmap.system == "LEAP" and dmap.processor == "192.168.1.201"
    buttons = sum(len(k["buttons"]) for a in dmap.areas().values() for k in a["keypads"].values())
    loads = sum(len(a["outputs"]) for a in dmap.areas().values())
    assert buttons == 164 and loads == 86
    assert "home office" in dmap.areas()
    assert dmap.resolve_output("home office office downlight").id == 1095
    f = json.load(open(FINDINGS))
    assert not any(m in open(FINDINGS).read().lower() for m in SECRET_MARKERS)
    assert f["processor_mac"] == "38:ab:41:ab:ec:cb" and f["bridge_ip"] == "192.168.1.173"
    dmap.data["savant"]["findings_file"] = FINDINGS
    md = build_markdown(dmap, {})
    assert "## Savant configuration findings" in md and "Output Module:Audio Zone 3 | Home Office" in md


def test_swift_prefill_shape():
    text = open(SWIFT).read()
    assert not any(m in text.lower() for m in SECRET_MARKERS)
    m = json.loads(text)
    assert m["system"] == "LEAP" and m["processor"] == "192.168.1.201"
    assert m["savant"]["processorMAC"] == "38:ab:41:ab:ec:cb"
    n_btn = n_out = 0
    for a in m["areas"]:
        assert set(a) >= {"name", "keypads", "outputs"}
        for k in a["keypads"]:
            assert "name" in k and "buttons" in k
            for b in k["buttons"]:
                assert isinstance(b["label"], str) and isinstance(b["kind"], str) and b["href"].startswith("/button/")
                n_btn += 1
        for o in a["outputs"]:
            assert isinstance(o["id"], int) and isinstance(o["name"], str) and isinstance(o["kind"], str)
            n_out += 1
    assert n_btn == 164 and n_out == 86
    linked = [b for a in m["areas"] for k in a["keypads"] for b in k["buttons"] if b.get("savantWorkflows")]
    assert len(linked) >= 25
    assert any(b.get("audioZones") == ["Kitchen"] for b in linked)   # Vol Up -> Output Module zone 6 -> Kitchen
