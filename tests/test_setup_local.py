"""Exercise the streamed installer; Docker/network operations are test doubles.

Real OpenSSL and filesystem operations verify generated secrets and rerun safety.
Run with: python3 -m unittest discover -s tests
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


INSTALLER = (Path(__file__).resolve().parents[1] / "setup-local.sh").read_text()
ENV_KEYS = ("JWT_SECRET", "COLLABORATION_SERVICE_SECRET", "CURSOR_SECRET", "AI_SERVICE_TOKEN")
PASSWORD_FILES = (
    "db_admin_password.txt", "db_runtime_password.txt", "db_migrator_password.txt",
    "db_provisioner_password.txt", "redis_limit_secret.txt",
    "redis_invitation_binding_secret.txt", "csrf_secret.txt", "minio_root_password.txt",
)


class LocalSetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.install = self.root / "synodus"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        SETUP_TEST_LOG=str(self.root / "commands.jsonl"),
                        SETUP_TEST_CONFIG=str(Path(__file__).resolve().parents[1]))
        self.write_tool("git", "#!/bin/sh\nexit 99\n")
        self.write_tool("docker", '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['SETUP_TEST_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['compose', 'up', '--help']:
    print('--wait-timeout')
if os.environ.get('SETUP_TEST_FAIL') and sys.argv[-3:] == ['postgres', 'redis', 'minio']:
    sys.exit(9)
''')
        self.write_tool("curl", '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
url = next((arg for arg in sys.argv if arg.startswith('https://raw.githubusercontent.com/')), '')
if url:
    relative = url.split('/infra/main/', 1)[1]
    target = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
    shutil.copyfile(pathlib.Path(os.environ['SETUP_TEST_CONFIG']) / relative, target)
elif '-w' in sys.argv:
    print('401', end='')
''')

    def write_tool(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_installer(self, success=True):
        result = subprocess.run(["bash"], input=INSTALLER, text=True,
                                cwd=self.root, env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0 if success else 9, result.stderr)
        return result

    def env_values(self):
        return dict(line.split("=", 1) for line in (self.install / ".env").read_text().splitlines()
                    if line and not line.startswith("#"))

    def test_fresh_install_generates_unique_credentials_and_shared_storage_keys(self):
        result = self.run_installer()
        secrets = self.install / "secrets"
        values = [(secrets / name).read_text().strip() for name in PASSWORD_FILES]
        values += [self.env_values()[key] for key in ENV_KEYS]
        values += [self.env_values()["GRAFANA_ADMIN_PASSWORD"]]
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{64}", value) for value in values))
        self.assertEqual(len(values), len(set(values)))
        for value in values:
            self.assertNotIn(value, result.stdout + result.stderr)
        for first, second in [("minio_root_user.txt", "minio_access_key"),
                              ("minio_root_password.txt", "minio_secret_key.txt")]:
            self.assertEqual((secrets / first).read_text(), (secrets / second).read_text())
        self.assertEqual(secrets.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(path.stat().st_mode & 0o444 == 0o444 for path in secrets.iterdir()))
        self.assertEqual((self.install / ".env").stat().st_mode & 0o777, 0o600)
        commands = [json.loads(line) for line in (self.root / "commands.jsonl").read_text().splitlines()]
        bootstrap = next(args for args in commands if args[-1] == "local-setup")
        self.assertIn("--interactive=false", bootstrap)
        self.assertIn("-T", bootstrap)
        self.assertIn("Synodus is ready", result.stdout)
        self.assertFalse(any("build" in args or "--build" in args for args in commands))
        self.assertTrue(any("pull" in args for args in commands))
        self.assertFalse(any((self.install / name).exists() for name in
                             (".git", "core-api", "web-frontend", "socket-server", "ai-service")))

    def test_rerun_preserves_passwords_and_user_configuration(self):
        self.run_installer()
        env_file = self.install / ".env"
        with env_file.open("a") as file:
            file.write("CUSTOM_SETTING=keep-this\n")
        files = [env_file, *self.install.glob("secrets/*")]
        before = {file: file.read_bytes() for file in files}
        self.run_installer()
        self.assertEqual(before, {file: file.read_bytes() for file in files})

    def test_missing_storage_key_reuses_existing_counterpart(self):
        self.run_installer()
        secrets = self.install / "secrets"
        password = (secrets / "minio_secret_key.txt").read_text()
        (secrets / "minio_root_password.txt").unlink()
        (secrets / "minio_access_key").unlink()
        self.run_installer()
        self.assertEqual((secrets / "minio_root_password.txt").read_text(), password)
        self.assertEqual((secrets / "minio_root_user.txt").read_text(), (secrets / "minio_access_key").read_text())

    def test_startup_failure_does_not_report_success_or_delete_credentials(self):
        self.env["SETUP_TEST_FAIL"] = "1"
        result = self.run_installer(success=False)
        self.assertIn("Data and containers are preserved", result.stderr)
        self.assertNotIn("Synodus is ready", result.stdout)
        self.assertTrue((self.install / "secrets/db_admin_password.txt").is_file())


if __name__ == "__main__":
    unittest.main()
