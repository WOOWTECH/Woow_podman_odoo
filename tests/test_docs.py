import re
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
DOCS=[ROOT/'README.md', ROOT/'docs/skills/deploy-odoo18.md', ROOT/'docs/DEPLOYMENT_RECORD.md']
class DocsContractTest(unittest.TestCase):
 def test_no_legacy_insecure_instructions(self):
  text='\n'.join(p.read_text() for p in DOCS)
  banned=[r'admin_passwd\s*=\s*admin',r'(?<!127\.0\.0\.1:)18069:8069',r'(?<![\w.-])odoo:18(?!\.0)',r'docker compose',r'POSTGRES_' + r'PASSWORD=',r'Portainer',r'Nginx Proxy Manager',r'git clone.+pgvector']
  for pattern in banned: self.assertIsNone(re.search(pattern,text,re.I),pattern)
 def test_bilingual_operations_are_complete(self):
  text='\n'.join(p.read_text() for p in DOCS)
  for english,chinese in [('Prerequisites','前置需求'),('Deploy','部署'),('Verify','驗證'),('systemd','systemd'),('local URL','本機網址'),('Tailnet-only remote gate','僅限 tailnet'),('Backup','備份'),('Restore','還原'),('Safe removal','安全移除'),('Upgrades and digest rotation','升級與 digest 輪替'),('Troubleshooting','疑難排解'),('Security boundary','安全邊界')]:
   self.assertIn(english,text); self.assertIn(chinese,text)
 def test_commands_and_versions_are_documented(self):
  text=(ROOT/'README.md').read_text()
  for value in ['Podman **4.9.3**','podman-compose **1.0.6**','scripts/deploy.sh','scripts/verify.sh','scripts/backup.sh','scripts/restore.sh','scripts/remove.sh','loginctl enable-linger']:
   self.assertIn(value,text)
 def test_live_pinned_image_account_ids_are_documented(self):
  text=(ROOT/'README.md').read_text()
  for value in ['PostgreSQL `uid=999,gid=999`','Odoo `uid=100,gid=101`','web volume and filestore are `100:101`','fail-closed']:
   self.assertIn(value,text)
  self.assertNotIn('101:101',text)
if __name__=='__main__': unittest.main()
