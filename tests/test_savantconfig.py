"""Savant configuration importer, exercised on a tiny synthetic RacePointMedia copy."""
import json
import os
import plistlib
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from savantsniffer import savantconfig as sc


def make_copy(root):
    cfg = root / "userConfig.rpmConfig"
    cfg.mkdir(parents=True)
    lite = {"Version": 1, "Controllers": {"Need Assignment": {"Keypads": [{
        "UID": "985DAD7CC0810042", "KeypadName": "Leap Integration Bridge",
        "Areas": {"Home Office": ["/area/2592"], "Kitchen": ["/area/2809"]},
        "Loads": [
            {"LoadName": "Office Downlight", "LoadZone": "Home Office", "Href": "/zone/1095", "LoadSubType": "W",
             "LoadManufacture": "Lutron", "LoadID": "AAA", "LoadMin": 0, "LoadMax": 100},
            {"LoadName": "Hob", "LoadZone": "Kitchen", "Href": "/zone/1446", "LoadSubType": "RELAY",
             "LoadManufacture": "Lutron", "LoadID": "BBB", "LoadMin": 0, "LoadMax": 100},
        ],
        "Shades": [{"LoadName": "Curtain", "LoadZone": "Home Office", "Href": "/zone/3617", "LoadID": "CCC"}],
        "Scenes": [
            {"DeviceLabel": "Broadcast", "SavantZone": "Home Office", "Href": "/button/2639", "LEDref": "/led/2614", "DeviceUID": "X1", "Offset": "902", "ButtonType": "PressAndRelease"},
            {"DeviceLabel": "Vol Up", "SavantZone": "Kitchen", "Href": "/button/2900", "LEDref": "/led/2890", "DeviceUID": "X2", "Offset": "903", "ButtonType": "PressAndRelease"},
            {"DeviceLabel": "Ambient", "SavantZone": "Kitchen", "Href": "/button/2901", "LEDref": "/led/2891", "DeviceUID": "X3", "Offset": "904", "ButtonType": "PressAndRelease"},
            {"DeviceLabel": "Hallway\nAC", "SavantZone": "Kitchen", "Href": "/button/2902", "DeviceUID": "X4", "Offset": "905", "ButtonType": "PressAndRelease"},
        ],
    }]}}}
    with open(cfg / "LiteInterfaceConfiguration.plist", "wb") as f:
        plistlib.dump(lite, f)
    with open(cfg / "rpmSystemInfo.plist", "wb") as f:
        plistlib.dump({"RPMSystemName": "Test House"}, f)
    (cfg / "userConnection.xml").write_text("""<?xml version="1.0"?>
<connection_definitions>
 <component user_defined_name="Output Module">
  <output name_on_component="Analog Audio Out 6"><audio_media type="rca"><connection>
   <peer_io user_defined_name="Kitchen Speakers" name_on_component="RCA"><audio_media type="rca"/></peer_io>
  </connection></audio_media></output>
 </component>
 <component user_defined_name="Denon AVR"><control>
  <ip_control address="192.168.1.80" port="23" name_on_component="NETWORK"/></control></component>
 <component user_defined_name="CCTV 1"><control>
  <ip_control address="admin:secret@192.168.1.101" port="80" name_on_component="Ethernet"/></control></component>
</connection_definitions>""")
    (cfg / "zoneConfig.xml").write_text("""<?xml version="1.0"?>
<zone_config>
 <zone name="Kitchen"><component_list><component user_defined_name="Kitchen Speakers"/></component_list></zone>
 <zone name="Master Bedroom"><component_list><component user_defined_name="Denon AVR"/></component_list></zone>
</zone_config>""")
    wf = cfg / "workflows" / "Kitchen" / "Mark-Lighting-1-SVC_ENV_LIGHTING" / "Vol up (Kitchen).workflow" / "Contents"
    wf.mkdir(parents=True)
    doc = {"actions": [{"action": {"ActionName": "Output Module", "ActionParameters": {
        "RPMClassName": "avAction", "actionName": "IncreaseVolume", "componentID": "Output Module",
        "logicalComponentName": "Audio Zone 6", "requestingServiceName": "SVC_AV_LIVEMEDIAQUERY_SAVANTMEDIAAUDIO"}}}]}
    with open(wf / "document.wflow", "wb") as f:
        plistlib.dump(doc, f)
    wf2 = cfg / "workflows" / "Home Office" / "Mark--1-SVC_GEN_GENERIC" / "Broadcast On (Home Office).workflow" / "Contents"
    wf2.mkdir(parents=True)
    doc2 = {"actions": [{"action": {"ActionName": "Send Service Request", "ActionParameters": {
        "RPMClassName": "svcCallServiceAction", "selectedEvent": "SendSavantScene", "selectedZone": "Home Office",
        "arguments": [{"name": "SceneName", "value": "Broadcast Home Office"}]}}}]}
    with open(wf2 / "document.wflow", "wb") as f:
        plistlib.dump(doc2, f)
    nd = root / "lighting" / "shm" / "sdo" / "NetworkDevice"
    nd.mkdir(parents=True)
    (nd / "985DAD7CC0810042").write_text(json.dumps({"uid": "985DAD7CC0810042", "ip": "192.168.1.173", "devicetype": "TIEL"}))
    ctl = root / "statusfiles" / "controllers"
    ctl.mkdir(parents=True)
    (ctl / "985DAD7CC0810042").write_text(json.dumps({"controllerMacAddr": "38:ab:41:ab:ec:cb"}))
    (root / "lighting" / "shm" / "loadgroups.out").write_text(
        "Scene Hob Scene: Offset(0), Ramp(2), Step(10), Switches(0), Load Members:\n\tPreset 100%, Current 100%\n\t1002D,100,0,100,0,0,100,100,On,100%\n")


