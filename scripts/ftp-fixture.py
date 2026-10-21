#!/usr/bin/env python3
"""Independent FTP, explicit FTPS, implicit FTPS, and legacy LIST fixtures.

Virtual test accounts, a disposable root, generated CA/server keys, localhost only.
Production code and application bundles do not depend on these Python packages.
"""
import datetime
import json
import logging
import os
import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer

logging.basicConfig(level=logging.ERROR)
fixture = Path(sys.argv[1])
remote = fixture / "remote"
remote.mkdir()
(fixture / "local").mkdir()
(remote / "welcome.txt").write_text("syncSCP FTP/FTPS fixture · İstanbul · 日本語\n", encoding="utf-8")
(fixture / "local" / "upload.txt").write_text("Native macOS transfer test\n", encoding="utf-8")
now = datetime.datetime.now(datetime.timezone.utc)
ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "syncSCP disposable test CA")])
ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name).public_key(ca_key.public_key())
      .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
      .not_valid_after(now + datetime.timedelta(days=2)).add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
      .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=False,
                                 data_encipherment=False, key_agreement=False, key_cert_sign=True, crl_sign=True,
                                 encipher_only=False, decipher_only=False), critical=True).sign(ca_key, hashes.SHA256()))
server_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
server_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
certificate = (x509.CertificateBuilder().subject_name(server_name).issuer_name(ca_name).public_key(server_key.public_key())
               .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
               .not_valid_after(now + datetime.timedelta(days=1))
               .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
               .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
               .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
               .sign(ca_key, hashes.SHA256()))
(fixture / "ca.pem").write_bytes(ca.public_bytes(serialization.Encoding.PEM))
(fixture / "server.pem").write_bytes(certificate.public_bytes(serialization.Encoding.PEM) + ca.public_bytes(serialization.Encoding.PEM))
(fixture / "server.key").write_bytes(server_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
os.chmod(fixture / "server.key", 0o600)

authorizer = DummyAuthorizer()
authorizer.add_user("syncscp", "test-only-password", str(remote), perm="elradfmwMT")
authorizer.add_user("readonly", "test-only-password", str(remote), perm="elr")

class Plain(FTPHandler):
    auth_failed_timeout = 0

class Explicit(TLS_FTPHandler):
    auth_failed_timeout = 0
    tls_control_required = True
    tls_data_required = True
    certfile = str(fixture / "server.pem")
    keyfile = str(fixture / "server.key")

class Implicit(Explicit):
    def handle(self):
        self.secure_connection(self.ssl_context)

    def handle_ssl_established(self):
        FTPHandler.handle(self)

class Legacy(Plain):
    def ftp_MLSD(self, path):
        self.respond("502 MLSD not implemented for legacy fixture")

class SparseMetadata(Plain):
    def ftp_OPTS(self, line):
        if line.upper().startswith("MLST"):
            self._current_facts = ["type"]
            self.respond("200 MLST OPTS accepted with type facts only")
        else:
            super().ftp_OPTS(line)

servers = []
ports = {}
for name, handler in [("ftp", Plain), ("explicit", Explicit), ("implicit", Implicit), ("legacy", Legacy), ("sparse", SparseMetadata)]:
    handler.authorizer = authorizer
    handler.banner = "syncSCP disposable localhost test fixture"
    server = FTPServer(("127.0.0.1", 0), handler)
    server.max_cons = 64
    servers.append(server)
    ports[name] = server.socket.getsockname()[1]
configuration = {"root": str(fixture), "ports": ports}
(fixture / "ready.json").write_text(json.dumps(configuration), encoding="utf-8")
try:
    servers[0].serve_forever(timeout=0.1, handle_exit=False)
finally:
    for server in servers:
        server.close_all()
