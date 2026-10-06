#!/usr/bin/env python3
"""Exercise the real read-only sweep runner with isolated provider responses."""
import json, os, subprocess, tempfile
from pathlib import Path
root = Path(tempfile.mkdtemp(prefix="golem-email-test.", dir="/tmp"))
provider = root / "provider.py"
provider.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
case = os.environ['SWEEP_CASE']
answer = {'status':'ok', 'accountsChecked':['fixture@example.invalid'], 'error':'', 'emails':[]}
if case == 'unavailable': answer.update(status='unavailable', error='fixture access failed')
if case == 'empty-accounts': answer['accountsChecked'] = []
if case == 'old-schema': answer = {'emails':[]}
if case == 'email': answer['emails'] = [{'account':'fixture@example.invalid', 'from':'Fixture', 'subject':'Appointment', 'why':'Decision required', 'action':'Review', 'link':'', 'id':'mail-1'}]
Path(sys.argv[sys.argv.index('-o')+1]).write_text(json.dumps(answer))
sys.exit(7 if case == 'nonzero' else 0)
""")
provider.chmod(0o700)
main = root / "main.swift"
main.write_text(r"""
import Foundation
struct RuntimeFailure: Error { let message:String; init(_ message:String){self.message=message} }
enum RuntimePaths { static var assistantFolder:String { ProcessInfo.processInfo.environment["SWEEP_FOLDER"]! }; static var assistantMemoryFolder:URL {URL(fileURLWithPath:assistantFolder)} }
enum EasyCLIProxy { static let codexHasChatGPTSignIn=true }
enum BinaryLocator { static var environment:[String:String] {ProcessInfo.processInfo.environment} }
@MainActor func checkCatchUp() {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    let h:TimeInterval=3600
    // Fresh cursor: one window up to now.
    let fresh=EmailCatchUp.window(through:now.addingTimeInterval(-600),failures:0,now:now)!
    precondition(fresh.until==now && !fresh.catchingUp, "\(fresh)")
    // 41 h behind: 3 h pieces, catching up, never the old silent 16 h jump.
    let behind=EmailCatchUp.window(through:now.addingTimeInterval(-41*h),failures:0,now:now)!
    precondition(behind.since==now.addingTimeInterval(-41*h) && behind.until==behind.since.addingTimeInterval(3*h) && behind.catchingUp, "\(behind)")
    // Failures halve the window, down to 30 minutes.
    precondition(EmailCatchUp.window(through:now.addingTimeInterval(-41*h),failures:1,now:now)!.until.timeIntervalSince(behind.since)==1.5*h)
    precondition(EmailCatchUp.window(through:now.addingTimeInterval(-41*h),failures:9,now:now)!.until.timeIntervalSince(behind.since)==1800)
    // No cursor yet: the last hour. Nothing new: no window.
    precondition(EmailCatchUp.window(through:nil,failures:0,now:now)!.since==now.addingTimeInterval(-h))
    precondition(EmailCatchUp.window(through:now.addingTimeInterval(-30),failures:0,now:now)==nil)
    // Older than a week: sweep from a week back and report the skipped part.
    let old=now.addingTimeInterval(-10*86400)
    precondition(EmailCatchUp.window(through:old,failures:0,now:now)!.since==now.addingTimeInterval(-7*86400))
    precondition(EmailCatchUp.skipped(through:old,now:now)==now.addingTimeInterval(-7*86400) && EmailCatchUp.skipped(through:now.addingTimeInterval(-41*h),now:now)==nil)
    // One alert after an hour and three failures, never twice.
    let since=now.addingTimeInterval(-61*60)
    precondition(EmailCatchUp.shouldAlert(failingSince:since,failures:3,alerted:false,now:now))
    precondition(!EmailCatchUp.shouldAlert(failingSince:since,failures:2,alerted:false,now:now))
    precondition(!EmailCatchUp.shouldAlert(failingSince:now.addingTimeInterval(-50*60),failures:5,alerted:false,now:now))
    precondition(!EmailCatchUp.shouldAlert(failingSince:since,failures:5,alerted:true,now:now))
    // The query is bounded on both sides.
    let prompt=EmailSweep.prompt(name:"Golem",since:behind.since,until:behind.until)
    precondition(prompt.contains("after:\(Int(behind.since.timeIntervalSince1970)) before:\(Int(behind.until.timeIntervalSince1970)) -in:sent -in:drafts"))
    precondition(EmailCatchUp.looksLikeFixture("/Users/x/Vibes/Chatterbox/tests/golem-integration/fake-provider.py"))
    precondition(EmailCatchUp.looksLikeFixture("/tmp/fake-codex") && !EmailCatchUp.looksLikeFixture("/Users/x/.local/bin/codex") && !EmailCatchUp.looksLikeFixture("/opt/homebrew/bin/codex"))
    print("catchup:ok")
}
Task { @MainActor in
    if ProcessInfo.processInfo.environment["SWEEP_CASE"]=="catchup" { checkCatchUp(); exit(0) }
    let result=await EmailSweep.run(codex:ProcessInfo.processInfo.environment["SWEEP_PROVIDER"]!,model:"fixture",prompt:"Read-only fixture")
    switch result {
    case .success(let emails,let accounts):print("success:\(emails.count):\(accounts.count)")
    case .failure(let reason):print("failure"); fputs(reason + "\n",stderr)
    }
    exit(0)
}
RunLoop.main.run()
""")
binary=root/'test'
subprocess.run(['swiftc','-o',str(binary),'GolemService/EmailSweep.swift',str(main)],check=True)
for case,expected in [('catchup','catchup:ok'),('empty','success:0:1'),('email','success:1:1'),('unavailable','failure'),('empty-accounts','failure'),('old-schema','failure'),('nonzero','failure')]:
    env=dict(os.environ,SWEEP_CASE=case,SWEEP_FOLDER=str(root),SWEEP_PROVIDER=str(provider))
    r=subprocess.run([str(binary)],env=env,capture_output=True,text=True,timeout=20,check=True)
    assert r.stdout.strip()==expected,(case,r.stdout,r.stderr)
    print('PASS',case,expected)
print('Sweep runner artifacts:',root)
