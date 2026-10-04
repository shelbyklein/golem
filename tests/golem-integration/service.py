#!/usr/bin/env python3
import json, os, socket, subprocess, tempfile, time, uuid
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='golem-service.',dir='/tmp'))
env=dict(os.environ,CHATTERBOX_DATA_DIR=str(root/'data'),CHATTERBOX_HOST_DIR=str(root/'host'),
    CHATTERBOX_AGENT_PORT='0',CHATTERBOX_COMPANION_PORT='0',CHATTERBOX_TEST_DISABLE_COMPUTER='1',
    CHATTERBOX_HOST_NOTIFY='0',CHATTERBOX_HOST_IDLE_SECONDS='1',CHATTERBOX_HOST_DETACHED_IDLE_SECONDS='1',
    CHATTERBOX_HOST_BINARY=str(Path('build/GolemPlan/Build/Products/Debug/Chatterbox.app/Contents/MacOS/ChatterboxHost').resolve()),
    FAKE_PROVIDER=str(Path('tests/golem-integration/fake-provider.py').resolve()),GOLEM_TEST_JOB='fixture-checkin',CHATTERBOX_TEST_TRUST_UI='1',CHATTERBOX_PREFERENCES_SUITE='com.shelbyklein.golem.service-fixture.'+root.name)
class Control:
    def __init__(self):
        self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(5)
        self.s.connect(str(root/'data/golem.sock'));self.f=self.s.makefile('rwb')
        assert 'result' in self.call('hello',{'role':'ui'})
    def call(self,op,body=None,key=None):
        key=key or str(uuid.uuid4())
        self.f.write((json.dumps(dict(version=1,id=key,operation=op,body=body or {}))+'\n').encode());self.f.flush()
        return json.loads(self.f.readline())
    def close(self):self.f.close();self.s.close()
def launch(binary,name):return subprocess.Popen([binary],env=env,stdout=open(root/(name+'.log'),'wb'),stderr=subprocess.STDOUT)
def wait(predicate):
    for _ in range(200):
        try:
            if predicate():return
        except (FileNotFoundError,json.JSONDecodeError):pass
        time.sleep(.05)
    raise AssertionError('Timed out; artifacts '+str(root))
def chats():return [json.loads(f.read_text()) for f in (root/'data/Conversations').glob('*.json')]
def completed():return any(any(i['kind']=='assistant' for i in c['items']) for c in chats())
daemon=launch('build/runtime/chatterboxd','daemon');golem=None
try:
    wait(lambda:(root/'data/daemon.sock').exists())
    golem=launch('build/runtime/golemd','golem');wait(completed)
    wait(lambda:(root/'data/Dot/journal.json').exists())
    records=chats();count=sum(len(c['items']) for c in records)
    golem.terminate();golem.wait(timeout=8)
    golem=launch('build/runtime/golemd','restart');time.sleep(2)
    assert sum(len(c['items']) for c in chats())==count,'duplicate job after restart'
    journal=json.loads((root/'data/Dot/journal.json').read_text())
    assert len([e for e in journal if e['title']=='Headless fixture'])==1
    control=Control()
    invalid=control.call('settings',{'dotCheckInTimes':[480],'dotEmailModel':False})
    assert 'error' in invalid and not (root/'data/Dot/service-preferences.plist').exists(),'partial settings update'
    key=str(uuid.uuid4());first=control.call('pause',{'paused':True},key)
    assert control.call('pause',{'paused':True},key)==first,'receipt retry changed result'
    assert 'error' in control.call('pause',{'paused':False},key),'request identity conflict accepted'
    assert control.call('health')['result']['paused']
    assert 'result' in control.call('stop');control.close();golem.wait(timeout=8);assert golem.returncode==0;golem=None
    golem=launch('build/runtime/golemd','stopped-restart');wait(lambda:(root/'data/golem.sock').exists())
    control=Control();assert control.call('health')['result']['paused'],'stop did not persist pause'
    assert control.call('pause',{'paused':True},key)==first,'receipt lost on restart'
    control.close();time.sleep(.5)
    assert sum(len(c['items']) for c in chats())==count,'paused service submitted work'
    golem.terminate();golem.wait(timeout=8);golem=None
    print('PASS headless check-in, journal/restart dedupe, atomic settings rejection, durable control receipts, successful stop and persisted pause')
    print('Service artifacts:',root)
finally:
    if golem and golem.poll() is None:golem.terminate();golem.wait(timeout=8)
    daemon.terminate();daemon.wait(timeout=8)
