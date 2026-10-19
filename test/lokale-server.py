# Testserver voor de website op localhost: serveert de e2e-testmap en laat de website schrijven in data/
# (PUT en DELETE), zoals de GitHub-API dat in productie doet. Alleen voor tests, alleen op 127.0.0.1.
#   python test/lokale-server.py 8765 %TEMP%\doubleleren-e2e
import http.server, os, sys

poort = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
basis = os.path.realpath(sys.argv[2] if len(sys.argv) > 2 else '.')
data = os.path.join(basis, 'data')


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=basis, **k)

    def doel(self):
        pad = self.path.split('?', 1)[0]
        if not pad.startswith('/data/'):
            return None
        f = os.path.realpath(os.path.join(basis, pad.lstrip('/')))
        return f if f.startswith(data + os.sep) else None

    def do_PUT(self):
        f = self.doel()
        n = int(self.headers.get('Content-Length') or 0)
        if not f or n > 2_000_000:
            self.send_error(403); return
        os.makedirs(os.path.dirname(f), exist_ok=True)
        with open(f, 'wb') as h:
            h.write(self.rfile.read(n))
        self.send_response(201); self.send_header('Content-Length', '0'); self.end_headers()

    def do_DELETE(self):
        f = self.doel()
        if not f:
            self.send_error(403); return
        if os.path.isfile(f):
            os.remove(f)
        self.send_response(204); self.end_headers()

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


http.server.ThreadingHTTPServer(('127.0.0.1', poort), Handler).serve_forever()
