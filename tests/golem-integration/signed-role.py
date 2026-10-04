#!/usr/bin/env python3
"""Actual signed Golem identity; no trust override or production data."""
import os,subprocess,tempfile,time
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='golem-signed-role.',dir='/tmp'))
env=dict(os.environ,CHATTERBOX_DATA_DIR=str(root/'data'),CHATTERBOX_HOST_DIR=str(root/'host'),CHATTERBOX_PREFERENCES_SUITE='com.shelbyklein.fixture.'+root.name,CHATTERBOX_AGENT_PORT='0',CHATTERBOX_COMPANION_PORT='0',CHATTERBOX_DAEMON_CLIENT='1',CHATTERBOX_TEST_DISABLE_COMPUTER='1',GOLEM_TEST_ROLE_CHECK='1')
env.pop('CHATTERBOX_TEST_TRUST_UI',None)
log=open(root/'daemon.log','wb');daemon=subprocess.Popen(['build/runtime/chatterboxd'],env=env,stdout=log,stderr=log)
try:
 for _ in range(100):
  if (root/'data/daemon.sock').exists():break
  time.sleep(.05)
 with open(root/'app.log','w') as output:
  app=subprocess.run(['build/GolemPlan/Build/Products/Debug/Golem.app/Contents/MacOS/Golem','-ApplePersistenceIgnoreState','YES'],env=env,stdout=output,stderr=subprocess.STDOUT,timeout=25)
 text=(root/'app.log').read_text();print(text);print((root/'daemon.log').read_text())
 assert app.returncode==0 and 'PASS signed Golem' in text
 print('Signed role artifacts:',root)
finally:daemon.terminate();daemon.wait(timeout=8)
