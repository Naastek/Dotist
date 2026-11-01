import http.server, pathlib, socketserver, sys
root=pathlib.Path(sys.argv[1]).resolve()
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs): super().__init__(*args,directory=str(root/'www'),**kwargs)
    def log_message(self,*args): pass
class LocalUpdateServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # The fixture uses loopback only; HTTPServer's reverse DNS can block startup.
        socketserver.TCPServer.server_bind(self)
        self.server_name = 'localhost'
        self.server_port = self.server_address[1]
server=LocalUpdateServer(('127.0.0.1',0),Handler)
(root/'port.txt').write_text(str(server.server_port))
print('Isolated localhost update server port:',server.server_port,flush=True)
server.serve_forever()
