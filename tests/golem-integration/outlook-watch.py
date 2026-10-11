#!/usr/bin/env python3
"""Isolated daemon + golemd with a fake Codex: the Outlook watcher's baseline, one new message
read and journaled with its action item and link, no repeat, failures that never look like an
empty inbox, and scratch folders removed after runs (including one killed mid-run)."""
import json, os, plistlib, signal, socket, subprocess, tempfile, time, uuid
from pathlib import Path
root = Path(tempfile.mkdtemp(prefix='golem-outlook-test.', dir='/tmp'))
folder = root/'data/Dot'; folder.mkdir(parents=True)
scratchbase = root/'data/OutlookScratch'
casefile = root/'case'; casefile.write_text('baseline')
provider = root/'provider.py'
provider.write_text("""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
if 'exec' not in sys.argv: os.execv(sys.executable,[sys.executable,os.environ['OUTLOOK_FIXTURE']]+sys.argv[1:])
root=Path(os.environ['OUTLOOK_ROOT']); case=(root/'case').read_text().strip()
out=Path(sys.argv[sys.argv.index('-o')+1]); prompt=sys.argv[-1]
(root/'scratch.log').open('a').write(str(out.parent)+'\\n')
(root/'prompts.log').open('a').write(prompt+'\\n=====\\n')
(root/'pid').write_text(str(os.getpid()))
if 'Outlook watcher' not in prompt:
    out.write_text(json.dumps({'status':'ok','accountsChecked':['f@example.invalid'],'error':'','emails':[]})); sys.exit(0)
answer={'status':'ok','error':'','account':'me@example.org','inboxIDs':['m3','m2','m1'],'processed':[]}
if case=='new' or case=='again':
    answer['inboxIDs']=['m4','m3','m2']
    answer['processed']=[{'id':'m4','link':'https://outlook.cloud.microsoft/mail/inbox/id/m4','from':'Pat','subject':'Budget form','received':'Fri 9:00',
      'summary':'Pat needs the budget form.','actions':['Send the budget form to Pat'],'deadlines':['Friday 5pm'],'links':['https://forms.example.org/budget'],'important':True,'unreadRestored':True}]
elif case=='unavailable': answer.update(status='unavailable',error='Chrome extension not connected',inboxIDs=[])
elif case=='empty': answer.update(inboxIDs=[])
elif case=='hang': time.sleep(120)
out.write_text(json.dumps(answer))
""")
provider.chmod(0o700)
env = {k: v for k, v in os.environ.items() if not k.startswith(('CHATTERBOX_', 'GOLEM_'))}
env.update(CHATTERBOX_DATA_DIR=str(root/'data'), CHATTERBOX_HOST_DIR=str(root/'host'), CHATTERBOX_AGENT_PORT='0', CHATTERBOX_COMPANION_PORT='0',
           CHATTERBOX_TEST_TRUST_UI='1', CHATTERBOX_HOST_NOTIFY='0', CHATTERBOX_PREFERENCES_SUITE='golem.outlook.fixture.'+root.name,
           CHATTERBOX_HOST_BINARY=os.environ['CHATTERBOX_TEST_HOST_BINARY'],
           OUTLOOK_ROOT=str(root), OUTLOOK_FIXTURE=str(Path('tests/golem-integration/fake-provider.py').resolve()))
(folder/'service-preferences.plist').write_bytes(plistlib.dumps(dict(dotEmailWatch=False, dotOutlookWatch=True, dotCheckIns=False, dotWatchWaiting=False, dotSummarizeFinished=False, codexPath=str(provider))))
(folder/'service-state.json').write_text(json.dumps(dict(schema=1, paused=False, jobs=[], seen=[])))
def launch(binary, name): return subprocess.Popen([binary], env=env, stdout=open(root/(name+'.log'), 'wb'), stderr=subprocess.STDOUT)
def wait(predicate, what, seconds=25):
    end = time.time()+seconds
    while time.time() < end:
        try:
            if predicate(): return
        except (FileNotFoundError, json.JSONDecodeError, ConnectionRefusedError, KeyError): pass
        time.sleep(.05)
    raise AssertionError('Timed out: %s; artifacts %s' % (what, root))
