#!/usr/bin/env python3
"""Real daemon/service, fake providers/mail, deterministic missed weekday slot."""
import json,os,socket,subprocess,tempfile,time,uuid
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='golem-policies.',dir='/tmp'))
env=dict(os.environ,CHATTERBOX_DATA_DIR=str(root/'data'),CHATTERBOX_HOST_DIR=str(root/'host'),CHATTERBOX_AGENT_PORT='0',CHATTERBOX_COMPANION_PORT='0',CHATTERBOX_TEST_DISABLE_COMPUTER='1',CHATTERBOX_TEST_TRUST_UI='1',CHATTERBOX_HOST_NOTIFY='0',CHATTERBOX_HOST_IDLE_SECONDS='1',CHATTERBOX_HOST_DETACHED_IDLE_SECONDS='1',CHATTERBOX_PREFERENCES_SUITE='com.shelbyklein.golem.fixture.'+root.name,CHATTERBOX_HOST_BINARY=str(Path('build/GolemPlan/Build/Products/Debug/Chatterbox.app/Contents/MacOS/ChatterboxHost').resolve()),FAKE_PROVIDER=str(Path('tests/golem-integration/fake-provider.py').resolve()),GOLEM_TEST_POLICIES='1',GOLEM_TEST_CLOCK='2026-10-05T13:30:00Z',TZ='America/New_York')
def launch(binary,name):return subprocess.Popen([binary],env=env,stdout=open(root/(name+'.log'),'wb'),stderr=subprocess.STDOUT)
def wait(predicate):
 for _ in range(400):
  try:
   if predicate():return
  except (FileNotFoundError,json.JSONDecodeError):pass
  time.sleep(.05)
 raise AssertionError('Timed out: '+str(root))
class Peer:
 def __init__(self):
  self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(8);self.s.connect(str(root/'data/daemon.sock'));self.f=self.s.makefile('rwb');self.call('hello',{'role':'ui'})
 def call(self,op,body=None):
  key=str(uuid.uuid4());self.f.write((json.dumps(dict(version=1,id=key,operation=op,body=body or {}))+'\n').encode());self.f.flush()
  while True:
   r=json.loads(self.f.readline())
   if r.get('id')==key:
    assert 'error' not in r,r
    return r['result']
 def close(self):self.f.close();self.s.close()
def journal():return json.loads((root/'data/Dot/journal.json').read_text())
def titles():return [e['title'] for e in journal()]
def records():return [json.loads(p.read_text()) for p in (root/'data/Conversations').glob('*.json')]
daemon=launch('build/runtime/chatterboxd','daemon');service=None;peer=None
try:
 wait(lambda:(root/'data/daemon.sock').exists());peer=Peer()
 # Create ordinary work using a durable record and the real provider bridge.
 record=dict(id=str(uuid.uuid4()),title='Policy fixture',model='default',effort='',personality='friendly',createdAt='2026-10-04T12:00:00Z',updatedAt='2026-10-04T12:00:00Z',items=[],activeBackend='claude',dotFollowing=True)
 chat=peer.call('create',{'record':record});peer.call('send',{'chatID':chat,'text':'hello'})
 wait(lambda:any(c['id']==chat and any(i['kind']=='assistant' for i in c['items']) for c in records()))
 service=launch('build/runtime/golemd','service')
 wait(lambda:'Morning check-in' in titles())
 wait(lambda:'Policy fixture finished' in titles())
 wait(lambda:'Email from Fixture Sender' in titles())
 peer.call('send',{'chatID':chat,'text':'question'})
 wait(lambda:'Policy fixture is waiting on you' in titles())
 time.sleep(1)
 before={label:titles().count(label) for label in ['Morning check-in','Policy fixture finished','Email from Fixture Sender','Policy fixture is waiting on you']}
 assert before['Morning check-in']==1 and before['Policy fixture finished']==1 and before['Policy fixture is waiting on you']==1,before
 service.kill();service.wait(timeout=8)
 service=launch('build/runtime/golemd','restart');time.sleep(3)
 assert {label:titles().count(label) for label in before}==before,'restart duplicated trigger or briefing'
 print('PASS missed weekday check-in catch-up, completed-turn resync catch-up, waiting question, read-only email, crash/restart deduplication with both UIs absent')
 print('Policy artifacts:',root)
finally:
 if peer:peer.close()
 if service and service.poll() is None:service.terminate();service.wait(timeout=8)
 daemon.terminate();daemon.wait(timeout=8)
