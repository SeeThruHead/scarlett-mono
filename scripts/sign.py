import os
import secrets
import shlex
import subprocess
from pathlib import Path

folder = Path.home() / 'Library/Application Support/Scarlett Mono/signing'
folder.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(folder, 0o700)
password_file = folder / 'keychain-password'
keychain = folder / 'signing.keychain-db'
certificate = folder / 'certificate.pem'

def run(*args):
    try:
        result = subprocess.run(args, check=False, timeout=20, stdout=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f'{args[0]} timed out') from None
    if result.returncode != 0:
        raise RuntimeError(f'{args[0]} failed with exit code {result.returncode}')

if not password_file.exists():
    password_file.write_text(secrets.token_urlsafe(32))
    os.chmod(password_file, 0o600)
password = password_file.read_text()
if not certificate.exists():
    config = folder / 'certificate.cnf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=Scarlett Mono Local Signing\n[extensions]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
    run('/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650', '-config', str(config), '-keyout', str(folder / 'private-key.pem'), '-out', str(certificate))
    os.chmod(folder / 'private-key.pem', 0o600)
    run('/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(folder / 'private-key.pem'), '-in', str(certificate), '-out', str(folder / 'identity.p12'), '-passout', f'file:{password_file}')
    os.chmod(folder / 'identity.p12', 0o600)
if not keychain.exists():
    run('security', 'create-keychain', '-p', password, str(keychain))
    run('security', 'import', str(folder / 'identity.p12'), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign')
run('security', 'unlock-keychain', '-p', password, str(keychain))
run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, str(keychain))
fingerprint = subprocess.check_output(['/usr/bin/openssl', 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1'], text=True).strip().split('=')[1].replace(':', '')
original_keychains = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
try:
    run('security', 'list-keychains', '-d', 'user', '-s', *original_keychains, str(keychain))
    run('codesign', '--force', '--sign', fingerprint, '--keychain', str(keychain), '--identifier', 'com.shanekeulen.ScarlettMono', 'build/Scarlett Mono.app')
finally:
    run('security', 'list-keychains', '-d', 'user', '-s', *original_keychains)
run('codesign', '--verify', '--strict', 'build/Scarlett Mono.app')
print('Signed with persistent local certificate')
