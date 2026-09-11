import importlib.util
import os
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock
ROOT=Path(__file__).resolve().parents[1]
SCRIPT=ROOT/'tests/live-remote.sh'
spec=importlib.util.spec_from_file_location('remote_probe',ROOT/'scripts/remote-probe.py'); remote=importlib.util.module_from_spec(spec); spec.loader.exec_module(remote)

def address(host,port,*args,**kwargs):
 mapping={'safe.example':'100.64.0.10','next.example':'100.64.0.11',
          'public.example':'192.0.2.10','localhost':'127.0.0.1'}
 ip=mapping.get(host,host)
 return [(socket.AF_INET,socket.SOCK_STREAM,6,'',(ip,port))]

class LiveGateTest(unittest.TestCase):
 def test_unconfigured_gate_skips(self):
  env=os.environ.copy(); env.pop('ODOO_REMOTE_URL',None); result=subprocess.run([SCRIPT],env=env,capture_output=True)
  self.assertEqual(result.returncode,77)
 def test_rejects_local_origins_before_local_verify(self):
  for url in ('http://localhost:18069','http://127.0.0.2:18069','http://[::1]:18069','http://0.0.0.0:18069'):
   result=subprocess.run([SCRIPT],env=os.environ|{'ODOO_REMOTE_URL':url},text=True,capture_output=True)
   self.assertNotEqual(result.returncode,0,url); self.assertNotIn('Local verification passed',result.stderr)
 def test_rejects_ipv4_mapped_ipv6_loopback(self):
  mapped=[(socket.AF_INET6,socket.SOCK_STREAM,6,'',('::ffff:127.0.0.1',18069,0,0))]
  with mock.patch.object(remote.socket,'getaddrinfo',return_value=mapped):
   with self.assertRaisesRegex(ValueError,'loopback'): remote.validate_url('http://mapped.example:18069')
 def fake_curl(self,root):
  path=root/'curl'; path.write_text("""#!/usr/bin/env python3
import os,sys
args=sys.argv[1:]; header=args[args.index('--dump-header')+1]; url=args[-1]
status=os.environ.get('FAKE_STATUS','200'); location=os.environ.get('FAKE_LOCATION')
if os.environ.get('FAKE_REDIRECT_ONCE') and 'safe.example' in url:
 status='302'; location='http://next.example/final'
peer=os.environ.get('FAKE_PEER') or ('100.64.0.11' if 'next.example' in url else '100.64.0.10')
with open(header,'w') as out:
 out.write('HTTP/1.1 '+status+' Test\\r\\n')
 if location: out.write('Location: '+location+'\\r\\n')
 out.write('\\r\\n')
print(status); print(peer); print(url,end='')
"""); path.chmod(0o755); return path
 @mock.patch.object(remote.socket,'getaddrinfo',side_effect=address)
 def test_valid_probe_pins_dns_and_accepts_approved_effective_peer(self,_):
  with tempfile.TemporaryDirectory() as d:
   curl=self.fake_curl(Path(d)); status,effective=remote.probe('http://safe.example/web/health',str(curl))
   self.assertEqual(status,200); self.assertEqual(effective,'http://safe.example/web/health')
 @mock.patch.object(remote.socket,'getaddrinfo',side_effect=address)
 def test_public_address_requires_an_explicit_peer_identity(self,_):
  with self.assertRaisesRegex(ValueError,'Tailscale CGNAT/ULA'):
   remote.validate_url('http://public.example:18069')
  peer=remote.ipaddress.ip_address('192.0.2.10')
  host,port,addresses=remote.validate_url('http://public.example:18069',explicit_peer=peer)
  self.assertEqual((host,port,str(addresses[0])),('public.example',18069,'192.0.2.10'))
 @mock.patch.object(remote.socket,'getaddrinfo',side_effect=address)
 def test_valid_redirect_revalidates_and_pins_the_next_hop(self,_):
  with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ,{'FAKE_REDIRECT_ONCE':'1'}):
   curl=self.fake_curl(Path(d)); status,effective=remote.probe('http://safe.example/',str(curl))
   self.assertEqual(status,200); self.assertEqual(effective,'http://next.example/final')
 @mock.patch.object(remote.socket,'getaddrinfo',side_effect=address)
 def test_redirect_to_loopback_is_rejected_before_second_request(self,_):
  with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ,{'FAKE_STATUS':'302','FAKE_LOCATION':'http://localhost:18069/'}):
   curl=self.fake_curl(Path(d))
   with self.assertRaisesRegex(ValueError,'localhost'): remote.probe('http://safe.example/',str(curl))
 @mock.patch.object(remote.socket,'getaddrinfo',side_effect=address)
 def test_unapproved_effective_peer_is_rejected(self,_):
  with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ,{'FAKE_PEER':'127.0.0.1'}):
   curl=self.fake_curl(Path(d))
   with self.assertRaisesRegex(ValueError,'effective peer'): remote.probe('http://safe.example/',str(curl))

if __name__=='__main__': unittest.main()
