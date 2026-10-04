import http.server,json,os
from pathlib import Path
RIG=Path(__file__).resolve().parents[2]/"Golem/rig"
G='11111111-1111-1111-1111-111111111111';C='33333333-3333-3333-3333-333333333333'
def summary(id,title,dot):return dict(id=id,title=title,subtitle='Fixture',backend='claude',isRunning=False,isWaitingOnYou=False,updatedAt='2026-10-04T00:00:00Z',isDot=dot)
paused=False
offline=False
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def reply(self,x):
  b=json.dumps(x).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
 def do_POST(self):
  global paused,offline
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or b'{}')
  if self.path=='/test/offline':offline=body['offline'];return self.reply({'ok':True})
  if self.path=='/v1/golem/control':
   if body.get('operation')=='pause':paused=body.get('body',{}).get('paused',False)
   return self.reply({'ok':True})
  if self.path=='/v1/pair':return self.reply(dict(token='isolated-fixture',macName='Fixture Mac',addresses=['127.0.0.1']))
  return self.reply({'ok':True})
 def do_GET(self):
  if offline and not self.path.startswith('/test/'):return self.send_error(503)
  golem=self.headers.get('X-Chatterbox-Product')=='golem'
  if self.path=='/v1/chats':return self.reply({'revision':1,'groups':[dict(id='dot' if golem else 'chats',kind='dot' if golem else 'chats',title='Golem' if golem else 'Chats',chats=[summary(G,'Golem',True) if golem else summary(C,'Ordinary fixture',False)])]})
  if self.path=='/v1/avatar':return self.reply({'files':[{'name':f.name,'bytes':f.stat().st_size,'modified':'2026-10-04T00:00:00Z'} for f in RIG.iterdir() if f.is_file()]})
  if self.path.startswith('/v1/avatar/'):
   f=RIG/self.path.split('/')[-1]
   if not f.is_file():return self.send_error(404)
   b=f.read_bytes();self.send_response(200);self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b);return
  if self.path=='/v1/golem/health':return self.reply({'paused':paused,'preferences':{'dotCheckIns':True,'dotWatchWaiting':True,'dotSummarizeFinished':True,'dotEmailWatch':True}})
  if self.path=='/v1/golem/status':return self.reply({'available':True})
  if self.path=='/v1/addresses':return self.reply({'addresses':['127.0.0.1']})
  if self.path=='/v1/golem/journal':return self.reply([dict(id='55555555-5555-5555-5555-555555555555',date='2026-10-04T00:00:00Z',kind='activity',title='Fixture journal entry',detail='A headless check-in persisted once.',chat=C)])
  if self.path.startswith('/v1/chats/'):
   if '?since=1' in self.path:return self.reply({'unchanged':True,'revision':1})
   id=self.path.split('/')[3].split('?')[0];dot=id==G
   return self.reply(dict(revision=1,summary=summary(id,'Golem' if dot else 'Ordinary fixture',dot),settings='Claude · Default',items=[dict(id='44444444-4444-4444-4444-444444444444',kind='assistant',text='Fixture briefing' if dot else 'Fixture ordinary reply',isStreaming=False,isCommentary=False,isPending=False,attachments=[],isQueued=False)],earlierCount=0))
  self.send_error(404)
http.server.ThreadingHTTPServer(('127.0.0.1',47411),Handler).serve_forever()
