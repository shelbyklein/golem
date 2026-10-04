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
Task { @MainActor in
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
for case,expected in [('empty','success:0:1'),('email','success:1:1'),('unavailable','failure'),('empty-accounts','failure'),('old-schema','failure'),('nonzero','failure')]:
    env=dict(os.environ,SWEEP_CASE=case,SWEEP_FOLDER=str(root),SWEEP_PROVIDER=str(provider))
    r=subprocess.run([str(binary)],env=env,capture_output=True,text=True,timeout=20,check=True)
    assert r.stdout.strip()==expected,(case,r.stdout,r.stderr)
    print('PASS',case,expected)
print('Sweep runner artifacts:',root)
