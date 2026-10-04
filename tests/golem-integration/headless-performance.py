#!/usr/bin/env python3
import json,os,subprocess,tempfile,time
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='golem-headless-perf.',dir='/tmp'))
env=dict(os.environ,CHATTERBOX_DATA_DIR=str(root/'data'),CHATTERBOX_HOST_DIR=str(root/'host'),CHATTERBOX_PREFERENCES_SUITE='com.shelbyklein.fixture.'+root.name,CHATTERBOX_AGENT_PORT='0',CHATTERBOX_COMPANION_PORT='0',CHATTERBOX_TEST_DISABLE_COMPUTER='1',GOLEM_TEST_DISABLE_AUTOMATION='1')
def cpu(pid):
 value=subprocess.check_output(['ps','-p',str(pid),'-o','time='],text=True).strip()
 return sum(float(x)*60**i for i,x in enumerate(reversed(value.split(':'))))
processes=[subprocess.Popen(['build/runtime/'+name],env=env,stdout=open(root/(name+'.log'),'wb'),stderr=subprocess.STDOUT) for name in ['chatterboxd','golemd']]
try:
 time.sleep(3);samples=[]
 for run in range(1,4):
  before=sum(cpu(p.pid) for p in processes);start=time.monotonic();time.sleep(60);elapsed=time.monotonic()-start
  samples.append(dict(run=run,seconds=elapsed,combined_cpu_percent=(sum(cpu(p.pid) for p in processes)-before)/elapsed*100))
  Path('tests/golem-integration/artifacts/headless-performance.json').write_text(json.dumps(samples,indent=2)+'\n')
 print('PASS three headless CPU samples:',root)
finally:
 for p in processes:p.terminate()
 for p in processes:p.wait(timeout=8)
