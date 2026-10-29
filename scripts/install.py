import os
import plistlib
import shutil
from pathlib import Path

root = Path(__file__).resolve().parent.parent
app = Path.home() / 'Applications/Scarlett Mono.app'
app.parent.mkdir(parents=True, exist_ok=True)
staged = app.parent / '.ScarlettMono.installing'
previous = Path.home() / 'Library/Application Support/Scarlett Mono/previous-install'
previous.parent.mkdir(parents=True, exist_ok=True)
if staged.exists():
    shutil.rmtree(staged)
shutil.copytree(root / 'build/Scarlett Mono.app', staged)
if previous.exists():
    shutil.rmtree(previous)
if app.exists():
    app.rename(previous)
staged.rename(app)
logs = Path.home() / 'Library/Logs/Scarlett Mono'
logs.mkdir(parents=True, exist_ok=True)
agent = Path.home() / 'Library/LaunchAgents/com.shanekeulen.ScarlettMono.plist'
agent.parent.mkdir(parents=True, exist_ok=True)
agent.write_bytes(plistlib.dumps({
    'Label': 'com.shanekeulen.ScarlettMono',
    'ProgramArguments': [str(app / 'Contents/MacOS/ScarlettMono')],
    'RunAtLoad': True,
    'KeepAlive': {'SuccessfulExit': False},
    'ThrottleInterval': 10,
    'ProcessType': 'Interactive',
    'LimitLoadToSessionType': 'Aqua',
    'StandardOutPath': str(logs / 'stdout.log'),
    'StandardErrorPath': str(logs / 'stderr.log'),
}))
print(f'Installed {app}')
print(f'Login agent: {agent}')
