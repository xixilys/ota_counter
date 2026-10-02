from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class DeployIdolSeedUpdaterTest(unittest.TestCase):
    def test_environment_overrides_reach_deployed_service(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            commands = directory / "bin"
            commands.mkdir()
            ssh = commands / "ssh"
            ssh.write_text("#!/bin/sh\nexit 0\n")
            ssh.chmod(0o755)
            scp = commands / "scp"
            scp.write_text(
                '#!/bin/sh\nfor arg in "$@"; do\n'
                'case "$arg" in */ota-counter-idol-seed-update.service) '
                'cp "$arg" "$CAPTURE_SERVICE";; esac\ndone\n'
            )
            scp.chmod(0o755)
            capture = directory / "service"
            environment = dict(os.environ, PATH=str(commands) + ":" + os.environ["PATH"],
                OTA_UPDATE_SSH_HOST="fake-host", OTA_IDOL_UPDATER_APP_DIR="/opt/test-updater",
                OTA_UPDATE_REMOTE_DIR="/var/www/test-site", CAPTURE_SERVICE=str(capture))
            subprocess.run(["bash", str(ROOT / "tool/deploy_idol_seed_updater.sh"), "--no-run-now"],
                           env=environment, check=True, capture_output=True, text=True)
            unit = capture.read_text()
            self.assertIn('Environment="OTA_IDOL_UPDATER_APP_DIR=/opt/test-updater"', unit)
            self.assertIn('Environment="OTA_IDOL_PUBLIC_DIR=/var/www/test-site"', unit)
            self.assertIn('ExecStart="/opt/test-updater/run_idol_seed_update.sh"', unit)


if __name__ == "__main__":
    unittest.main()
