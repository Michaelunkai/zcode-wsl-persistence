#!/usr/bin/env python3
"""migrate_credentials.py — cross-OS re-wrap of ZCode credential blobs.

App format (recovered from /opt/ZCode/resources/app.asar):
    enc:v1:<iv.b64url>.<tag.b64url>.<ciphertext.b64url>
    AES-256-GCM, key = sha256(secret), secret =
        $ZCODE_CREDENTIAL_SECRET if set, else
        `zcode-credential-fallback:<platform>:<homedir>:<username>`
    (Node base64url — unpadded; secret pieces joined with ':')

Windows-created blobs use the Windows fallback seed and cannot be decrypted on
Linux. This script finds the exact Windows seed by brute-forcing the small
candidate space (GCM auth tags make a correct guess self-verifying), decrypts
every value, and re-wraps it under $ZCODE_CREDENTIAL_SECRET so the store is
portable across the WSL boundary. All data stays on this machine; secrets are
never printed.
"""
import base64
import hashlib
import json
import os
import sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PREFIX = "enc:v1:"
IV_LEN, TAG_LEN = 12, 16

def b64u_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def b64u_encode(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")

def derive_key(secret: str) -> bytes:
    return hashlib.sha256(secret.encode("utf-8")).digest()

def try_decrypt(value: str, key: bytes):
    if not value.startswith(PREFIX):
        return value  # stored plaintext
    parts = value[len(PREFIX):].split(".")
    if len(parts) != 3:
        raise ValueError("bad envelope")
    iv, tag, ct = (b64u_decode(p) for p in parts)
    if len(iv) != IV_LEN or len(tag) != TAG_LEN:
        raise ValueError("bad iv/tag length")
    return AESGCM(key).decrypt(iv, ct + tag, None).decode("utf-8")

def encrypt_value(plaintext: str, key: bytes) -> str:
    iv = os.urandom(IV_LEN)
    ct_with_tag = AESGCM(key).encrypt(iv, plaintext.encode("utf-8"), None)
    ct, tag = ct_with_tag[:-TAG_LEN], ct_with_tag[-TAG_LEN:]
    return PREFIX + b64u_encode(iv) + "." + b64u_encode(tag) + "." + b64u_encode(ct)

def win_homedir_candidates() -> list:
    return [
        "C:\\Users\\Admin",
        "C:/Users/Admin",
        "C:\\Users\\Admin\\",
        "c:\\Users\\Admin",
        "C:\\Users\\ADMIN",
        os.environ.get("WIN_USERPROFILE", "C:\\Users\\Admin"),
    ]

def win_username_candidates() -> list:
    return ["Admin", "admin", "ADMIN", "WIN-3J258HUL6HD\\Admin"]

def find_windows_key(src: dict, probe_key: str | None = None):
    """Return (secret, key) that decrypts the probe entry; None if not found."""
    probe = None
    for k, v in src.items():
        if v.startswith(PREFIX):
            probe = (k, v)
            break
    if probe is None:
        raise RuntimeError("no encrypted entries found")
    cands = []
    if probe_key:
        cands.append(probe_key)
    for h in win_homedir_candidates():
        for u in win_username_candidates():
            cands.append(f"zcode-credential-fallback:win32:{h}:{u}")
    for secret in cands:
        key = derive_key(secret)
        try:
            try_decrypt(probe[1], key)
            return secret, key
        except Exception:
            continue
    return None, None

def main() -> int:
    staging = os.path.expanduser("~/.zcode/v2/credentials.windows.json")
    target = os.path.expanduser("~/.zcode/v2/credentials.json")
    secret = os.environ.get("ZCODE_CREDENTIAL_SECRET")
    probe = os.environ.get("ZCODE_WIN_SEED_PROBE")  # optional exact-seed hint
    if not secret:
        print("ERROR: ZCODE_CREDENTIAL_SECRET not set", file=sys.stderr)
        return 2
    with open(staging, "r", encoding="utf-8") as f:
        src = json.load(f)

    win_secret, win_key = find_windows_key(src, probe)
    if win_key is None:
        print("ERROR: no Windows seed candidate decrypted the probe entry "
              "(set ZCODE_WIN_SEED_PROBE if the app used a custom secret)",
              file=sys.stderr)
        return 3
    print(f"windows seed matched (pattern: zcode-credential-fallback:win32:...)"
          if not probe else "windows seed: provided probe")

    new_key = derive_key(secret)
    out, failed = {}, []
    for k, v in src.items():
        try:
            out[k] = encrypt_value(try_decrypt(v, win_key), new_key)
        except Exception:
            out[k] = v
            failed.append(k)

    tmp = target + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)

    print(f"migrated {len(out)} entries; re-wrapped={len(out) - len(failed)} verbatim={len(failed)}")
    if failed:
        print("FAILED entries:", ", ".join(failed))
    return 0 if not failed else 4

if __name__ == "__main__":
    sys.exit(main())
