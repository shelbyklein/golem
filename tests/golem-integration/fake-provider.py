#!/usr/bin/env python3
"""Deterministic stdio provider fixture. No accounts, files or network access."""
import json,sys,uuid
if 'exec' in sys.argv:
 from pathlib import Path
 output=sys.argv[sys.argv.index('-o')+1]
 Path(output).write_text(json.dumps({'status':'ok','accountsChecked':['fixture@example.invalid'],'error':'','emails':[{'account':'fixture@example.invalid','from':'Fixture Sender','subject':'Fixture appointment','why':'A fixture needs a decision.','action':'Review the appointment.','link':'','id':'fixture-mail-1'}]}))
 sys.exit(0)
codex='app-server' in sys.argv
thread='fixture-thread';turn='fixture-turn';pending=None

def emit(obj):print(json.dumps(obj),flush=True)
def result():
 if codex:
  emit({'method':'item/started','params':{'threadId':thread,'item':{'id':str(uuid.uuid4()),'type':'agentMessage','text':'Fixture reply.'}}})
  emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':'completed'}}})
 else:
  emit({'type':'assistant','uuid':str(uuid.uuid4()),'message':{'id':str(uuid.uuid4()),'content':[{'type':'text','text':'Fixture reply.'}]}})
  emit({'type':'result','subtype':'success','is_error':False,'result':'Fixture reply.'})
if not codex:emit({'type':'system','subtype':'init','session_id':'fixture-session','slash_commands':[]})
for line in sys.stdin:
 try:m=json.loads(line)
 except ValueError:continue
 if codex:
  op=m.get('method');rid=m.get('id');p=m.get('params',{})
  if op in ('thread/start','thread/resume','thread/fork'):emit({'id':rid,'result':{'thread':{'id':thread}}})
  elif op=='model/list':emit({'id':rid,'result':{'data':[],'nextCursor':None}})
  elif op=='turn/start':
   turn='turn-'+str(uuid.uuid4());emit({'id':rid,'result':{'turn':{'id':turn}}})
   text=' '.join(x.get('text','') for x in p.get('input',[]))
   if text.endswith('question'):
    pending=True;emit({'id':'fixture-question','method':'item/tool/requestUserInput','params':{'threadId':thread,'questions':[{'id':'q','header':'Choice','question':'Pick one','options':[{'label':'A','description':'A'}]}]}})
   elif text.endswith('approval'):
    pending=True;emit({'id':'fixture-approval','method':'item/commandExecution/requestApproval','params':{'threadId':thread,'command':'true','reason':'Fixture approval'}})
   elif text.endswith('hold'):pending=True
   else:result()
  elif op=='turn/interrupt':emit({'id':rid,'result':{}});emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':'interrupted'}}});pending=None
  elif op=='turn/steer':emit({'id':rid,'result':{'turnId':turn}});result();pending=None
  elif op:emit({'id':rid,'result':{}}) if rid is not None else None
  elif rid is not None and pending:result();pending=None
 else:
  if m.get('type')=='user':
   text=' '.join(x.get('text','') for x in m['message']['content'])
   emit(m)
   if text.endswith('question'):
    pending=True;emit({'type':'control_request','request_id':'fixture-q','request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion','input':{'questions':[{'header':'Choice','question':'Pick one','options':[{'label':'A','description':'A'}],'multiSelect':False}]}}})
   elif text.endswith('approval'):
    pending=True;emit({'type':'control_request','request_id':'fixture-a','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'true'}}})
   elif text.endswith('hold'):pending=True
   else:result();pending=None
  elif m.get('type')=='control_response' and pending:result();pending=None
  elif m.get('type')=='control_request':
   emit({'type':'control_response','response':{'subtype':'success','request_id':m['request_id'],'response':{}}})
   if m['request'].get('subtype')=='interrupt':emit({'type':'result','subtype':'success','is_error':False});pending=None
