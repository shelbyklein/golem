import json, plistlib, subprocess, tempfile, hashlib
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='golem-migration.',dir='/tmp'))
for name in ['data/Conversations','data/Attachments','assistant/Avatar','host','memory']:(root/name).mkdir(parents=True,exist_ok=True)
chat={'id':'fixture-chat','draft':'unsent','approval':'pending','offset':92}
(root/'data/Conversations/chat.json').write_text(json.dumps(chat));(root/'data/Attachments/file.bin').write_bytes(b'fixture')
(root/'assistant/journal.json').write_text('[]');(root/'host/offset.json').write_text('{"offset":92}');(root/'memory/MEMORY.md').write_text('unchanged fixture memory')
(root/'prefs.plist').write_bytes(plistlib.dumps({'dotEmailWatch':False,'defaultModel':'fixture','companionDevices':b'paired','windowGeometry':'excluded'}))
args=['python3','scripts/golem-adoption.py','adopt','--data',str(root/'data'),'--assistant',str(root/'assistant'),'--host',str(root/'host'),'--memory',str(root/'memory'),'--preferences',str(root/'prefs.plist'),'--backup',str(root/'backup'),'--quiesced']
subprocess.run(args,check=True);subprocess.run(args,check=True)
assert (root/'data/Conversations/chat.json').read_text()==json.dumps(chat)
assert plistlib.loads((root/'data/runtime-preferences.plist').read_bytes())['companionDevices']==b'paired'
assert 'windowGeometry' not in plistlib.loads((root/'data/runtime-preferences.plist').read_bytes())
(root/'data/Conversations/new.json').write_text('{"new":true}')
args[2]='restore';subprocess.run(args,check=True)
assert not (root/'data/runtime-owner.json').exists()
assert (root/'backup/post-adoption-recovery/data/Conversations/new.json').exists()
assert (root/'memory/MEMORY.md').read_text()=='unchanged fixture memory'
print('PASS offline adoption retry, allowlisted preferences, pairing/draft/approval/offset identity, verified restore and additive recovery export')
print('Migration artifacts:',root)
