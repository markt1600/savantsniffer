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
    assert discovery.guess_vendor("00:0f:e7:aa:bb:cc") == "Lutron"        # real Lutron OUI
    assert discovery.guess_vendor("0:f:e7:aa:bb:cc") == "Lutron"          # arp -a style, no leading zeros
    assert discovery.guess_vendor("b8:1:1f:67:a:10") == "Apple"
    assert discovery.guess_vendor("00:1a:ae:00:00:01") == "Savant"
    assert discovery.guess_vendor("a2:f9:81:97:bc:c8") == "private"       # randomised address
    assert discovery.guess_vendor("de:ad:be:ef:00:01", "Lutron Electronics") == "Lutron"
    assert discovery.guess_vendor("dc:ad:be:ef:00:01") == "unknown"       # unregistered, not private
    assert "D&M" in discovery.vendor_name("0:6:78:a2:e3:6b")


def test_arp_scan_parser():
    text = "192.168.1.50\t00:0f:e7:11:22:33\tLutron Electronics Co\n" \
           "192.168.1.20\tb8:01:1f:44:55:66\tApple, Inc.\n"
    hosts = discovery.parse_scan_output("arp-scan", text)
    assert len(hosts) == 2
    assert hosts[0].classification == "Lutron"
    assert hosts[1].classification == "Apple"


def test_nmap_parser():
    text = ("Nmap scan report for 192.168.1.50\n"
            "Host is up.\n"
            "MAC Address: 00:0F:E7:11:22:33 (Lutron Electronics)\n")
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


# ---- socket-level tests for the LIP client (no hardware: socketpair) ----

def _client_on_socketpair():
    import socket
    from savantsniffer.lip import LIPClient
    a, b = socket.socketpair()
    c = LIPClient("unused")
    c.sock = a
    a.settimeout(1.0)
    return c, b


def test_login_success_and_prompt_detection():
    import threading
    c, peer = _client_on_socketpair()

    def processor():
        peer.sendall(b"\r\nlogin: ")
        assert peer.recv(64) == b"lutron\r\n"
        peer.sendall(b"password: ")
        assert peer.recv(64) == b"integration\r\n"
        peer.sendall(b"\r\nQNET> ")
    t = threading.Thread(target=processor); t.start()
    c._login()
    t.join()
    assert c.prompt == "QNET>"
    assert c.system == "HomeWorks QS"
    c.close(); peer.close()


def test_login_rejected_raises():
    import threading
    from savantsniffer.lip import LIPAuthError
    c, peer = _client_on_socketpair()

    def processor():
        peer.sendall(b"login: ")
        peer.recv(64)
        peer.sendall(b"password: ")
        peer.recv(64)
        peer.sendall(b"\r\nlogin: ")       # rejected -> prompts again
    t = threading.Thread(target=processor); t.start()
    try:
        c._login()
        assert False, "expected LIPAuthError"
    except LIPAuthError:
        pass
    t.join(); c.close(); peer.close()


def test_read_events_stop_when_quiet():
    """The stop callable must end the loop even if the processor sends nothing."""
    import time
    c, peer = _client_on_socketpair()
    deadline = time.monotonic() + 2.5
    got = list(c.read_events(stop=lambda: time.monotonic() > deadline))
    assert got == []
    c.close(); peer.close()


def test_read_events_parses_and_strips_prompt():
    c, peer = _client_on_socketpair()
    peer.sendall(b"QNET> ~DEVICE,25,3,3\r\n~OUTPUT,12,1,50.00\r\n")
    seen = []
    for ev in c.read_events(stop=lambda: len(seen) >= 2):
        seen.append(ev)
    assert [e.raw for e in seen] == ["~DEVICE,25,3,3", "~OUTPUT,12,1,50.00"]
    assert seen[0].kind == "DEVICE" and seen[1].kind == "OUTPUT"
    c.close(); peer.close()


