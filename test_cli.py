"""Safe tests: every invocation exits before any server mutation."""
import subprocess
import unittest
from pathlib import Path
SCRIPT = Path(__file__).resolve().parent / 'vps-init.sh'

class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(['bash', str(SCRIPT), *args], capture_output=True, text=True)

    def test_help(self):
        result = self.run_cli('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('--check', result.stdout)

    def test_invalid_inputs_fail_before_mutation(self):
        cases = [
            (['--user'], 'Missing value'),
            (['--ssh-port', '99999'], 'Invalid SSH port'),
            (['--user', 'root'], 'non-root'),
            (['--user', 'deploy'], 'PUBLIC key'),
            (['--disable-root-login'], 'require --user'),
            (['--disable-password-auth', '--ssh-key', 'example'], 'require --user'),
            (['--swap', '0G'], 'Swap size'),
            (['--user', 'deploy', '--ssh-key-url', 'http://example.com/key'], 'HTTPS'),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


class SshRollbackTests(unittest.TestCase):
    def test_invalid_config_restores_original(self):
        import tempfile
        script = SCRIPT.read_text()
        function = script.split('step_harden_ssh() {', 1)[1].split('\nstep_setup_firewall()', 1)[0]
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / 'sshd_config'
            main.write_text('Port 2222\nPermitRootLogin yes\n')
            body = ('step_harden_ssh() {' + function).replace('/etc/ssh/', folder + '/')
            harness = '''set -euo pipefail
DISABLE_ROOT_LOGIN=true
DISABLE_PASSWORD_AUTH=true
log() { :; }
die() { echo "$*" >&2; exit 1; }
sshd() { return 1; }
systemctl() { return 0; }
'''
            result = subprocess.run(['bash', '-c', harness + body + '\nstep_harden_ssh'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(main.read_text(), 'Port 2222\nPermitRootLogin yes\n')
            self.assertIn('restored', result.stderr)

if __name__ == '__main__':
    unittest.main()
