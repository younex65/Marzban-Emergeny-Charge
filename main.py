from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
import os, requests, time, json, threading, urllib3
from pydantic import BaseModel
from typing import Optional

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ------------ ENV ------------
MARZBAN_BASE = os.getenv("MARZBAN_BASE_URL", "").rstrip("/")
ADMIN_USER = os.getenv("MARZBAN_ADMIN_USERNAME", "")
ADMIN_PASS = os.getenv("MARZBAN_ADMIN_PASSWORD", "")
VERIFY_SSL = os.getenv("MARZBAN_VERIFY_SSL", "false").lower() == "true"

# --------- TOKEN CACHE ---------
_token_cache = {"access": None, "exp": 0}
_token_lock = threading.Lock()

# ------------ STORAGE ------------
STORE_PATH = "/var/lib/marzban/emergency_flags.json"
if not os.path.isdir("/var/lib/marzban"):
    os.makedirs("/var/lib/marzban", exist_ok=True)


def load_store():
    try:
        with open(STORE_PATH) as f:
            return json.load(f)
    except:
        return {}


def save_store(d):
    tmp = STORE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    os.replace(tmp, STORE_PATH)


# ------------ TOKEN HANDLING ------------
def get_new_token():
    url = f"{MARZBAN_BASE}/api/admin/token"

    data = {
        "username": ADMIN_USER,
        "password": ADMIN_PASS,
        "grant_type": "password"
    }

    r = requests.post(url, data=data, verify=VERIFY_SSL, timeout=10)
    if r.status_code != 200:
        raise Exception(f"Token error {r.status_code}: {r.text}")

    js = r.json()
    token = js.get("access_token")
    exp = js.get("exp", int(time.time()) + 3600)

    if not token:
        raise Exception("No access_token returned")

    return token, exp


def get_token():
    """Auto-refresh token if expired"""
    now = time.time()

    with _token_lock:
        if _token_cache["access"] and now < _token_cache["exp"] - 10:
            return _token_cache["access"]

        tok, exp = get_new_token()
        _token_cache["access"] = tok
        _token_cache["exp"] = exp
        return tok


# ------------ MARZBAN API CALLS ------------
def marz_get(path: str):
    t = get_token()
    headers = {"Authorization": f"Bearer {t}"}
    url = f"{MARZBAN_BASE}{path}"

    r = requests.get(url, headers=headers, verify=VERIFY_SSL)
    if r.status_code == 401:
        # token expired → refresh and retry
        with _token_lock:
            _token_cache["exp"] = 0
        t = get_token()
        headers["Authorization"] = f"Bearer {t}"
        r = requests.get(url, headers=headers, verify=VERIFY_SSL)

    if r.status_code != 200:
        raise Exception(f"GET {path} failed: {r.status_code} {r.text}")

    return r.json()


def marz_put(path: str, payload: dict):
    t = get_token()
    headers = {
        "Authorization": f"Bearer {t}",
        "Content-Type": "application/json"
    }
    url = f"{MARZBAN_BASE}{path}"

    r = requests.put(url, json=payload, headers=headers, verify=VERIFY_SSL)
    if r.status_code == 401:
        # retry if expired
        with _token_lock:
            _token_cache["exp"] = 0
        t = get_token()
        headers["Authorization"] = f"Bearer {t}"
        r = requests.put(url, json=payload, headers=headers, verify=VERIFY_SSL)

    if r.status_code not in (200, 204):
        raise Exception(f"PUT {path} failed: {r.status_code} {r.text}")

    return True


# ------------ FASTAPI ------------
app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


class GrantRequest(BaseModel):
    add_bytes: int
    add_seconds: int


def to_int(v):
    try:
        return int(v)
    except:
        return 0


@app.get("/emergency/{username}")
def check(username: str):
    store = load_store()
    rec = store.get(username)

    if not rec:
        return {"username": username, "used": False}

    try:
        user = marz_get(f"/api/user/{username}")
    except Exception as e:
        return {"username": username, "used": True, "error": str(e)}

    cur_limit = to_int(user.get("data_limit"))
    cur_exp = to_int(user.get("expire"))
    old_limit = to_int(rec.get("saved_data_limit"))
    old_exp = to_int(rec.get("saved_expire"))

    if cur_limit > old_limit or cur_exp > old_exp:
        store.pop(username, None)
        save_store(store)
        return {"username": username, "used": False, "renewed": True}

    return {"username": username, "used": True, "record": rec}


@app.post("/emergency/{username}/grant")
def grant(username: str, body: GrantRequest, req: Request):
    referer = req.headers.get("referer", "")
    origin = req.headers.get("origin", "")
    if not referer and not origin:
        raise HTTPException(403, "Forbidden")

    store = load_store()
    if store.get(username, {}).get("used"):
        raise HTTPException(400, "Already used")

    try:
        user = marz_get(f"/api/user/{username}")
    except Exception as e:
        raise HTTPException(500, str(e))

    now = int(time.time())
    cur_limit = to_int(user.get("data_limit"))
    cur_exp = to_int(user.get("expire"))

    new_limit = cur_limit + body.add_bytes
    base = cur_exp if cur_exp > now else now
    new_exp = base + body.add_seconds

    marz_put(f"/api/user/{username}", {
        "data_limit": new_limit,
        "expire": new_exp
    })

    store[username] = {
        "used": True,
        "granted_at": now,
        "saved_data_limit": cur_limit,
        "saved_expire": cur_exp,
        "granted_data_limit": new_limit,
        "granted_expire": new_exp
    }
    save_store(store)

    return {"ok": True, "username": username}
