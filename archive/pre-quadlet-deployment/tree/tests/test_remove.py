import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

class RemoveBehaviorTest(unittest.TestCase):
 def setUp(self):
  self.t=tempfile.TemporaryDirectory(); self.root=Path(self.t.name); (self.root/'scripts').mkdir()
  for n in ('remove.sh','lib.sh'): shutil.copy(ROOT/'scripts'/n,self.root/'scripts'/n)
  self.state=self.root/'state'; self.state.mkdir(); self.log=self.root/'log'
  self.names=('odoo18-web','odoo18-db','odoo18-network','odoo18-web-data','odoo18-db-data')
  for n in self.names: (self.state/n).touch()
  podman=self.root/'podman'; podman.write_text("""#!/usr/bin/env bash
printf '%s\\n' "$*" >>"$FAKE_LOG"
kind=$1; action=$2
if [[ $action == inspect ]]; then
 name=${@: -1}; [[ -e "$FAKE_STATE/$name" ]] || exit 1
 if [[ $3 == --format ]]; then [[ ${FOREIGN_RESOURCE:-} == "$name" ]] && echo 'other 9' || echo "odoo18 $ODOO_DEPLOY_UID"; fi
elif [[ $kind == rm || $action == rm ]]; then rm -f "$FAKE_STATE/${@: -1}"
fi
"""); podman.chmod(0o755)
  systemctl=self.root/'systemctl'; systemctl.write_text("#!/usr/bin/env bash\nprintf 'systemctl %s\\n' \"$*\" >>\"$FAKE_LOG\"\n"); systemctl.chmod(0o755)
  identity=self.root/'id'; identity.write_text("#!/usr/bin/env bash\n[[ $1 == -u ]] && echo 1000 || /usr/bin/id \"$@\"\n"); identity.chmod(0o755)
  self.env=os.environ|{'ODOO_PROJECT_ROOT':str(self.root),'PODMAN_BIN':str(podman),'SYSTEMCTL_BIN':str(systemctl),'FAKE_STATE':str(self.state),'FAKE_LOG':str(self.log),'ODOO_DEPLOY_UID':'1000','PATH':str(self.root)+os.pathsep+os.environ['PATH']}
 def tearDown(self): self.t.cleanup()
 def run_remove(self,*args,**extra): return subprocess.run([self.root/'scripts/remove.sh',*args],env=self.env|extra,text=True,capture_output=True)
 def test_default_removal_is_exact_idempotent_and_preserves_data(self):
  for _ in range(2):
   result=self.run_remove(); self.assertEqual(result.returncode,0,result.stderr)
  self.assertFalse((self.state/'odoo18-web').exists()); self.assertFalse((self.state/'odoo18-network').exists())
  self.assertTrue((self.state/'odoo18-web-data').exists()); self.assertTrue((self.state/'odoo18-db-data').exists())
  self.assertNotIn('prune',self.log.read_text())
 def test_foreign_object_blocks_every_mutation_and_confirmed_purge_removes_volumes(self):
  blocked=self.run_remove(FOREIGN_RESOURCE='odoo18-network'); self.assertNotEqual(blocked.returncode,0)
  self.assertNotIn('systemctl',self.log.read_text()); self.assertTrue(all((self.state/n).exists() for n in self.names))
  self.log.write_text(''); ok=self.run_remove('--purge-data','--confirm-purge','odoo18')
  self.assertEqual(ok.returncode,0,ok.stderr); self.assertFalse(any((self.state/n).exists() for n in self.names))

if __name__=='__main__': unittest.main()
