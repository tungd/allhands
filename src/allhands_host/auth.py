import base64
import binascii
from pathlib import Path
import shutil
import subprocess
import tempfile

from allhands_host.models import UserRecord, utc_now
from allhands_host.store import UserStore

REALM = "All Hands"


def _bcrypt_module():
    try:
        import bcrypt
    except ModuleNotFoundError:
        return None
    return bcrypt


def _htpasswd_binary() -> str | None:
    return shutil.which("htpasswd")


def hash_password(password: str) -> str:
    bcrypt = _bcrypt_module()
    password_bytes = password.encode("utf-8")
    if bcrypt is not None:
        return bcrypt.hashpw(password_bytes, bcrypt.gensalt(rounds=12)).decode("utf-8")

    htpasswd = _htpasswd_binary()
    if htpasswd is None:
        raise RuntimeError("bcrypt support requires the Python bcrypt package or the htpasswd command")
    result = subprocess.run(
        [htpasswd, "-nbBC", "12", "user", password],
        check=True,
        capture_output=True,
        text=True,
    )
    _, _, password_hash = result.stdout.strip().partition(":")
    return password_hash


def verify_password(password: str, password_hash: str) -> bool:
    bcrypt = _bcrypt_module()
    password_bytes = password.encode("utf-8")
    if bcrypt is not None:
        return bcrypt.checkpw(password_bytes, password_hash.encode("utf-8"))

    htpasswd = _htpasswd_binary()
    if htpasswd is None:
        raise RuntimeError("bcrypt support requires the Python bcrypt package or the htpasswd command")

    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(f"user:{password_hash}\n")
        auth_file = Path(handle.name)
    try:
        result = subprocess.run(
            [htpasswd, "-vb", str(auth_file), "user", password],
            check=False,
            capture_output=True,
            text=True,
        )
    finally:
        auth_file.unlink(missing_ok=True)
    return result.returncode == 0


def ensure_default_user(user_store: UserStore, username: str, password: str) -> UserRecord:
    try:
        user = user_store.get_user(username)
    except KeyError:
        user = None

    if user is not None and verify_password(password, user.password_hash):
        return user

    now = utc_now()
    user = UserRecord(
        username=username,
        password_hash=hash_password(password),
        created_at=user.created_at if user is not None else now,
        updated_at=now,
    )
    user_store.upsert_user(user)
    return user


def parse_basic_authorization(header_value: str | None) -> tuple[str, str] | None:
    if not header_value:
        return None
    scheme, _, encoded = header_value.partition(" ")
    if scheme.lower() != "basic" or not encoded:
        return None
    try:
        decoded = base64.b64decode(encoded, validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError):
        return None
    username, separator, password = decoded.partition(":")
    if not separator:
        return None
    return username, password


class BasicAuthenticator:
    def __init__(self, user_store: UserStore):
        self.user_store = user_store

    def authenticate(self, header_value: str | None) -> UserRecord | None:
        credentials = parse_basic_authorization(header_value)
        if credentials is None:
            return None
        username, password = credentials
        try:
            user = self.user_store.get_user(username)
        except KeyError:
            return None
        if not verify_password(password, user.password_hash):
            return None
        return user