def state(): return json.loads((folder/'service-state.json').read_text())
def journal(): return json.loads((folder/'journal.json').read_text())
def scratch(): return [p for p in scratchbase.iterdir() if p.name.startswith('golem-outlook-')] if scratchbase.exists() else []
class Control:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(20); self.s.connect(str(root/'data/golem.sock')); self.f = self.s.makefile('rwb'); self.call('hello', {'role': 'ui'})
    def call(self, op, body=None):
        key = str(uuid.uuid4()); self.f.write((json.dumps(dict(version=1, id=key, operation=op, body=body or {}))+'\n').encode()); self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if r.get('id') == key:
                assert 'error' not in r, r
                return r['result']
    def close(self): self.f.close(); self.s.close()
def run(case, done, what):
    casefile.write_text(case); control.call('sweep')
    wait(lambda: not control.call('health')['sweeping'] and done(), what)
daemon = launch(os.environ['CHATTERBOX_TEST_DAEMON_BINARY'], 'daemon'); service = None; control = None
try:
    wait(lambda: (root/'data/daemon.sock').exists(), 'daemon')
    service = launch('build/runtime/golemd', 'service')
    wait(lambda: state().get('outlookKnown') == ['m1', 'm2', 'm3'], 'baseline recorded')
    assert not any(e['title'].startswith('Outlook:') for e in journal()), 'the first run opened mail'
    assert any(e['title'] == 'Watching Outlook' for e in journal())
    wait(lambda: not scratch(), 'baseline scratch removed')
    print('PASS first run records the current inbox as seen and opens nothing')
    control = Control()
    assert control.call('health')['preferences']['dotOutlookWatch'] is True
    run('new', lambda: 'm4' in state().get('outlookKnown', []), 'new message read')
    entry = next(e for e in journal() if e['title'] == 'Outlook: Budget form')
    assert 'For you: Send the budget form to Pat' in entry['detail'] and 'Open in Outlook: https://outlook.cloud.microsoft/mail/inbox/id/m4' in entry['detail'] and 'Friday 5pm' in entry['detail'], entry
    outlook_prompts = [x for x in (root/'prompts.log').read_text().split('=====') if 'Outlook watcher' in x]
    assert '- m3' in outlook_prompts[-1] and 'Already read' in outlook_prompts[-1], 'known ids were not passed to the sweep'
    logged = [p for p in (root/'scratch.log').read_text().split() if 'golem-outlook-' in Path(p).name]  # the Gmail sweep's own folder is logged too
    assert logged and all(p.startswith(str(scratchbase)) and not Path(p).exists() for p in logged) and not scratch(), logged
    print('PASS a new message is journaled with its action item, deadline and link; the scratch folder is gone')
    count = sum(e['title'] == 'Outlook: Budget form' for e in journal())
    run('again', lambda: True, 'second run')
    assert sum(e['title'] == 'Outlook: Budget form' for e in journal()) == count
    print('PASS the same message is not processed again')
    known = state()['outlookKnown']; before = len(journal())
    run('unavailable', lambda: state().get('outlookProblem'), 'unavailable recorded')
    assert 'Chrome extension not connected' in state()['outlookProblem'] and state()['problem'] == state()['outlookProblem'] and state()['outlookKnown'] == known
    assert not any(e['title'].startswith('Outlook:') for e in journal()[before:])
    run('empty', lambda: (state().get('outlookFailures') or 0) >= 2, 'empty inbox counted as failure')
    assert 'came back empty' in state()['outlookProblem'] and state()['outlookKnown'] == known
    print('PASS failures (unreachable, empty inbox) are problems, never "no new mail", and remember nothing')
    run('new', lambda: state().get('outlookProblem') is None and not state().get('outlookFailures'), 'recovered')
    print('PASS a good run clears the problem')
    control.close(); control = None
    service.terminate(); service.wait(timeout=8)
    casefile.write_text('hang'); s = state(); s['outlookAttempt'] = None; (folder/'service-state.json').write_text(json.dumps(s))
    service = launch('build/runtime/golemd', 'hang')
    wait(lambda: scratch(), 'hung run started')
    service.kill(); service.wait(timeout=8)
    try: os.kill(int((root/'pid').read_text()), signal.SIGKILL)
    except (ProcessLookupError, ValueError, FileNotFoundError): pass
    assert scratch(), 'a killed run should leave its folder behind for this check'
    casefile.write_text('again'); service = launch('build/runtime/golemd', 'restart')
    leftover = scratch()[0]
    wait(lambda: not leftover.exists(), 'leftover removed at start', 15)
    print('PASS a run killed midway leaves nothing behind once the service restarts')
    print('Artifacts:', root)
finally:
    if control: control.close()
    if service and service.poll() is None: service.terminate(); service.wait(timeout=8)
    daemon.terminate(); daemon.wait(timeout=8)
