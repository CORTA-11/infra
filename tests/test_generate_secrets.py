"""Fresh production credentials must work without manual files or rotation."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ProductionSecretsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copyfile(Path(__file__).resolve().parents[1] / "generate-secrets.sh",
                        self.root / "generate-secrets.sh")

    def run_generator(self):
        subprocess.run(["bash", "generate-secrets.sh"], cwd=self.root,
                       capture_output=True, text=True, check=True)

    def test_fresh_credentials_are_complete_matched_and_preserved(self):
        self.run_generator()
        secrets = self.root / "secrets"
        snapshot = {p.name: p.read_bytes() for p in secrets.iterdir()}
        for name in ("db_admin_password.txt", "db_runtime_password.txt",
                     "db_migrator_password.txt", "db_provisioner_password.txt"):
            self.assertRegex(snapshot[name].decode().strip(), r"^[0-9a-f]{64}$")
        self.assertEqual(len({snapshot[n] for n in snapshot if n.startswith("db_")
                              and "password" in n}), 4)
        self.assertEqual(snapshot["minio_root_user.txt"], snapshot["minio_access_key"])
        self.assertEqual(snapshot["minio_root_password.txt"], snapshot["minio_secret_key.txt"])
        self.assertEqual(secrets.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / ".env").stat().st_mode & 0o777, 0o600)
        env = (self.root / ".env").read_bytes()
        self.run_generator()
        self.assertEqual(snapshot, {p.name: p.read_bytes() for p in secrets.iterdir()})
        self.assertEqual(env, (self.root / ".env").read_bytes())

    def test_partial_storage_credentials_are_reused_and_empty_files_repaired(self):
        secrets = self.root / "secrets"
        secrets.mkdir()
        (secrets / "minio_access_key").write_text("custom-user\n")
        (secrets / "minio_secret_key.txt").write_text("custom-storage-password\n")
        (secrets / "db_migrator_password.txt").touch()
        self.run_generator()
        self.assertEqual((secrets / "minio_root_user.txt").read_text(), "custom-user\n")
        self.assertEqual((secrets / "minio_root_password.txt").read_text(), "custom-storage-password\n")
        self.assertTrue((secrets / "db_migrator_password.txt").read_text().strip())

    def test_custom_password_prefix_is_preserved_and_quoted_placeholder_replaced(self):
        (self.root / ".env").write_text('JWT_SECRET=admin-prefix-custom-secret\nGRAFANA_ADMIN_PASSWORD="admin"\n')
        self.run_generator()
        env = (self.root / ".env").read_text()
        self.assertIn("JWT_SECRET=admin-prefix-custom-secret\n", env)
        self.assertRegex(env, r"GRAFANA_ADMIN_PASSWORD=[0-9a-f]{64}\n")


if __name__ == "__main__":
    unittest.main()