def test_controller_reuses_live_client_and_disarms():
    """With a live client supplied, no new session is opened and control is re-disarmed."""
    from savantsniffer.controller import Controller
    from savantsniffer.lip import LIPClient
    sent = []

    class Fake(LIPClient):
        def __init__(self): super().__init__("x"); self.sock = object()
        def send_raw(self, line): sent.append(line)
        def _client(self): raise AssertionError("must not open a second session")
    m = DeviceMap({"areas": {}}); m.add_output("kitchen", "island", 12)
    fake = Fake()
    ctl = Controller(m, client=fake)
    ctl._client = lambda: (_ for _ in ()).throw(AssertionError("second session opened"))
    assert ctl.set_level("kitchen island", 40, confirm=True) == "#OUTPUT,12,1,40"
    assert sent == ["#OUTPUT,12,1,40"]
    assert fake._allow_control is False   # disarmed again after sending


# ---- report / correlate / fade ----

def test_set_command_with_fade():
    from savantsniffer.controller import Controller
    assert Controller.set_command(12, 20) == "#OUTPUT,12,1,20"
    assert Controller.set_command(12, 20, 2) == "#OUTPUT,12,1,20,2"
    assert Controller.set_command(12, 20, 0) == "#OUTPUT,12,1,20"


def test_report_contains_commands_and_creds():
    from savantsniffer.report import build_markdown
    m = DeviceMap({"system": "LIP", "processor": "1.2.3.4", "areas": {}})
    m.add_output("kitchen", "island", 12)
    m.add_button("kitchen", "kitchen keypad", 25, 3, label="Room Off", kind="macro", effect={12: 0.0, 13: 0.0})
    m.add_button("study", "study keypad", 40, 2, label="Music", kind="integration")
    md = build_markdown(m, {"LUTRON_LIP_USER": "lutron", "LUTRON_LIP_PASSWORD": "s3cret"})
    assert "`#DEVICE,25,3,3`" in md
    assert "`#OUTPUT,12,1,<0-100>`" in md
    assert "s3cret" in md
    assert "12→0, 13→0" in md
    assert "still needing Savant-side capture" in md and "Music" in md


def test_correlate_matches_press_to_savant_packets():
    from savantsniffer import correlate as co
    import datetime as dt
    t0 = dt.datetime(2026, 9, 21, 19, 42, 7, 318000)
    log = f"{t0.isoformat(timespec='milliseconds')}  ~DEVICE,12,8,3\n" \
          f"{(t0 + dt.timedelta(seconds=10)).isoformat(timespec='milliseconds')}  ~DEVICE,12,8,4\n"   # release ignored
    e = t0.timestamp()
    payload = "PLAY,zone:office\r".encode().hex()
    fields = "\n".join([
        f"{e+0.4:.6f}\t10.0.1.30\t8085\t\t{payload}\t",       # within window
        f"{e+0.9:.6f}\t10.0.1.30\t8085\t\t{payload}\t",
        f"{e+5.0:.6f}\t10.0.1.99\t\t9000\t\t{'00'*4}",         # outside window
    ])
    packets = co.parse_savant_fields(fields)
    presses = co.parse_monitor_log(log)
    assert len(presses) == 1 and presses[0].button == 8
    res = co.correlate(presses, packets, window=2.0)
    assert len(res[0].targets) == 1
    t = res[0].targets[0]
    assert t["dst"] == "10.0.1.30" and t["port"] == 8085 and t["count"] == 2
    assert t["preview"].startswith("PLAY,zone:office")
    assert "keypad 12 button 8" in co.render(res, 2.0)


def test_parse_monitor_log_mac_app_format():
    from savantsniffer import correlate as co
    import datetime as dt
    presses = co.parse_monitor_log("19:42:07.318  ~DEVICE,12,8,3\n", date_hint=dt.date(2026, 9, 21))
    assert len(presses) == 1
    assert dt.datetime.fromtimestamp(presses[0].t).hour == 19
