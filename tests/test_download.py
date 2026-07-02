"""Download workload returns sensible numbers against a local target."""
import http.server
import socketserver
import threading

from probe.workloads import download

PAYLOAD = b"x" * (1 << 20)  # 1 MiB


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        self.wfile.write(PAYLOAD)

    def log_message(self, *_):
        pass


def test_download_throughput():
    with socketserver.TCPServer(("127.0.0.1", 0), _Handler) as srv:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        port = srv.server_address[1]
        result = download.run(f"http://127.0.0.1:{port}/testfile.bin")
        srv.shutdown()

    assert result["bytes"] == len(PAYLOAD)
    assert result["throughput_mbps"] > 0
