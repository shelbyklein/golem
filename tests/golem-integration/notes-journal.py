#!/usr/bin/env python3
"""Isolated daemon + golemd: notes captured from Golem's replies, and journal entries filed by
project, studio or chat. The fixture store is seeded; nothing touches live data."""
import copy, hashlib, json, os, plistlib, subprocess, tempfile, time, uuid
from pathlib import Path
root = Path(tempfile.mkdtemp(prefix='golem-notes.', dir='/tmp'))
data = root/'data'; folder = data/'Dot'; convs = data/'Conversations'
for d in (folder, convs): d.mkdir(parents=True)
shape = json.loads(Path(os.environ.get('RECORD_SHAPE','tests/golem-integration/notes/record-shape.json')).read_text())   # key layout only; every value below is replaced
def record(title, items, **extra):
    r = copy.deepcopy(shape)
    for k in ('claudeSessionID','claudeHost','codexHost','githubRepo','savedContext','projectFolder','projectNickname','dotFollowing','turnStartedAt'):
        if k in r: r[k] = None
    r.update(id=str(uuid.uuid4()).upper(), title=title, items=items, tags=[], turnDates=[], backgroundTasks=[],
             updatedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - extra.pop('age', 0))))
    r.update(extra); return r
item_shape = json.loads(Path(os.environ.get('ITEM_SHAPE','tests/golem-integration/notes/item-shape.json')).read_text())
def item(kind, text):
    i = copy.deepcopy(item_shape); i.update(id=str(uuid.uuid4()).upper(), kind=kind, phase='final', text=text); return i
studio_id = str(uuid.uuid4()).upper()
(data/'Studios.json').write_text(json.dumps([{'id': studio_id, 'name': 'Archery Studio', 'folder': str(root/'studio'), 'instructions': '', 'createdAt': shape['createdAt'], 'collapsed': False}]))
project = record('Furnace project chat', [item('user', 'hi')], projectFolder=str(root/'Homelab'))
studio = record('Studio chat', [item('user', 'hi')], studioID=studio_id)
plain = record('Plain chat', [item('user', 'hi')])
old = record('Old chat', [item('user', 'hi')], age=3*86400)
project['items'].append(item('assistant', 'Furnace schedule updated.\nFilters next.'))
job_text = '<app_note>\nChat %s finished. Read it with read_chat and summarize.\nYou may suggest answers but never submit user answers or approve requests.\n</app_note>' % project['id']
golem = record('Golem', [
    item('user', job_text), item('assistant', 'The furnace work finished; filters are due.\nNoted: buy furnace filters'),
    item('user', 'note: dentist'), item('assistant', 'Got it.\n- **Noted:** call the dentist Thursday'),
    item('user', 'delete the filters note'), item('assistant', 'Deleted note: buy furnace filters'),
], isDot=True)
for r in (project, studio, plain, old, golem): (convs/(r['id']+'.json')).write_text(json.dumps(r))
key = hashlib.sha256(job_text.strip().encode()).hexdigest()[:24]
(folder/'service-state.json').write_text(json.dumps(dict(schema=1, paused=False, jobs=[], seen=[], jobChats={key: project['id']})))
(folder/'service-preferences.plist').write_bytes(plistlib.dumps(dict(dotEmailWatch=False, dotCheckIns=False, dotWatchWaiting=False, dotSummarizeFinished=False)))
env = {k: v for k, v in os.environ.items() if not k.startswith(('CHATTERBOX_', 'GOLEM_'))}
env.update(CHATTERBOX_DATA_DIR=str(data), CHATTERBOX_HOST_DIR=str(root/'host'), CHATTERBOX_AGENT_PORT='0', CHATTERBOX_COMPANION_PORT='0',
           CHATTERBOX_TEST_TRUST_UI='1', CHATTERBOX_HOST_NOTIFY='0', CHATTERBOX_PREFERENCES_SUITE='golem.notes.fixture.'+root.name,
           CHATTERBOX_HOST_BINARY=os.environ['CHATTERBOX_TEST_HOST_BINARY'])
def launch(binary, name): return subprocess.Popen([binary], env=env, stdout=open(root/(name+'.log'), 'wb'), stderr=subprocess.STDOUT)
def wait(predicate, what):
    for _ in range(400):
        try:
            if predicate(): return
        except (FileNotFoundError, json.JSONDecodeError): pass
        time.sleep(.05)
    raise AssertionError('Timed out: %s; artifacts %s' % (what, root))
daemon = launch(os.environ['CHATTERBOX_TEST_DAEMON_BINARY'], 'daemon'); service = None
try:
    wait(lambda: (data/'daemon.sock').exists(), 'daemon socket')
    service = launch('build/runtime/golemd', 'service')
    journal = lambda: json.loads((folder/'journal.json').read_text())
    wait(lambda: any(e['kind'] == 'note-deleted' for e in journal()), 'notes captured')
    state = json.loads((folder/'service-state.json').read_text())
    assert [n['text'] for n in state['notes']] == ['call the dentist Thursday'], state['notes']
    md = (folder/'notes.md').read_text()
    assert 'call the dentist Thursday' in md and 'furnace filters' not in md, md
    kinds = [e['kind'] for e in journal() if e['kind'] in ('note', 'note-deleted')]
    assert kinds == ['note', 'note', 'note-deleted'], kinds
    print('PASS Noted:/Deleted note: lines keep the notebook (state, notes.md, journal records)')
    replies = [e for e in journal() if e['title'] == 'Briefing']
    filed = next(e for e in replies if 'furnace work' in (e.get('detail') or ''))
    assert filed['group'] == 'project' and filed['groupName'] == 'Homelab' and filed['chat'].upper() == project['id'] and filed['chatName'] == 'Furnace project chat', filed
    own = next(e for e in replies if 'Got it.' in (e.get('detail') or ''))
    assert own['group'] == 'golem', own
    print('PASS a briefing is filed under the project its automatic turn was about; his own conversation under Golem')
    activity = (folder/'activity.md').read_text()
    assert '· Project Homelab · Furnace project chat [%s] · idle' % project['id'] in activity, activity
    assert 'Last: Furnace schedule updated. Filters next.' in activity and '· Studio Archery Studio · Studio chat' in activity, activity
    assert 'Old chat' not in activity and 'Golem [' not in activity, activity
    print('PASS activity.md lists recent chats with time, home, status and latest reply; skips old chats and Golem')
    service.terminate(); service.wait(timeout=8)
    before = len(journal()); service = launch('build/runtime/golemd', 'restart')
    time.sleep(3)
    assert len(journal()) == before and [n['text'] for n in json.loads((folder/'service-state.json').read_text())['notes']] == ['call the dentist Thursday']
    print('PASS restart neither duplicates notes nor re-reads old replies')
    print('Notes artifacts:', root)
finally:
    if service and service.poll() is None: service.terminate(); service.wait(timeout=8)
    daemon.terminate(); daemon.wait(timeout=8)
