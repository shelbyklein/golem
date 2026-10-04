#!/usr/bin/env python3
"""Actual isolated daemons: failed cursor, missing executable and restart dedupe."""
import json, os, plistlib, socket, subprocess, tempfile, time, uuid
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='golem-email-policy.',dir='/tmp'))
folder=root/'data/Dot';folder.mkdir(parents=True)
provider=root/'provider.py'
fixture=Path('tests/golem-integration/fake-provider.py').resolve()
provider.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if 'exec' not in sys.argv: os.execv(sys.executable,[sys.executable,os.environ['EMAIL_FIXTURE']]+sys.argv[1:])
case=Path(os.environ['EMAIL_CASE_FILE']).read_text().strip()
answer={'status':'ok','accountsChecked':['fixture@example.invalid'],'error':'','emails':[]}
if case=='unavailable': answer.update(status='unavailable',error='test access unavailable')
else: answer['emails']=[{'account':'fixture@example.invalid','from':'Fixture Sender','subject':'Appointment','why':'Needs decision','action':'Review','link':'','id':'stable-mail-id'}]
Path(sys.argv[sys.argv.index('-o')+1]).write_text(json.dumps(answer))
""");provider.chmod(0o700)
casefile=root/'case';casefile.write_text('unavailable')
env={k:v for k,v in os.environ.items() if not k.startswith(('CHATTERBOX_','GOLEM_'))}
env.update(CHATTERBOX_DATA_DIR=str(root/'data'),CHATTERBOX_HOST_DIR=str(root/'host'),CHATTERBOX_AGENT_PORT='0',CHATTERBOX_COMPANION_PORT='0',CHATTERBOX_TEST_TRUST_UI='1',CHATTERBOX_HOST_NOTIFY='0',CHATTERBOX_PREFERENCES_SUITE='golem.email.fixture.'+root.name,CHATTERBOX_HOST_BINARY=os.environ.get('CHATTERBOX_TEST_HOST_BINARY','/Applications/Chatterbox.app/Contents/MacOS/ChatterboxHost'),FAKE_PROVIDER=str(fixture),EMAIL_FIXTURE=str(fixture),EMAIL_CASE_FILE=str(casefile))
(folder/'service-preferences.plist').write_bytes(plistlib.dumps(dict(dotEmailWatch=True,dotCheckIns=False,dotWatchWaiting=False,dotSummarizeFinished=False,codexPath=str(provider))))
(folder/'service-state.json').write_text(json.dumps(dict(schema=1,paused=False,jobs=[],seen=[],emailThrough='2026-10-04T12:00:00Z')))
def launch(binary,name):return subprocess.Popen([binary],env=env,stdout=open(root/(name+'.log'),'wb'),stderr=subprocess.STDOUT)
def wait(predicate):
 for _ in range(500):
  try:
   if predicate():return
  except (FileNotFoundError,json.JSONDecodeError,ConnectionRefusedError):pass
  time.sleep(.05)
 raise AssertionError('Timed out; artifacts '+str(root))
def state():return json.loads((folder/'service-state.json').read_text())
class Control:
 def __init__(self):
  self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(20);self.s.connect(str(root/'data/golem.sock'));self.f=self.s.makefile('rwb');self.call('hello',{'role':'ui'})
 def call(self,op,body=None):
  key=str(uuid.uuid4());self.f.write((json.dumps(dict(version=1,id=key,operation=op,body=body or {}))+'\n').encode());self.f.flush()
  while True:
   r=json.loads(self.f.readline())
   if r.get('id')==key:
    assert 'error' not in r,r
    return r['result']
 def close(self):self.f.close();self.s.close()
daemon=launch(os.environ['CHATTERBOX_TEST_DAEMON_BINARY'],'daemon');service=None;control=None
try:
 wait(lambda:(root/'data/daemon.sock').exists())
 service=launch('build/runtime/golemd','service')
 wait(lambda:state().get('emailProblem') is not None)
 assert state()['emailThrough']=='2026-10-04T12:00:00Z'
 print('PASS unavailable Gmail preserves successful cursor and exposes emailProblem')
 casefile.write_text('email');control=Control();control.call('sweep')
 wait(lambda:state().get('emailAccounts')==['fixture@example.invalid'])
 wait(lambda:'email:fixture@example.invalid:stable-mail-id' in state()['seen'])
 assert not state().get('emailProblem')
 journal=json.loads((folder/'journal.json').read_text())
 count=sum(e['title']=='Email from Fixture Sender' for e in journal)
 assert count==2,count # one discovery and one durable submitted job
 control.call('sweep');wait(lambda:not control.call('health')['sweeping'])
 assert sum(e['title']=='Email from Fixture Sender' for e in json.loads((folder/'journal.json').read_text()))==count
 print('PASS identical email across overlapping sweeps submitted once')
 control.close();control=None;service.terminate();service.wait(timeout=8)
 prefs=plistlib.loads((folder/'service-preferences.plist').read_bytes());prefs['codexPath']=str(root/'deleted-test-provider');(folder/'service-preferences.plist').write_bytes(plistlib.dumps(prefs))
 previous=state()['emailThrough'];s=state();s.pop('emailAttempt',None);(folder/'service-state.json').write_text(json.dumps(s))
 service=launch('build/runtime/golemd','missing-binary')
 wait(lambda:'cannot start Codex' in (state().get('emailProblem') or ''))
 assert state()['emailThrough']==previous and state().get('emailAttempt')
 assert sum(e['title']=='Email from Fixture Sender' for e in json.loads((folder/'journal.json').read_text()))==count
 print('PASS missing executable is visible, cursor retained, no duplicates after restart')
 print('Email policy artifacts:',root)
finally:
 if control:control.close()
 if service and service.poll() is None:service.terminate();service.wait(timeout=8)
 daemon.terminate();daemon.wait(timeout=8)
