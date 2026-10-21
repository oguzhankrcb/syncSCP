#!/usr/bin/env python3
"""Independent WsgiDAV over HTTP/HTTPS, disposable credentials/files and test-only faults."""
import datetime
import json
import logging
import os
import signal
import ssl
import sys
import threading
from urllib.parse import urlsplit, unquote
from pathlib import Path
from cheroot.wsgi import Server
from cheroot.ssl.builtin import BuiltinSSLAdapter
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
from wsgidav.wsgidav_app import WsgiDAVApp
from wsgidav.fs_dav_provider import FilesystemProvider

logging.basicConfig(level=logging.ERROR)
fixture = Path(sys.argv[1])
remote = fixture / 'remote'
remote.mkdir()
(fixture / 'local').mkdir()
(remote / 'welcome.txt').write_text('WebDAV fixture · İstanbul · 日本語\n', encoding='utf-8')
(fixture / 'local' / 'upload.txt').write_text('Native WebDAV upload.\n', encoding='utf-8')
now = datetime.datetime.now(datetime.timezone.utc)
ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'syncSCP WebDAV disposable CA')])
ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name).public_key(ca_key.public_key())
      .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=1))
      .not_valid_after(now+datetime.timedelta(days=2)).add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
      .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=False, data_encipherment=False,
                                 key_agreement=False, key_cert_sign=True, crl_sign=True, encipher_only=False, decipher_only=False), critical=True)
      .sign(ca_key, hashes.SHA256()))
server_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
server_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
certificate = (x509.CertificateBuilder().subject_name(server_name).issuer_name(ca_name).public_key(server_key.public_key())
               .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=1))
               .not_valid_after(now+datetime.timedelta(days=1)).add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
               .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), critical=False)
               .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False).sign(ca_key, hashes.SHA256()))
(fixture / 'ca.pem').write_bytes(ca.public_bytes(serialization.Encoding.PEM))
(fixture / 'server.pem').write_bytes(certificate.public_bytes(serialization.Encoding.PEM)+ca.public_bytes(serialization.Encoding.PEM))
(fixture / 'server.key').write_bytes(server_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
os.chmod(fixture / 'server.key', 0o600)
class FixtureProvider(FilesystemProvider):
    def get_resource_inst(self, path, environ):
        resource = super().get_resource_inst(path, environ)
        if resource is not None and path.endswith('/no-etag.txt'):
            resource.support_etag = lambda: False
            resource.get_etag = lambda: None
        return resource

app = WsgiDAVApp({
    'provider_mapping': {'/dav': FixtureProvider(str(remote)), '/readonly': FilesystemProvider(str(remote), readonly=True)},
    'http_authenticator': {'accept_basic': True, 'accept_digest': False, 'default_to_digest': False},
    'simple_dc': {'user_mapping': {'*': {'syncscp': {'password': 'test-only-password', 'roles': ['admin']}}}},
    'verbose': 0,
    'logging': {'enable': False},
    'dir_browser': {'enable': False},
    'property_manager': True,
    'lock_storage': True,
})

captures = 0
capture_lock = threading.Lock()

def capture(environ, start_response):
    global captures
    with capture_lock:
        captures += 1
        (fixture / 'capture-count').write_text(str(captures))
    start_response('200 OK', [('Content-Length', '0')])
    return [b'']

capture_server = Server(('127.0.0.1', 0), capture, numthreads=4, timeout=5)
capture_server.prepare()
(fixture / 'capture-count').write_text('0')
capture_url = f'http://127.0.0.1:{capture_server.bind_addr[1]}/credential-leak'

def faults(environ, start_response):
    method, path = environ['REQUEST_METHOD'], environ.get('PATH_INFO', '')
    if method == 'MOVE' and environ.get('HTTP_DESTINATION', '').endswith('/race-at-move.txt'):
        relative = unquote(urlsplit(environ['HTTP_DESTINATION']).path).removeprefix('/dav/')
        target = remote / relative
        if not target.resolve().is_relative_to(remote.resolve()):
            raise ValueError('Fixture destination is out of scope')
        target.write_bytes(b'External change at the MOVE boundary; preserve this version.')
        (fixture / 'race-condition-seen').write_text(environ.get('HTTP_IF', ''))
    if method == 'GET' and path.endswith('/redirect-file.txt'):
        start_response('302 Found', [('Location', capture_url), ('Content-Length', '0')])
        return [b'']
    if method == 'PROPFIND' and path == '/foreign-redirect/':
        start_response('301 Moved Permanently', [('Location', capture_url), ('Content-Length', '0')])
        return [b'']
    if method == 'DELETE' and path.rstrip('/').endswith('/partial-delete'):
        body = b'<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/partial-delete/keep.txt</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response></d:multistatus>'
        start_response('207 Multi-Status', [('Content-Type', 'application/xml'), ('Content-Length', str(len(body)))])
        return [body]
    # Normal responses and semantics are entirely WsgiDAV's implementation.
    return app(environ, start_response)

http = Server(('127.0.0.1', 0), faults, numthreads=8, timeout=5)
https = Server(('127.0.0.1', 0), faults, numthreads=8, timeout=5)
https.ssl_adapter = BuiltinSSLAdapter(str(fixture / 'server.pem'), str(fixture / 'server.key'))
https.ssl_adapter.context.minimum_version = ssl.TLSVersion.TLSv1_2
http.prepare()
https.prepare()
servers = [http, https, capture_server]
for server in servers:
    server.error_log = lambda *args, **kwargs: None
    threading.Thread(target=server.serve, daemon=True).start()
(fixture / 'ready.json').write_text(json.dumps({'root': str(fixture), 'http': http.bind_addr[1], 'https': https.bind_addr[1]}))
stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
try:
    stop.wait()
finally:
    for server in servers:
        server.stop()
