import pathlib,tempfile,os,subprocess,shutil
root=pathlib.Path(tempfile.mkdtemp(prefix='golem-mini-fit.',dir='/tmp'))
(root/'Dot').mkdir();shutil.copytree(pathlib.Path.home()/'Chatterbox/Dot/Avatar',root/'Dot/Avatar')
products=pathlib.Path('build/GolemPlan/Build/Products/Debug').resolve()
dylib=products/'Golem.app/Contents/MacOS'
subprocess.run(['swiftc','-I',str(products),str(dylib/'Golem.debug.dylib'),'-Xlinker','-rpath','-Xlinker',str(dylib),'-o',str(root/'test'),'tests/mini-fit/main.swift'],check=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('CHATTERBOX_','GOLEM_'))}
env.update(CHATTERBOX_DATA_DIR=str(root),CHATTERBOX_HOST_DIR=str(root/'host'),CHATTERBOX_AGENT_PORT='0',CHATTERBOX_COMPANION_PORT='0',CHATTERBOX_PREFERENCES_SUITE='golem-mini-fit.'+root.name)
subprocess.run([str(root/'test')],env=env,check=True)
print('Proof:',root)
