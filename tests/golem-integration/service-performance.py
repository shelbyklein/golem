#!/usr/bin/env python3
"""Concurrent service CPU totals, conservatively added to native app samples."""
import json, subprocess, sys, time
from pathlib import Path
pids=sys.argv[1:3];output=Path(sys.argv[3])
def cpu():
    total=0
    for pid in pids:
        value=subprocess.check_output(['ps','-p',pid,'-o','time='],text=True).strip()
        total+=sum(float(x)*60**i for i,x in enumerate(reversed(value.split(':'))))
    return total
samples=[]
time.sleep(4)
for run in range(1,7):
    before=cpu();start=time.monotonic();time.sleep(60);elapsed=time.monotonic()-start
    samples.append(dict(run=run,seconds=elapsed,service_cpu_percent=(cpu()-before)/elapsed*100))
    output.write_text(json.dumps(samples,indent=2)+'\n')
