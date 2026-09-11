import importlib.util
import stat
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/odoo-healthcheck.py"
spec = importlib.util.spec_from_file_location("odoo_healthcheck", SCRIPT)
healthcheck = importlib.util.module_from_spec(spec)
spec.loader.exec_module(healthcheck)


class ProbeHandler(BaseHTTPRequestHandler):
    status = 200
    paths = []

    def do_GET(self):
        type(self).paths.append(self.path)
        self.send_response(type(self).status)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, _format, *_args):
        pass


class OdooHealthcheckTest(unittest.TestCase):
    def test_helper_is_an_executable_reviewed_file(self):
        self.assertTrue(SCRIPT.is_file())
        self.assertEqual(stat.S_IMODE(SCRIPT.stat().st_mode), 0o755)

    def run_probe(self, status):
        ProbeHandler.status = status
        ProbeHandler.paths = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), ProbeHandler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            result = healthcheck.check("127.0.0.1", server.server_port)
        finally:
            server.shutdown()
            thread.join()
            server.server_close()
        return result, ProbeHandler.paths

    def test_fresh_no_business_database_state_is_healthy_without_initialization(self):
        healthy, paths = self.run_probe(200)
        self.assertTrue(healthy)
        self.assertEqual(paths, ["/web/health"])

    def test_server_error_is_unhealthy(self):
        healthy, paths = self.run_probe(500)
        self.assertFalse(healthy)
        self.assertEqual(paths, ["/web/health"])

    def test_unreachable_http_process_is_unhealthy(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), ProbeHandler)
        port = server.server_port
        server.server_close()
        self.assertFalse(healthcheck.check("127.0.0.1", port))


if __name__ == "__main__":
    unittest.main()
