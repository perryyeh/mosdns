"""Sandbox checks for mosdns rule/my sync modes and reload timing."""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
CRON = REPO / "cron"
SHA = "0123456789abcdef0123456789abcdef01234567"
LISTS = {
    "whitelist.txt": "domain:example.com\n# === 2026-11-05 ===\nkeyword:bank\n",
    "greylist.txt": "full:grey.example\n",
    "blacklist.txt": "",
    "hosts.txt": "# fixed\nlogs.example.com 127.0.0.1 ::1\n",
}


class SyncModeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mos = self.root / "mos"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        shutil.copytree(CRON, self.mos / "cron")
        (self.mos / "my").mkdir()
        (self.mos / "rule").mkdir()
        (self.mos / "tmp").mkdir()
        self.wget_log = self.root / "wget.log"
        self.kill_log = self.root / "kill.log"
        self._write_tool("timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
        self._write_tool("wget", r"""#!/bin/sh
printf '%s\n' "$*" >> "$WGET_LOG"
dest=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-O" ]; then dest=$arg; fi
    prev=$arg
done
url=${prev}
case "$url" in
    *api.github.com/repos/perryyeh/mosdns/commits/main*)
        if [ "${WGET_FAIL_API:-0}" = 1 ]; then exit 1; fi
        printf '%s\n' "{\"sha\":\"${WGET_SHA}\"}" > "$dest"
        ;;
    *)
        name=${url##*/}
        if [ "${WGET_FAIL_FILE:-}" = "$name" ]; then exit 1; fi
        if [ "${WGET_HTML_FILE:-}" = "$name" ]; then
            printf '<html><body>nope</body></html>\n' > "$dest"
            exit 0
        fi
        if [ "${WGET_BAD_HOSTS:-0}" = 1 ] && [ "$name" = hosts.txt ]; then
            printf 'not-a-host\n' > "$dest"
            exit 0
        fi
        src="$WGET_BODY/$name"
        if [ -f "$src" ]; then cp "$src" "$dest"; else printf 'domain:example.com\n' > "$dest"; fi
        ;;
esac
exit 0
""")
        self._write_tool("kill", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$KILL_LOG\"\nexit 0\n")
        body = self.root / "body"
        body.mkdir()
        for name, text in LISTS.items():
            (body / name).write_text(text)
        (body / "geoip_cn.txt").write_text("203.0.113.0/24\n")
        (body / "geosite_direct.txt").write_text("domain:direct.example\n")
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.root / "home"),
            "TMPDIR": str(self.root / "tmpwork"),
            "WGET_LOG": str(self.wget_log),
            "WGET_SHA": SHA,
            "WGET_BODY": str(body),
            "KILL_LOG": str(self.kill_log),
            "MOSDNS_KILL": str(self.bin / "kill"),
            "MOSDNS_ROOT": str(self.mos),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        (self.root / "home").mkdir()
        (self.root / "tmpwork").mkdir()

    def _write_tool(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def write_env(self, text):
        (self.mos / "cron" / "cron.env").write_text(text)

    def write_conf(self, text):
        (self.mos / "cron" / "sync.conf").write_text(text)

    def run_script(self, script, *args):
        return subprocess.run(["sh", str(self.mos / "cron" / script), *args],
                              env=self.env, text=True, capture_output=True, timeout=30)

    def seed_my(self, **overrides):
        for name, text in LISTS.items():
            (self.mos / "my" / name).write_text(overrides.get(name, "domain:old.example\n" if name != "hosts.txt" else "old.example 127.0.0.1\n"))

    def snapshot_my(self):
        return {path.name: path.read_bytes() for path in (self.mos / "my").iterdir()}

    def my_conf(self):
        lines = []
        for name in ("whitelist.txt", "greylist.txt", "blacklist.txt", "hosts.txt"):
            lines.append(f"my/{name} | yes | https://raw.githubusercontent.com/perryyeh/mosdns/main/my/{name}")
        return "\n".join(lines) + "\n"

    def test_crontab_uses_0100_download_and_0110_reload(self):
        text = (CRON / "crontab.conf").read_text()
        self.assertIn("0 0 * * * /etc/mosdns/cron/sync-rules.sh", text)
        self.assertIn("30 0 * * * /etc/mosdns/cron/reload-if-needed.sh rules", text)
        self.assertIn("0 1 * * * /etc/mosdns/cron/sync-my.sh", text)
        self.assertIn("10 1 * * * /etc/mosdns/cron/reload-if-needed.sh my", text)
        self.assertIn("sync-my-*.log", text)

    def test_mode2_pins_one_commit_and_writes_only_after_all_files(self):
        self.write_env("MOSDNS_MY_MODE=2\nMOSDNS_SYNC_CANDIDATES_ENABLED=1\nMOSDNS_PROMOTE_ENABLED=1\n")
        self.write_conf("rule/geosite_direct.txt | yes | https://example.invalid/direct\n" + self.my_conf())
        self.seed_my()
        result = self.run_script("sync-my.sh")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        for name, text in LISTS.items():
            self.assertEqual((self.mos / "my" / name).read_text(), text)
        self.assertTrue((self.mos / "tmp" / "reload-needed").is_file())
        urls = self.wget_log.read_text()
        self.assertEqual(urls.count(SHA), 4)
        self.assertNotIn("/main/my/", urls)
        self.assertIn("commits/main", urls)
        self.assertNotIn("example.invalid", urls)

    def test_download_failure_html_and_bad_hosts_keep_old_files(self):
        self.write_env("MOSDNS_MY_MODE=2\n")
        self.write_conf(self.my_conf())
        for failure in ({"WGET_FAIL_FILE": "blacklist.txt"}, {"WGET_HTML_FILE": "greylist.txt"},
                        {"WGET_BAD_HOSTS": "1"}, {"WGET_FAIL_API": "1"}):
            with self.subTest(failure=failure):
                self.seed_my()
                before = self.snapshot_my()
                env = dict(self.env)
                env.update(failure)
                self.wget_log.write_text("")
                result = subprocess.run(["sh", str(self.mos / "cron" / "sync-my.sh")],
                                        env=env, text=True, capture_output=True, timeout=30)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.snapshot_my(), before)
                self.assertFalse((self.mos / "tmp" / "reload-needed").exists())

    def test_unchanged_lists_do_not_touch_reload_marker(self):
        self.write_env("MOSDNS_MY_MODE=2\n")
        self.write_conf(self.my_conf())
        for name, text in LISTS.items():
            (self.mos / "my" / name).write_text(text)
        marker = self.mos / "tmp" / "reload-needed"
        marker.write_text("keep")
        before = marker.stat().st_mtime_ns
        result = self.run_script("sync-my.sh")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("unchanged", result.stdout)
        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(marker.stat().st_mtime_ns, before)

    def test_mode1_and_legacy_do_not_download_or_override(self):
        self.write_conf(self.my_conf())
        cases = (
            "MOSDNS_MY_MODE=1\nMOSDNS_SYNC_CANDIDATES_ENABLED=1\nMOSDNS_PROMOTE_ENABLED=1\n",
            "MOSDNS_SYNC_CANDIDATES_ENABLED=1\nMOSDNS_PROMOTE_ENABLED=1\n",
            "MOSDNS_MY_MODE=0\n",
            "MOSDNS_MY_MODE=9\nMOSDNS_SYNC_CANDIDATES_ENABLED=1\n",
        )
        for text in cases:
            with self.subTest(text=text):
                self.write_env(text)
                self.seed_my()
                before = self.snapshot_my()
                self.wget_log.write_text("")
                result = self.run_script("sync-my.sh")
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertIn("my download skipped", result.stdout)
                self.assertEqual(self.snapshot_my(), before)
                self.assertFalse(self.wget_log.exists() and self.wget_log.read_text())
                self.assertFalse((self.mos / "tmp" / "reload-needed").exists())

    def test_mode2_suppresses_candidates_and_promote(self):
        self.write_env("MOSDNS_MY_MODE=2\nMOSDNS_SYNC_CANDIDATES_ENABLED=1\nMOSDNS_PROMOTE_ENABLED=1\n")
        candidates = self.run_script("sync-candidates.sh")
        promote = self.run_script("promote-candidates.sh")
        self.assertEqual(candidates.returncode, 0, candidates.stderr)
        self.assertEqual(promote.returncode, 0, promote.stderr)
        self.assertIn("candidate sync suppressed", candidates.stdout)
        self.assertIn("candidate promotion suppressed", promote.stdout)
        self.assertFalse(any((self.mos / "tmp").glob("not-in-list*")))
        self.assertFalse(any(self.mos.rglob(".sync-candidates-disabled*")))

    def test_extra_or_disabled_my_entry_writes_nothing(self):
        self.write_env("MOSDNS_MY_MODE=2\n")
        self.seed_my()
        before = self.snapshot_my()
        for conf in (
            self.my_conf() + "my/whitelist.txt.before-apple | yes | https://example.invalid/backup\n",
            self.my_conf().replace("my/blacklist.txt | yes |", "my/blacklist.txt | no |"),
        ):
            with self.subTest(conf=conf.splitlines()[-1]):
                self.write_conf(conf)
                result = self.run_script("sync-my.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot_my(), before)

    def test_rules_skip_my_and_reject_escape_paths(self):
        self.write_env("MOSDNS_SYNC_RULES_ENABLED=1\nMOSDNS_MY_MODE=1\n")
        self.write_conf("\n".join([
            "geoip_cn.txt | yes | https://example.invalid/geoip_cn.txt",
            "rule/geosite_direct.txt | yes | https://example.invalid/geosite_direct.txt",
            "my/whitelist.txt | yes | https://raw.githubusercontent.com/perryyeh/mosdns/main/my/whitelist.txt",
            "/tmp/evil.txt | yes | https://example.invalid/evil",
            "../evil.txt | yes | https://example.invalid/dot",
            "other/evil.txt | yes | https://example.invalid/other",
            "rule/../../tmp/evil.txt | yes | https://example.invalid/nest",
        ]) + "\n")
        (self.mos / "my" / "whitelist.txt").write_text("keep-my\n")
        result = self.run_script("sync-rules.sh")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.mos / "rule" / "geoip_cn.txt").read_text(), "203.0.113.0/24\n")
        self.assertEqual((self.mos / "rule" / "geosite_direct.txt").read_text(), "domain:direct.example\n")
        self.assertEqual((self.mos / "my" / "whitelist.txt").read_text(), "keep-my\n")
        self.assertFalse((self.root / "evil.txt").exists())
        self.assertFalse((self.mos / "evil.txt").exists())
        urls = self.wget_log.read_text()
        self.assertNotIn("perryyeh/mosdns", urls)
        self.assertNotIn("example.invalid/evil", urls)
        self.assertIn("handled by my sync", result.stdout)
        self.assertIn("reject sync target", result.stdout)

    def test_reload_slots_follow_mode(self):
        marker = self.mos / "tmp" / "reload-needed"
        cases = (
            ("2", "rules", True),
            ("2", "my", False),
            ("1", "rules", False),
            ("1", "my", True),
            ("0", "rules", False),
            ("0", "my", True),
        )
        for mode, slot, remains in cases:
            with self.subTest(mode=mode, slot=slot):
                self.write_env(f"MOSDNS_MY_MODE={mode}\nMOSDNS_RELOAD_ENABLED=1\nMOSDNS_RELOAD_METHOD=none\n")
                marker.write_text("needed")
                self.kill_log.write_text("")
                result = self.run_script("reload-if-needed.sh", slot)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertEqual(marker.exists(), remains)
                self.assertEqual(self.kill_log.read_text(), "")
        self.write_env("MOSDNS_MY_MODE=1\nMOSDNS_RELOAD_ENABLED=1\nMOSDNS_RELOAD_METHOD=restart\n")
        marker.write_text("needed")
        result = self.run_script("reload-if-needed.sh", "rules")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse(marker.exists())
        self.assertIn("-TERM 1", self.kill_log.read_text())


if __name__ == "__main__":
    unittest.main()
