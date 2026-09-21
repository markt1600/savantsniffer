"""Tests for the pure-logic pieces (no network / no hardware needed)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from savantsniffer import discovery, portcheck
from savantsniffer.devicemap import DeviceMap
from savantsniffer.lip import MonitorEvent
from savantsniffer.webapp import _parse_ids
from savantsniffer.capture import extract_credentials
import datetime as dt


def test_oui_classification():
    assert discovery.guess_vendor("00:16:e1:aa:bb:cc") == "Lutron"
    assert discovery.guess_vendor("f0:18:9e:aa:bb:cc") == "Apple"
    assert discovery.guess_vendor("de:ad:be:ef:00:01", "Lutron Electronics") == "Lutron"
    assert discovery.guess_vendor("de:ad:be:ef:00:01") == "unknown"


def test_arp_scan_parser():
    text = "192.168.1.50\t00:16:e1:11:22:33\tLutron Electronics Co\n" \
           "192.168.1.20\tf0:18:9e:44:55:66\tApple, Inc.\n"
    hosts = discovery.parse_scan_output("arp-scan", text)
    assert len(hosts) == 2
    assert hosts[0].classification == "Lutron"
    assert hosts[1].classification == "Apple"


def test_nmap_parser():
    text = ("Nmap scan report for 192.168.1.50\n"
            "Host is up.\n"
            "MAC Address: 00:16:E1:11:22:33 (Lutron Electronics)\n")
    hosts = discovery.parse_scan_output("nmap", text)
    assert hosts[0].ip == "192.168.1.50"
    assert hosts[0].classification == "Lutron"


def test_likely_system():
    rep = portcheck.ProbeReport("h", [portcheck.PortResult(23, True)])
    assert rep.likely_system()[0] == "LIP"
    rep2 = portcheck.ProbeReport("h", [portcheck.PortResult(8081, True)])
    assert rep2.likely_system()[0] == "LEAP"
    rep3 = portcheck.ProbeReport("h", [portcheck.PortResult(23, False)])
    assert rep3.likely_system()[0] == "unknown"


def test_event_kind():
    e = MonitorEvent(dt.datetime.now(), "~DEVICE,25,3,3")
    assert e.kind == "DEVICE"
    e2 = MonitorEvent(dt.datetime.now(), "~OUTPUT,12,1,50.00")
    assert e2.kind == "OUTPUT"


def test_parse_ids():
    assert _parse_ids("~DEVICE,25,3,3") == {"id": "25", "component": "3", "action": "3"}
    assert _parse_ids("~OUTPUT,12,1,50.00") == {"id": "12", "action": "1", "level": "50.00"}


def test_devicemap_resolution(tmp_path):
    m = DeviceMap({"system": "LIP", "processor": "1.2.3.4", "areas": {}})
    m.add_output("kitchen", "island", 12, "dimmer")
    m.add_output("living room", "lamps", 21)
    m.add_keypad_button("kitchen", "master keypad", 25, 3, "movie")
    r = m.resolve_output("kitchen island")
    assert r.id == 12 and r.area == "kitchen"
    r2 = m.resolve_output("living room lamps")
    assert r2.id == 21
    k = m.resolve_keypad("kitchen master keypad")
    assert k.id == 25 and 3 in k.buttons


def test_devicemap_ambiguous():
    m = DeviceMap({"areas": {}})
    m.add_output("a", "lamp", 1)
    m.add_output("b", "lamp", 2)
    try:
        m.resolve_output("lamp")
        assert False, "should be ambiguous"
    except KeyError as e:
        assert "ambiguous" in str(e)


def test_extract_credentials():
    stream = "\r\nlogin: myuser\r\npassword: s3cret\r\nQNET> "
    c = extract_credentials(stream)
    assert c.username == "myuser"
    assert c.password == "s3cret"
    assert c.found


def test_macro_recorder_classify():
    from savantsniffer.macros import MacroRecorder
    r = MacroRecorder(settle_seconds=0.01)
    r.begin()
    r.feed("~DEVICE,30,4,3")           # the trigger press
    r.feed("~OUTPUT,12,1,0.00")
    r.feed("~OUTPUT,13,1,0.00")
    r.feed("~OUTPUT,21,1,0.00")
    cap = r.finish()
    assert cap.classify() == "macro"
    assert cap.trigger_device == 30 and cap.trigger_button == 4
    assert cap.effect_set() == {12: 0.0, 13: 0.0, 21: 0.0}


def test_macro_single_output_is_output():
    from savantsniffer.macros import MacroRecorder
    r = MacroRecorder()
    r.begin(device=25, button=1)
    r.feed("~OUTPUT,12,1,75.00")
    cap = r.finish()
    assert cap.classify() == "output"


def test_macro_integration_no_output():
    from savantsniffer.macros import MacroRecorder
    r = MacroRecorder()
    r.begin(device=40, button=2)
    r.feed("~DEVICE,40,2,3")   # press only, nothing on Lutron follows
    cap = r.finish()
    assert cap.classify() == "integration"
    assert cap.effect_set() == {}


def test_devicemap_add_button_macro():
    m = DeviceMap({"areas": {}})
    m.add_button("whole house", "entry keypad", 30, 4, label="home off",
                 kind="macro", effect={12: 0.0, 13: 0.0})
    btn = m.data["areas"]["whole house"]["keypads"]["entry keypad"]["buttons"][4]
    assert btn["kind"] == "macro"
    assert len(btn["effect"]) == 2


def test_devicemap_add_button_integration():
    m = DeviceMap({"areas": {}})
    m.add_button("study", "study keypad", 40, 2, label="music", kind="integration")
    btn = m.data["areas"]["study"]["keypads"]["study keypad"]["buttons"][2]
    assert btn["kind"] == "integration"
    assert "note" in btn


def test_merge_seed_preserves_captured(tmp_path):
    import yaml
    seed = {
        "system": "LIP", "processor": None,
        "areas": {
            "kitchen": {"keypads": {"kitchen keypad": {"id": None, "buttons": {
                1: {"label": "Light", "kind": "output", "button": None},
                2: {"label": "Room Off", "kind": "macro", "button": None, "effect": None},
            }}}}
        }
    }
    # start with a map that already captured button 1's real ids
    m = DeviceMap({"areas": {"kitchen": {"keypads": {"kitchen keypad": {
        "id": 25, "buttons": {1: {"label": "Light", "kind": "output", "button": 1}}}}}}})
    added = m.merge_seed(seed)
    kp = m.data["areas"]["kitchen"]["keypads"]["kitchen keypad"]
    assert kp["id"] == 25                       # captured id preserved
    assert kp["buttons"][1]["button"] == 1      # captured button preserved
    assert 2 in kp["buttons"]                    # new button added
    assert added["buttons"] == 1
    assert m.data["system"] == "LIP"            # filled from seed


def test_seed_file_is_valid():
    import os, yaml
    path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "layout.seed.yaml")
    with open(path) as f:
        d = yaml.safe_load(f)
    assert d["areas"]
    total = sum(len(k["buttons"]) for a in d["areas"].values() for k in a["keypads"].values())
    assert total > 100