def test_import_folder(tmp_path):
    make_copy(tmp_path)
    dmap, f = sc.import_folder(str(tmp_path))
    assert dmap["system"] == "LEAP"
    assert f.system_name == "Test House"
    assert f.bridge_ip == "192.168.1.173"
    assert f.bridge_mac == "98:5d:ad:7c:c0:81"            # from the UID
    assert f.processor_mac == "38:ab:41:ab:ec:cb"
    assert f.counts["buttons"] == 4 and f.counts["loads"] == 2 and f.counts["shades"] == 1
    k = dmap["areas"]["kitchen"]
    assert k["outputs"]["Hob"] == {"id": 1446, "kind": "switch", "href": "/zone/1446", "savant_load_id": "BBB", "level_at_export": 100}
    assert dmap["areas"]["home office"]["outputs"]["Curtain"]["kind"] == "shade"
    btns = k["keypads"]["kitchen keypads"]["buttons"]
    vol = btns[2900]
    assert vol["kind"] == "integration" and vol["href"] == "/button/2900" and vol["led"] == "/led/2890"
    assert vol["savant_workflows"] == ["Vol up (Kitchen) [SVC_ENV_LIGHTING]"]
    assert vol["audio_zones"] == ["Kitchen"]               # Audio Zone 6 -> Kitchen Speakers -> Kitchen
    assert vol["savant_captured"] is True
    assert btns[2901]["kind"] == "macro" and "savant_workflows" not in btns[2901]
    assert btns[2902]["label"] == "Hallway AC" and btns[2902]["kind"] == "hvac"
    bc = dmap["areas"]["home office"]["keypads"]["home office keypads"]["buttons"][2639]
    assert bc["savant_actions"] == ["SendSavantScene 'Broadcast Home Office' in Home Office"]
    # devices: credentials split out, room from zoneConfig, protocol hint
    denon = next(d for d in f.devices if d["name"] == "Denon AVR")
    assert denon["ip"] == "192.168.1.80" and denon["room"] == "Master Bedroom" and "telnet" in denon["protocol"]
    cam = next(d for d in f.devices if d["name"] == "CCTV 1")
    assert cam["ip"] == "192.168.1.101" and cam["credentials"] == "admin:secret"
    md = sc.findings_markdown(f)
    assert "38:ab:41:ab:ec:cb" in md and "Output Module:Audio Zone 6 | Kitchen" in md


def test_missing_folder(tmp_path):
    try:
        sc.import_folder(str(tmp_path))
        assert False, "expected FileNotFoundError"
    except FileNotFoundError:
        pass


def test_classify():
    assert sc.classify_button("Music")[0] == "integration"
    assert sc.classify_button("Room Off")[0] == "macro"
    assert sc.classify_button("Night Curtain")[0] == "shade"
    assert sc.classify_button("Light")[0] == "output"
    assert sc.classify_button("Fan")[0] == "fan"
    assert sc.classify_button("AC")[0] == "hvac"
    assert sc.mac_from_uid("985DAD7CC0810042") == "98:5d:ad:7c:c0:81"
    assert sc.mac_from_uid("nope") == ""
