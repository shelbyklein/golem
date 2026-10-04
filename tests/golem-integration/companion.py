#!/usr/bin/env python3
import json, os, socket, subprocess, tempfile, time, urllib.request
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='golem-companion.',dir='/tmp'))
s=socket.socket();s.bind(('127.0.0.1',0));port=s.getsockname()[1];s.close()
s=socket.socket();s.bind(('127.0.0.1',0));mobile_port=s.getsockname()[1];s.close()
env=dict(os.environ,CHATTERBOX_DATA_DIR=str(root/'data'),CHATTERBOX_HOST_DIR=str(root/'host'),
    CHATTERBOX_AGENT_PORT=str(port),CHATTERBOX_COMPANION_PORT=str(mobile_port),CHATTERBOX_TEST_TRUST_UI='1',CHATTERBOX_TEST_DISABLE_COMPUTER='1',
    CHATTERBOX_HOST_BINARY=str(Path('build/GolemPlan/Build/Products/Debug/Chatterbox.app/Contents/MacOS/ChatterboxHost').resolve()),
    CHATTERBOX_HOST_NOTIFY='0',CHATTERBOX_HOST_IDLE_SECONDS='1',CHATTERBOX_HOST_DETACHED_IDLE_SECONDS='1',
    FAKE_PROVIDER=str(Path('tests/golem-integration/fake-provider.py').resolve()))
p=subprocess.Popen(['build/runtime/chatterboxd'],env=env,stdout=open(root/'daemon.log','wb'),stderr=subprocess.STDOUT)
def call(path,body=None):
    token=(root/'data/agent-token').read_text()
    req=urllib.request.Request('http://127.0.0.1:'+str(port)+path,data=None if body is None else json.dumps(body).encode(),headers={'X-Chatterbox-Token':token,'Content-Type':'application/json'})
    return json.load(urllib.request.urlopen(req,timeout=8))
try:
    for _ in range(100):
        try: listing=call('/v1/chats');break
        except (OSError,FileNotFoundError):time.sleep(.05)
    else:raise AssertionError('agent adapter unavailable')
    detail=call('/v1/chats',{'backend':'claude'});chat=detail['summary']['id']
    call('/v1/chats/'+chat+'/messages',{'text':'hello'})
    for _ in range(100):
        detail=call('/v1/chats/'+chat)
        if any(i.get('kind')=='assistant' for i in detail['items']):break
        time.sleep(.05)
    else:raise AssertionError('reply missing')
    listing=call('/v1/chats');assert listing['groups']
    mcp=Path('build/GolemPlan/Build/Products/Debug/Chatterbox.app/Contents/MacOS/chatterbox-mcp')
    request={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'list_chats','arguments':{}}}
    result=subprocess.run([str(mcp)],input=json.dumps(request)+'\n',capture_output=True,text=True,env=env,timeout=10)
    assert result.returncode==0 and chat.lower() in result.stdout.lower(),result.stdout
    # Signed UI fixture configures the daemon-hosted mobile gateway.
    peer=socket.socket(socket.AF_UNIX);peer.connect(str(root/'data/daemon.sock'));wire=peer.makefile('rwb')
    def rpc(op,body):
        key=str(time.time_ns());wire.write((json.dumps(dict(version=1,id=key,operation=op,body=body))+'\n').encode());wire.flush()
        while True:
            reply=json.loads(wire.readline())
            if reply.get('id')==key:return reply['result']
    rpc('hello',{'role':'ui'});rpc('companion',{'enabled':True});assistant=rpc('ensureAssistant',{})
    status=rpc('companionStatus',{})
    def mobile(path,body=None,token=None,product='chatterbox'):
        headers={'Content-Type':'application/json','X-Chatterbox-Product':product}
        if token:headers['X-Chatterbox-Token']=token
        req=urllib.request.Request('http://127.0.0.1:'+str(mobile_port)+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
        return json.load(urllib.request.urlopen(req,timeout=8))
    time.sleep(.2)
    ctoken=mobile('/v1/pair',{'code':status['pairingCode'],'deviceName':'Fixture Chatterbox'})['token']
    gtoken=mobile('/v1/pair',{'code':status['golemPairingCode'],'deviceName':'Fixture Golem','product':'golem'},product='golem')['token']
    assert all(g['kind']!='dot' for g in mobile('/v1/chats',token=ctoken)['groups'])
    assert all(g['kind']=='dot' for g in mobile('/v1/chats',token=gtoken,product='golem')['groups'])
    try:mobile('/v1/chats',token=ctoken,product='golem');raise AssertionError('cross-product token accepted')
    except urllib.error.HTTPError as error:assert error.code==403
    try:mobile('/v1/chats/'+chat,token=gtoken,product='golem');raise AssertionError('Golem read ordinary chat through mobile scope')
    except urllib.error.HTTPError as error:assert error.code==404
    assert isinstance(mobile('/v1/golem/journal',token=gtoken,product='golem'),list)
    rpc('hello',{'role':'golem'})
    rpc('sendAutomatic',{'text':'Read suppression fixture','label':'Fixture'})
    for _ in range(100):
        projected=rpc('get',{'chatID':assistant})
        replies=[item for item in projected['record']['items'] if item['kind']=='assistant']
        if replies and not projected['running']:break
        time.sleep(.05)
    assert replies,'assistant reply missing'
    latest=replies[-1]['id']
    assert mobile('/v1/golem/read',{'itemID':latest},gtoken,'golem')['ok']
    assert rpc('notify',{'itemID':latest,'title':'Fixture','text':'Already read'})['suppressed']
    rpc('hello',{'role':'ui'})
    assert rpc('getPreferences',{})['dotSeenItem']==latest
    print('PASS visible briefing read position suppresses delayed notification')
    service_env=dict(env,GOLEM_TEST_DISABLE_AUTOMATION='1')
    service=subprocess.Popen(['build/runtime/golemd'],env=service_env,stdout=open(root/'service.log','wb'),stderr=subprocess.STDOUT)
    try:
        for _ in range(100):
            if (root/'data/golem.sock').exists():break
            time.sleep(.05)
        assert mobile('/v1/golem/health',token=gtoken,product='golem')['paused']==False
        control={'id':str(__import__('uuid').uuid4()),'operation':'pause','body':{'paused':True}}
        assert mobile('/v1/golem/control',control,gtoken,'golem')['ok']
        assert mobile('/v1/golem/control',control,gtoken,'golem')['ok']
        assert mobile('/v1/golem/health',token=gtoken,product='golem')['paused']
        try:mobile('/v1/golem/control',control,ctoken);raise AssertionError('Chatterbox token controlled Golem')
        except urllib.error.HTTPError as error:assert error.code==403
        mobile('/v1/golem/control',dict(control,id=str(__import__('uuid').uuid4()),operation='stop',body={}),gtoken,'golem')
        service.wait(timeout=8);assert service.returncode==0
        print('PASS authenticated product-scoped mobile service pause/retry/status/stop gateway')
    finally:
        if service.poll() is None:service.terminate();service.wait(timeout=8)
    wire.close();peer.close()
    print('PASS independent Chatterbox/Golem pairing, product-scoped lists/tokens/chats and journal gateway')
    print('PASS daemon-hosted /v1 create/send/read/list and existing MCP list_chats with no UI')
    print('Companion artifacts:',root)
finally:p.terminate();p.wait(timeout=8)
