#!/usr/bin/env python3
"""Temporary per-user labels; never install/modify live application agents."""
import json,os,plistlib,socket,subprocess,tempfile,time,uuid
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='golem-launchagents.',dir='/tmp'));data=root/'data';data.mkdir()
domain='gui/'+str(os.getuid());labels=[]
env={'CHATTERBOX_DATA_DIR':str(data),'CHATTERBOX_HOST_DIR':str(root/'host'),'CHATTERBOX_PREFERENCES_SUITE':'com.shelbyklein.fixture.'+root.name,'CHATTERBOX_TEST_TRUST_UI':'1','CHATTERBOX_TEST_DISABLE_COMPUTER':'1','CHATTERBOX_AGENT_PORT':'0','CHATTERBOX_COMPANION_PORT':'0','GOLEM_TEST_DISABLE_AUTOMATION':'1'}
def run(*args,check=True):return subprocess.run(['/bin/launchctl',*args],check=check,capture_output=True,text=True)
def wait(predicate):
 for _ in range(200):
  try:
   if predicate():return
  except (OSError,ValueError,json.JSONDecodeError):pass
  time.sleep(.1)
 raise AssertionError('Timed out: '+str(root))
def pid(label):
 value=run('print',domain+'/'+label,check=False).stdout
 for line in value.splitlines():
  if line.strip().startswith('pid = '):return int(line.strip().split(' = ')[1])
 return None
def control(op,body={}):
 s=socket.socket(socket.AF_UNIX);s.settimeout(5);s.connect(str(data/'golem.sock'));f=s.makefile('rwb')
 for operation,payload in [('hello',{'role':'ui'}),(op,body)]:
  f.write((json.dumps(dict(version=1,id=str(uuid.uuid4()),operation=operation,body=payload))+'\n').encode());f.flush();reply=json.loads(f.readline());assert 'error' not in reply,reply
 f.close();s.close();return reply['result']
try:
 for name in ['chatterboxd','golemd']:
  label='com.shelbyklein.fixture.'+root.name+'.'+name;labels.append(label)
  plist=root/(name+'.plist')
  plist.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':[str(Path('build/runtime/'+name).resolve())],'EnvironmentVariables':env,'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':1,'StandardOutPath':str(root/(name+'.log')),'StandardErrorPath':str(root/(name+'.log'))}))
  run('bootstrap',domain,str(plist));wait(lambda:pid(label))
 wait(lambda:(data/'daemon.sock').exists() and (data/'golem.sock').exists())
 for label in labels:
  previous=pid(label);run('kill','SIGKILL',domain+'/'+label)
  wait(lambda:pid(label) is not None and pid(label)!=previous)
  time.sleep(.3);assert pid(label) is not None
 wait(lambda:control('health') is not None)
 control('stop');wait(lambda:pid(labels[1]) is None)
 time.sleep(2);assert pid(labels[1]) is None,'successful stop restarted'
 run('kickstart',domain+'/'+labels[1]);wait(lambda:pid(labels[1]) is not None)
 wait(lambda:control('health')['paused'])
 print('PASS isolated LaunchAgents: daemon/service crash recovery, successful service stop remains stopped, explicit restart retains pause')
 print('LaunchAgent artifacts:',root)
finally:
 for label in reversed(labels):run('bootout',domain+'/'+label,check=False)
