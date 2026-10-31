import http.server, pathlib, sys
root=pathlib.Path(sys.argv[1]).resolve()
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs): super().__init__(*args,directory=str(root/'www'),**kwargs)
    def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'port.txt').write_text(str(server.server_port))
print('Isolated localhost update server port:',server.server_port,flush=True)
server.serve_forever()
