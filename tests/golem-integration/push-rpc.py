#!/usr/bin/env python3
"""Isolated real-daemon push capability checks; no live key or network sends."""
import json, os, pathlib, plistlib, socket, subprocess, tempfile, time, uuid
root=pathlib.Path(tempfile.mkdtemp(prefix="golem-push-rpc.",dir="/tmp"))
data=root/"data";data.mkdir()
golem_id=str(uuid.uuid4());other_id=str(uuid.uuid4())
devices=[dict(id=i,name="Fixture phone",tokenHash="fixture",pairedAt=0,product=product,push=dict(token="0"*64,environment="sandbox",enabled=True)) for i,product in [(golem_id,"golem"),(other_id,"chatterbox")]]
(data/"runtime-preferences.plist").write_bytes(plistlib.dumps(dict(companionDevices=json.dumps(devices).encode(),companionEnabled=False,mobilePushConfigured=False,mobilePushEnabled=False)))
env={k:v for k,v in os.environ.items() if not k.startswith(("CHATTERBOX_","GOLEM_"))}
env.update(CHATTERBOX_DATA_DIR=str(data),CHATTERBOX_HOST_DIR=str(root/"host"),CHATTERBOX_AGENT_PORT="0",CHATTERBOX_COMPANION_PORT="0",CHATTERBOX_TEST_TRUST_UI="1",CHATTERBOX_PREFERENCES_SUITE=root.name)
binary=os.environ.get("CHATTERBOX_TEST_DAEMON_BINARY",str(pathlib.Path("../Chatterbox/build/runtime/chatterboxd").resolve()))
log=open(root/"daemon.log","wb");proc=subprocess.Popen([binary],env=env,stdout=log,stderr=log)
class Peer:
 def __init__(self,role):
  self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(5);self.s.connect(str(data/"daemon.sock"));self.f=self.s.makefile("rwb");assert "result" in self.call("hello",dict(role=role))
 def call(self,op,body=None):
  rid=str(uuid.uuid4());self.f.write((json.dumps(dict(version=1,id=rid,operation=op,body=body or {}))+"\n").encode());self.f.flush()
  while True:
   result=json.loads(self.f.readline())
   if result.get("id")==rid:return result
try:
 for _ in range(150):
  if (data/"daemon.sock").exists():break
  if proc.poll() is not None:raise RuntimeError((root/"daemon.log").read_text())
  time.sleep(.05)
 for role in ["agent","golem"]:
  peer=Peer(role)
  for op in ["authorizePush","pushStatus","testPush","setGolemPushEnabled"]:assert peer.call(op).get("error")=="permission_denied",(role,op)
 peer=Peer("golem-ui")
 status=peer.call("pushStatus")["result"];assert status["configured"] is False and status["enabled"] is False
 assert peer.call("pushStatus",dict(product="chatterbox")).get("error")=="permission_denied"
 assert peer.call("testPush",dict(product="chatterbox",deviceID=other_id)).get("error")=="permission_denied"
 assert peer.call("testPush",dict(product="golem",deviceID=other_id)).get("error")=="permission_denied"
 result=peer.call("testPush",dict(product="golem",deviceID=golem_id));assert "disabled" in result.get("error",""),result
 assert "No delivery" in peer.call("pushStatus")["result"]["status"]
 assert peer.call("pushStatus")["result"]["optedIn"] is False
 assert "result" in peer.call("setGolemPushEnabled",dict(enabled=True))
 assert peer.call("pushStatus")["result"]["optedIn"] is True
 stored=plistlib.loads((data/"runtime-preferences.plist").read_bytes())
 assert stored["golemPushEnabled"] is True and stored["mobilePushEnabled"] is False
 assert "result" in peer.call("setGolemPushEnabled",dict(enabled=False))
 print("PASS signed Golem status, agent authorization denial, product/device isolation, disabled sender without key access")
 print("Evidence:",root)
finally:
 proc.terminate();proc.wait(timeout=10);log.close()
