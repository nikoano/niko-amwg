#!/usr/bin/env python3
"""Управление клиентами сервера AmneziaWG 3.x (amwg).

Утилита работает поверх штатного `awg` из amneziawg-tools: своей криптографии и
своего демона тут нет, изменения применяются через `awg syncconf` — на живом
интерфейсе, без разрыва чужих сессий и без рестарта юнита.

Источники правды раздельные, и это осознанно:

    /etc/amnezia/amneziawg/<iface>.conf   секция [Interface] — параметры обфускации.
                                          Её пишет установщик, утилита её только ЧИТАЕТ
                                          и перекладывает в клиентские конфиги;
    .../amwg/state.json                 клиенты: ключи, ip, вкл/выкл, заметки.
                                          Из него генерируются все [Peer] в conf;
    .../amwg/traffic.json               накопленный трафик и последний хендшейк.
                                          Счётчики ядра обнуляются при рестарте
                                          интерфейса, поэтому их складывает `amwg poll`.

Секции [Peer] в conf ПЕРЕГЕНЕРИРУЮТСЯ целиком при каждом изменении: править их
руками бессмысленно, правки перетрутся. Секция [Interface] не трогается никогда.

Использование (всё то же самое есть в меню — запусти без аргументов):

    amwg                              меню: стрелки/цифры/пробел/Enter/q
    amwg list [-v] [--json]           клиенты: ip, статус, хендшейк, трафик
    amwg add <имя> [--note ...]       новый клиент, печатает его конфиг
    amwg show <имя> [--qr] [--png ф] [--out ф]
    amwg disable <имя> [...] | enable <имя> [...]
    amwg rm <имя> [...] [--yes]
    amwg stats [<имя>] [--watch [сек]] [--json]
    amwg poll                         копит трафик (юнит amwg-poll.timer)
    amwg server [--endpoint host:port] [--dns ...] [--mtu N] [--keepalive N]
    amwg apply                        перегенерить [Peer] и синкнуть на интерфейс
    amwg init ...                     первичный state.json (зовёт установщик)

Всё требует root: конфиг интерфейса и ключи лежат 0600.

Клиентские приватные ключи ХРАНЯТСЯ на сервере (state.json, 0600) — иначе «покажи
ещё раз конфиг или qr» невозможен в принципе. Кому это не подходит — `amwg add
--pubkey <ключ клиента>`: тогда приватный ключ генерит клиент, сервер его не видит,
но и показать конфиг целиком уже не сможет.

Зависимостей нет: только стандартная библиотека, `awg` и (для qr) `qrencode`.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

CONF_DIR = os.environ.get("AMWG_CONF_DIR", "/etc/amnezia/amneziawg")
STATE_DIR = os.environ.get("AMWG_STATE_DIR", os.path.join(CONF_DIR, "amwg"))
STATE_FILE = os.path.join(STATE_DIR, "state.json")
TRAFFIC_FILE = os.path.join(STATE_DIR, "traffic.json")
AWG = os.environ.get("AMWG_AWG_BIN", "awg")
AWG_QUICK = os.environ.get("AMWG_AWG_QUICK_BIN", "awg-quick")

# Параметры обфускации, которые ОБЯЗАНЫ совпадать у сервера и клиента: копируются
# в клиентский конфиг как есть. Список из README ядерного модуля — «All parameters
# must be the same between Client and Server, except for Jc, Jmin, and Jmax».
COPY_KEYS = (
    "S1", "S2", "S3", "S4",
    "H1", "H2", "H3", "H4",
    "I1", "I2", "I3", "I4", "I5",
    "HeaderProtectionKey", "ContentPaddingAddition",
    "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime",
    "KeepaliveTimeout", "MaxHandshakeAttempts",
    "RandomTrailers", "DisableCookies",
)
# А эти у каждого клиента свои — в этом и смысл мусорных пакетов
JUNK_KEYS = ("Jc", "Jmin", "Jmax")

# Имя клиента уезжает в комментарий conf, в ключ json и в подсказки меню:
# буквы (в том числе русские), цифры, точка, подчёркивание, дефис — и всё
NAME_RE = re.compile(r"^\w[\w.-]{0,30}$", re.UNICODE)
ONLINE_WINDOW_SEC = 180          # хендшейк раз в ~2 минуты, 3 минуты — уже «отвалился»


class AppError(Exception):
    """Ожидаемая ошибка: печатается красным без трейсбека."""


# ============================================================================
#  Консоль
# ============================================================================
_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(text: str, code: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _COLOR else text


def red(t: str) -> str:
    return _c(t, "31")


def green(t: str) -> str:
    return _c(t, "32")


def yellow(t: str) -> str:
    return _c(t, "33")


def cyan(t: str) -> str:
    return _c(t, "36")


def grey(t: str) -> str:
    return _c(t, "90")


def bold(t: str) -> str:
    return _c(t, "1")


_ANSI = re.compile(r"\033\[[0-9;]*m")


def visible_len(text: str) -> int:
    return len(_ANSI.sub("", text))


def render_table(columns: list[str], rows: list[list[str]], indent: str = "  ") -> str:
    """Ширина колонки считается по ВИДИМОЙ длине: крашеная ячейка иначе тянет
    колонку на десяток невидимых символов, и таблица разъезжается."""
    if not rows:
        return indent + grey("пусто")
    widths = [visible_len(c) for c in columns]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], visible_len(cell))

    def line(cells: list[str]) -> str:
        return indent + " | ".join(
            cell + " " * max(0, widths[i] - visible_len(cell)) for i, cell in enumerate(cells))

    out = [line(columns), indent + "-+-".join("-" * w for w in widths)]
    out.extend(line(r) for r in rows)
    return "\n".join(out)


def human_bytes(value: int) -> str:
    step = 1024.0
    num = float(value)
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if num < step or unit == "ТБ":
            return f"{num:.0f} {unit}" if unit == "Б" else f"{num:.1f} {unit}"
        num /= step
    return f"{num:.1f} ТБ"


def human_ago(epoch: int) -> str:
    if not epoch:
        return "никогда"
    delta = int(time.time()) - int(epoch)
    if delta < 0:
        delta = 0
    if delta < 60:
        return f"{delta} с назад"
    if delta < 3600:
        return f"{delta // 60} мин назад"
    if delta < 86400:
        return f"{delta // 3600} ч назад"
    return f"{delta // 86400} д назад"


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().replace(microsecond=0).isoformat()


# ============================================================================
#  Запуск внешних команд
# ============================================================================
def run(args: list[str], *, input_text: str | None = None, check: bool = True) -> str:
    try:
        proc = subprocess.run(args, input=input_text, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError as e:
        raise AppError(f"не найдено: {args[0]} ({e})") from e
    if check and proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise AppError(f"{' '.join(args)} вернул {proc.returncode}: {err}")
    return (proc.stdout or "").strip()


def genkey() -> str:
    return run([AWG, "genkey"])


def pubkey(private: str) -> str:
    return run([AWG, "pubkey"], input_text=private + "\n")


def genpsk() -> str:
    return run([AWG, "genpsk"])


def iface_is_up(iface: str) -> bool:
    out = run([AWG, "show", "interfaces"], check=False)
    return iface in out.split()


def require_root() -> None:
    if os.geteuid() != 0:
        raise AppError("нужен root: конфиг и ключи лежат 0600")


# ============================================================================
#  Состояние
# ============================================================================
DEFAULT_STATE = {
    "iface": "awg0",
    "endpoint": "",
    "subnet": "10.9.9.0/24",
    "server_ip": "10.9.9.1",
    "server_pubkey": "",
    "dns": ["1.1.1.1", "1.0.0.1"],
    "client_mtu": 1280,
    "keepalive": 25,
    "allowed_ips": "0.0.0.0/0, ::/0",
    "clients": {},
}


def read_json(path: str, default: dict) -> dict:
    if not os.path.exists(path):
        return json.loads(json.dumps(default))
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise AppError(f"не читается {path}: {e}") from e


def write_secret(path: str, text: str) -> None:
    """Атомарная запись в тот же каталог + 0600: в файле приватные ключи, и
    подсунуть их наружу через полузаписанный/мирочитаемый файл нельзя."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def load_state() -> dict:
    if not os.path.exists(STATE_FILE):
        raise AppError(f"нет {STATE_FILE} — сервер ещё не разложен, запусти install.sh")
    state = read_json(STATE_FILE, DEFAULT_STATE)
    for key, value in DEFAULT_STATE.items():
        state.setdefault(key, value)
    return state


def save_state(state: dict) -> None:
    write_secret(STATE_FILE, json.dumps(state, ensure_ascii=False, indent=2) + "\n")


def conf_path(state: dict) -> str:
    return os.path.join(CONF_DIR, f"{state['iface']}.conf")


def server_pubkey(state: dict) -> str:
    """Публичный ключ сервера считается из conf КАЖДЫЙ раз, а не берётся из
    state: конфиг интерфейса могли перевыпустить (install.sh --force-config), и
    кеш тогда молча раздавал бы клиентам ключ от старого сервера. В state он
    лежит только чтобы было видно глазами."""
    interface, _ = parse_conf(conf_path(state))
    private = dict(interface).get("PrivateKey")
    if not private:
        raise AppError(f"в {conf_path(state)} нет PrivateKey")
    return pubkey(private)


# ============================================================================
#  Конфиг интерфейса
# ============================================================================
def parse_conf(path: str) -> tuple[list[tuple[str, str]], str]:
    """Возвращает ключи секции [Interface] и её ТЕКСТ как есть.

    Текст сохраняется дословно (вместе с комментариями и PostUp), потому что при
    перезаписи peer'ов секция интерфейса кладётся обратно байт в байт: там ключи,
    правила фаервола и параметры обфускации, генерить которые заново нельзя.
    """
    if not os.path.exists(path):
        raise AppError(f"нет конфига интерфейса {path}")
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    head: list[str] = []
    pairs: list[tuple[str, str]] = []
    in_interface = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            if stripped.lower() == "[interface]":
                in_interface = True
                head.append(line)
                continue
            break
        if in_interface:
            head.append(line)
            body = stripped.split("#", 1)[0].strip()
            if "=" in body:
                key, value = body.split("=", 1)
                pairs.append((key.strip(), value.strip()))
        else:
            head.append(line)          # шапка до [Interface] — комментарии установщика
    return pairs, "\n".join(head).rstrip() + "\n"


def render_peer(name: str, client: dict) -> str:
    return "\n".join([
        "[Peer]",
        f"# amwg: {name}",
        f"PublicKey = {client['pubkey']}",
        f"PresharedKey = {client['psk']}",
        f"AllowedIPs = {client['ip']}/32",
        "",
    ])


def write_conf(state: dict) -> str:
    """Перекладывает всех включённых клиентов в conf. Выключенные не пишутся
    вообще — для ядра «выключен» и «нет такого пира» это одно и то же."""
    path = conf_path(state)
    _, head = parse_conf(path)
    peers = [render_peer(name, client)
             for name, client in sorted(state["clients"].items())
             if client.get("enabled", True)]
    write_secret(path, head + "\n" + "\n".join(peers))
    return path


def sync_live(state: dict) -> bool:
    """Применяет conf на живой интерфейс без разрыва чужих сессий.

    `awg syncconf` хочет ФАЙЛ, поэтому stripped-конфиг кладётся во временный файл
    на tmpfs (/run) с 0600 и сразу удаляется: в нём приватный ключ сервера.
    """
    iface = state["iface"]
    if not iface_is_up(iface):
        return False
    stripped = run([AWG_QUICK, "strip", iface])
    tmp_dir = "/run" if os.path.isdir("/run") else tempfile.gettempdir()
    fd, tmp = tempfile.mkstemp(dir=tmp_dir, prefix="amwg-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(stripped + "\n")
        run([AWG, "syncconf", iface, tmp])
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return True


def apply(state: dict) -> None:
    save_state(state)
    write_conf(state)
    if sync_live(state):
        print(green(f"применено на живой интерфейс {state['iface']}"))
    else:
        print(yellow(f"интерфейс {state['iface']} не поднят — конфиг записан, "
                     f"поднимется вместе с ним"))


# ============================================================================
#  Клиенты
# ============================================================================
def check_name(name: str) -> str:
    if not NAME_RE.match(name):
        raise AppError(f"негодное имя '{name}': буквы, цифры, . _ -, до 31 символа")
    return name


def get_client(state: dict, name: str) -> dict:
    client = state["clients"].get(name)
    if client is None:
        known = ", ".join(sorted(state["clients"])) or "их пока нет"
        raise AppError(f"нет клиента '{name}' (есть: {known})")
    return client


def next_ip(state: dict) -> str:
    net = ipaddress.ip_network(state["subnet"], strict=False)
    busy = {ipaddress.ip_address(state["server_ip"])}
    busy.update(ipaddress.ip_address(c["ip"]) for c in state["clients"].values())
    for host in net.hosts():
        if host not in busy:
            return str(host)
    raise AppError(f"в {state['subnet']} кончились адреса — расширяй подсеть")


def rnd(lo: int, hi: int) -> int:
    return lo + int.from_bytes(os.urandom(4), "big") % (hi - lo + 1)


def add_client(state: dict, name: str, note: str = "", ip: str = "",
               client_pubkey: str = "") -> dict:
    check_name(name)
    if name in state["clients"]:
        raise AppError(f"клиент '{name}' уже есть")
    if ip:
        addr = ipaddress.ip_address(ip)
        if addr not in ipaddress.ip_network(state["subnet"], strict=False):
            raise AppError(f"{ip} вне подсети {state['subnet']}")
        if any(c["ip"] == ip for c in state["clients"].values()):
            raise AppError(f"{ip} уже занят")
    else:
        ip = next_ip(state)

    if client_pubkey:
        private = ""
        public = client_pubkey
    else:
        private = genkey()
        public = pubkey(private)

    client = {
        "ip": ip,
        "privkey": private,
        "pubkey": public,
        "psk": genpsk(),
        # мусорные пакеты у каждого свои: это единственное, что можно и нужно
        # разводить по клиентам, всё остальное обязано совпадать с сервером
        "jc": rnd(4, 12),
        "jmin": rnd(8, 24),
        "jmax": rnd(64, 320),
        "created": now_iso(),
        "enabled": True,
        "note": note,
    }
    state["clients"][name] = client
    return client


def client_config(state: dict, name: str) -> str:
    """Клиентский .conf: обфускация копируется из серверного один в один."""
    client = get_client(state, name)
    if not client.get("privkey"):
        raise AppError(f"у '{name}' нет приватного ключа (заводился с --pubkey) — "
                       f"конфиг соберёт сам клиент, ему нужны только параметры "
                       f"ниже: amwg server")
    pairs, _ = parse_conf(conf_path(state))
    server = dict(pairs)

    lines = [
        f"# amwg: {name}, создан {client['created']}",
        "[Interface]",
        f"PrivateKey = {client['privkey']}",
        f"Address = {client['ip']}/32",
    ]
    dns = state.get("dns") or []
    if dns:
        lines.append(f"DNS = {', '.join(dns)}")
    if state.get("client_mtu"):
        lines.append(f"MTU = {state['client_mtu']}")
    lines.append("")
    lines += [f"Jc = {client['jc']}", f"Jmin = {client['jmin']}", f"Jmax = {client['jmax']}"]
    for key in COPY_KEYS:
        if key in server:
            lines.append(f"{key} = {server[key]}")
    lines += [
        "",
        "[Peer]",
        f"PublicKey = {server_pubkey(state)}",
        f"PresharedKey = {client['psk']}",
        f"Endpoint = {state['endpoint']}",
        f"AllowedIPs = {state['allowed_ips']}",
        f"PersistentKeepalive = {state['keepalive']}",
        "",
    ]
    return "\n".join(lines)


# ============================================================================
#  Трафик и последнее подключение
# ============================================================================
def dump_peers(state: dict) -> dict[str, dict]:
    """`awg show <if> dump` по публичному ключу пира.

    Первая строка — сам интерфейс, дальше по строке на пира:
    pubkey, psk, endpoint, allowed-ips, latest-handshake, rx, tx, keepalive.
    """
    iface = state["iface"]
    if not iface_is_up(iface):
        return {}
    out = run([AWG, "show", iface, "dump"], check=False)
    peers: dict[str, dict] = {}
    for line in out.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        peers[parts[0]] = {
            "endpoint": "" if parts[2] == "(none)" else parts[2],
            "handshake": int(parts[4] or 0),
            "rx": int(parts[5] or 0),
            "tx": int(parts[6] or 0),
        }
    return peers


def load_traffic() -> dict:
    return read_json(TRAFFIC_FILE, {"peers": {}})


def poll_traffic(state: dict) -> dict:
    """Складывает счётчики ядра в накопительные.

    Ядро считает трафик от последнего поднятия интерфейса (а пир, которого сняли
    и вернули, начинает с нуля), поэтому «всего за всё время» без такого сложения
    не существует. Уменьшилось по сравнению с прошлым разом — значит был сброс,
    и текущее значение добавляется целиком.
    """
    traffic = load_traffic()
    peers = traffic.setdefault("peers", {})
    live = dump_peers(state)
    changed = False
    for key, cur in live.items():
        rec = peers.setdefault(key, {"rx_total": 0, "tx_total": 0, "rx_last": 0,
                                     "tx_last": 0, "handshake": 0, "endpoint": ""})
        for field in ("rx", "tx"):
            last = rec.get(f"{field}_last", 0)
            delta = cur[field] - last if cur[field] >= last else cur[field]
            rec[f"{field}_total"] = rec.get(f"{field}_total", 0) + delta
            rec[f"{field}_last"] = cur[field]
        if cur["handshake"] > rec.get("handshake", 0):
            rec["handshake"] = cur["handshake"]
        if cur["endpoint"]:
            rec["endpoint"] = cur["endpoint"]
        rec["updated"] = int(time.time())
        changed = True
    if changed:
        traffic["updated"] = int(time.time())
        write_secret(TRAFFIC_FILE, json.dumps(traffic, ensure_ascii=False, indent=2) + "\n")
    return traffic


def client_rows(state: dict, traffic: dict | None = None,
                live: dict | None = None) -> list[dict]:
    """Сводка по каждому клиенту: живые счётчики + накопленные + статус."""
    traffic = traffic if traffic is not None else load_traffic()
    live = live if live is not None else dump_peers(state)
    up = iface_is_up(state["iface"])
    saved = traffic.get("peers", {})
    rows = []
    for name, client in sorted(state["clients"].items()):
        key = client["pubkey"]
        cur = live.get(key)
        rec = saved.get(key, {})
        handshake = max(int(rec.get("handshake", 0)), cur["handshake"] if cur else 0)
        rx_session = cur["rx"] if cur else 0
        tx_session = cur["tx"] if cur else 0
        # накопленное = сложенное поллером + то, что натикало после его прохода
        rx_total = rec.get("rx_total", 0) + max(0, rx_session - rec.get("rx_last", 0))
        tx_total = rec.get("tx_total", 0) + max(0, tx_session - rec.get("tx_last", 0))
        rows.append({
            "name": name,
            "ip": client["ip"],
            "enabled": client.get("enabled", True),
            # «онлайн» только на живом интерфейсе: свежий хендшейк из traffic.json
            # переживает падение интерфейса и врал бы про подключение
            "online": up and bool(handshake) and (time.time() - handshake) < ONLINE_WINDOW_SEC,
            "handshake": handshake,
            "endpoint": (cur or {}).get("endpoint") or rec.get("endpoint", ""),
            "rx": rx_session, "tx": tx_session,
            "rx_total": rx_total, "tx_total": tx_total,
            "created": client.get("created", ""),
            "note": client.get("note", ""),
            "pubkey": key,
            "in_kernel": cur is not None,
            "iface_up": up,
        })
    return rows


def status_cell(row: dict) -> str:
    """«не в ядре» — это включённый клиент, которого нет на живом интерфейсе:
    conf и ядро разъехались, лечится `amwg apply`. Лежащий интерфейс — не тот
    случай, там в ядре нет вообще никого."""
    if not row["enabled"]:
        return grey("выключен")
    if not row["iface_up"]:
        return grey("интерфейс лежит")
    if row["online"]:
        return green("онлайн")
    return "ждёт" if row["in_kernel"] else yellow("не в ядре")


# ============================================================================
#  QR и выдача конфига
# ============================================================================
def qr_available() -> bool:
    return shutil.which("qrencode") is not None


def print_qr(text: str) -> None:
    if not qr_available():
        raise AppError("нет qrencode: apt install -y qrencode")
    size = len(text.encode())
    if size > 1200:
        print(yellow(f"конфиг на {size} байт — qr выйдет плотным, телефон может "
                     f"не взять с экрана; тогда --png файл"))
    proc = subprocess.run(["qrencode", "-t", "ANSIUTF8", "-l", "L", "-m", "1", "-o", "-"],
                          input=text, text=True)
    if proc.returncode != 0:
        raise AppError("qrencode не смог: конфиг слишком большой для qr-кода")


def save_qr_png(text: str, path: str) -> None:
    if not qr_available():
        raise AppError("нет qrencode: apt install -y qrencode")
    run(["qrencode", "-t", "PNG", "-l", "L", "-s", "6", "-o", path], input_text=text)
    os.chmod(path, 0o600)


def show_client(state: dict, name: str, *, qr: bool = False, png: str = "",
                out: str = "") -> None:
    """Текст конфига печатается, когда не просили ничего другого: голый `show`
    должен что-то показать, а `show --png x.png` — не сыпать ключами в терминал."""
    text = client_config(state, name)
    if not (out or png or qr):
        print(bold(f"# {name}"))
        print(text)
    if qr:
        print_qr(text)
    if out:
        write_secret(out, text)
        print(green(f"конфиг записан: {out} (0600)"))
    if png:
        save_qr_png(text, png)
        print(green(f"qr записан: {png} (0600)"))


# ============================================================================
#  Печать: список, статистика, сервер
# ============================================================================
def print_list(state: dict, verbose: bool = False, numbered: bool = False) -> list[dict]:
    rows = client_rows(state)
    columns = ["имя", "ip", "статус", "последний хендшейк", "принято", "отдано"]
    if verbose:
        columns += ["всего ↓", "всего ↑", "endpoint", "создан", "заметка"]
    if numbered:
        columns = ["№"] + columns

    table_rows = []
    for i, row in enumerate(rows, start=1):
        cells = [row["name"], row["ip"], status_cell(row), human_ago(row["handshake"]),
                 human_bytes(row["rx"]), human_bytes(row["tx"])]
        if verbose:
            cells += [human_bytes(row["rx_total"]), human_bytes(row["tx_total"]),
                      row["endpoint"] or "-", (row["created"] or "-")[:19],
                      row["note"] or "-"]
        table_rows.append(([str(i)] if numbered else []) + cells)

    print(render_table(columns, table_rows))
    if rows and not verbose:
        print(grey("  принято/отдано — с последнего подъёма интерфейса; всего — -v"))
    return rows


def print_stats(state: dict, name: str = "") -> None:
    rows = client_rows(state)
    if name:
        get_client(state, name)
        rows = [r for r in rows if r["name"] == name]
    for row in rows:
        head = f"{bold(row['name'])} ({row['ip']})  {status_cell(row)}"
        print(head)
        print(f"  последний хендшейк : {human_ago(row['handshake'])}"
              + (f"  ({datetime.fromtimestamp(row['handshake']).replace(microsecond=0)})"
                 if row["handshake"] else ""))
        print(f"  адрес клиента      : {row['endpoint'] or '-'}")
        print(f"  сессия             : ↓ {human_bytes(row['rx'])}  ↑ {human_bytes(row['tx'])}")
        print(f"  всего              : ↓ {human_bytes(row['rx_total'])}  "
              f"↑ {human_bytes(row['tx_total'])}")
        if row["note"]:
            print(f"  заметка            : {row['note']}")
        print()


def watch_stats(state: dict, interval: float = 2.0) -> None:
    """Живая таблица со скоростью. Ctrl+C — выход."""
    prev: dict[str, tuple[int, int]] = {}
    try:
        while True:
            rows = client_rows(state)
            table = []
            for row in rows:
                was = prev.get(row["name"])
                if was:
                    rx_rate = max(0, row["rx_total"] - was[0]) / interval
                    tx_rate = max(0, row["tx_total"] - was[1]) / interval
                    speed = f"{human_bytes(int(rx_rate))}/с  {human_bytes(int(tx_rate))}/с"
                else:
                    speed = grey("...")
                prev[row["name"]] = (row["rx_total"], row["tx_total"])
                table.append([row["name"], row["ip"], status_cell(row),
                              human_ago(row["handshake"]), speed,
                              f"{human_bytes(row['rx_total'])} / {human_bytes(row['tx_total'])}"])
            sys.stdout.write("\033[H\033[2J")
            print(bold(f"awg {state['iface']} · {datetime.now().strftime('%H:%M:%S')}"
                       f" · обновление раз в {interval:g} с · Ctrl+C — выход"))
            print(render_table(["имя", "ip", "статус", "хендшейк", "скорость ↓ / ↑",
                                "всего ↓ / ↑"], table))
            time.sleep(interval)
    except KeyboardInterrupt:
        print()


def print_server(state: dict) -> None:
    path = conf_path(state)
    pairs, _ = parse_conf(path)
    server = dict(pairs)
    up = iface_is_up(state["iface"])
    tools = run([AWG, "--version"], check=False) or "?"
    module = run(["modinfo", "-F", "version", "amneziawg"], check=False) or "нет (userspace?)"

    print(bold(f"интерфейс {state['iface']}") + "  " +
          (green("поднят") if up else red("лежит")))
    print(f"  конфиг        : {path}")
    print(f"  endpoint      : {state['endpoint']}")
    print(f"  порт          : {server.get('ListenPort', '?')}/udp")
    print(f"  подсеть       : {state['subnet']}  (сервер {state['server_ip']})")
    print(f"  клиентам      : DNS {', '.join(state['dns']) or '-'}, MTU "
          f"{state['client_mtu']}, keepalive {state['keepalive']}, "
          f"AllowedIPs {state['allowed_ips']}")
    print(f"  клиентов      : {len(state['clients'])} "
          f"(включённых {sum(1 for c in state['clients'].values() if c.get('enabled', True))})")
    print(f"  awg           : {tools}")
    print(f"  модуль ядра   : {module}")
    print()
    print(bold("обфускация (в клиентские конфиги копируется как есть)"))
    for key in JUNK_KEYS:
        if key in server:
            print(f"  {key:<22}: {server[key]}  " + grey("(у каждого клиента свой)"))
    for key in COPY_KEYS:
        if key not in server:
            continue
        value = server[key]
        if key == "HeaderProtectionKey":
            value = value[:6] + "…" + value[-4:]
        print(f"  {key:<22}: {value}")
    missing = [k for k in ("HeaderProtectionKey", "RandomTrailers", "DisableCookies")
               if k not in server]
    if missing:
        print(yellow(f"  нет параметров 3.x: {', '.join(missing)} — конфиг из старого "
                     f"поколения?"))


# ============================================================================
#  Интерактив: выбор стрелками, цифрами, пробелом
# ============================================================================
UP, DOWN, ENTER, SPACE, CANCEL, HOME, END, BACKSPACE = (
    "up", "down", "enter", "space", "cancel", "home", "end", "backspace")

# 'q' в русской раскладке — 'й': переключать раскладку ради выхода никто не будет
_CANCEL_CHARS = ("q", "Q", "й", "Й", "\x03", "\x04")


def interactive_ok() -> bool:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return False
    try:
        import termios  # noqa: F401
        import tty      # noqa: F401
    except ImportError:
        return False
    return True


class _Keys:
    """Режим терминала держится на всё меню, а не включается на каждую клавишу:
    иначе нажатое между чтениями попадает в канонический буфер и всплывает эхом
    посреди списка. Читаем сырым os.read: текстовый sys.stdin затягивает в свой
    буфер всю escape-последовательность стрелки целиком."""

    def __init__(self) -> None:
        self.fd = sys.stdin.fileno()
        self.saved = None

    def __enter__(self) -> "_Keys":
        import termios
        import tty
        self.saved = termios.tcgetattr(self.fd)
        tty.setcbreak(self.fd)
        attrs = termios.tcgetattr(self.fd)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        return self

    def __exit__(self, *exc) -> None:
        import termios
        if self.saved is not None:
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.saved)

    def _char(self, timeout: float | None = None) -> str:
        import select
        if timeout is not None and not select.select([self.fd], [], [], timeout)[0]:
            return ""
        raw = os.read(self.fd, 1)
        if not raw:
            return ""
        lead = raw[0]                       # кириллица приезжает многобайтовой
        extra = (1 if 0xC0 <= lead < 0xE0 else
                 2 if 0xE0 <= lead < 0xF0 else
                 3 if lead >= 0xF0 else 0)
        while extra > 0:
            raw += os.read(self.fd, 1)
            extra -= 1
        return raw.decode("utf-8", "replace")

    def read(self) -> str:
        ch = self._char()
        if ch == "\x1b":
            # Esc сама по себе и Esc как начало стрелки различаются только паузой
            nxt = self._char(0.05)
            if nxt == "":
                return CANCEL
            if nxt not in ("[", "O"):
                return ""
            code = self._char()
            if code.isdigit():              # '\x1b[1~' (Home), '\x1b[4~' (End)
                tail = code
                while not tail.endswith("~") and len(tail) < 4:
                    more = self._char(0.05)
                    if not more:
                        break
                    tail += more
                return {"1~": HOME, "7~": HOME, "4~": END, "8~": END}.get(tail, "")
            return {"A": UP, "B": DOWN, "H": HOME, "F": END}.get(code, "")
        if ch in ("\r", "\n"):
            return ENTER
        if ch == " ":
            return SPACE
        if ch in ("\x7f", "\b"):
            return BACKSPACE
        if ch in _CANCEL_CHARS:
            return CANCEL
        if ch.isdigit():
            return ch
        return ""


class _Screen:
    """Перерисовка блока на месте: печатаем, потом поднимаем курсор и стираем.
    Строки подрезаются по ширине окна СПЕЦИАЛЬНО — перенос длинной строки сбил бы
    счётчик строк, и перерисовка поехала бы вверх по экрану."""

    def __init__(self) -> None:
        self.lines = 0

    def draw(self, lines: list[str]) -> None:
        width = max(20, shutil.get_terminal_size((100, 25)).columns - 1)
        if self.lines:
            sys.stdout.write(f"\033[{self.lines}A\033[0J")
        sys.stdout.write("\n".join(_fit(line, width) for line in lines) + "\n")
        sys.stdout.flush()
        self.lines = len(lines)

    def clear(self) -> None:
        if self.lines:
            sys.stdout.write(f"\033[{self.lines}A\033[0J")
            sys.stdout.flush()
            self.lines = 0


def _fit(line: str, width: int) -> str:
    if visible_len(line) <= width:
        return line
    out, shown, i = [], 0, 0
    while i < len(line) and shown < width - 1:
        if line[i] == "\033":
            end = line.find("m", i)
            if end == -1:
                break
            out.append(line[i:end + 1])
            i = end + 1
            continue
        out.append(line[i])
        shown += 1
        i += 1
    return "".join(out) + "…\033[0m"


def pick(labels: list[str], title: str = "", multi: bool = False,
         start: int = 0) -> list[int] | None:
    """Выбор из списка. Возвращает 0-based индексы, None — отмена (q/Esc/Ctrl+C).

    Стрелки — ходить, цифры — прыгнуть на номер (набирается многозначный),
    пробел — отметить (в multi), Enter — подтвердить.
    """
    if not labels:
        return None
    if not interactive_ok():
        return _pick_by_number(labels, title, multi)

    pos = min(max(start, 0), len(labels) - 1)
    checked: set[int] = set()
    typed = ""
    offset = 0
    screen = _Screen()
    sys.stdout.write("\033[?25l")           # курсор скрыть: мешает читать список
    try:
        with _Keys() as keys:
            while True:
                lines, offset = _render(labels, checked, pos, title, offset, multi, typed)
                screen.draw(lines)
                try:
                    key = keys.read()
                except KeyboardInterrupt:
                    return None
                if key == CANCEL:
                    return None
                if key.isdigit():
                    candidate = typed + key
                    if 1 <= int(candidate) <= len(labels):
                        typed, pos = candidate, int(candidate) - 1
                    elif 1 <= int(key) <= len(labels):
                        typed, pos = key, int(key) - 1
                    continue
                if key == BACKSPACE:
                    typed = typed[:-1]
                    continue
                typed = ""
                if key == ENTER:
                    return sorted(checked) if multi and checked else [pos]
                if key == SPACE and multi:
                    checked.symmetric_difference_update({pos})
                elif key == SPACE:
                    return [pos]
                elif key == UP:
                    pos = (pos - 1) % len(labels)
                elif key == DOWN:
                    pos = (pos + 1) % len(labels)
                elif key == HOME:
                    pos = 0
                elif key == END:
                    pos = len(labels) - 1
    finally:
        sys.stdout.write("\033[?25h")       # курсор вернуть, даже если рухнули
        sys.stdout.flush()
        screen.clear()


def _render(labels: list[str], checked: set[int], pos: int, title: str,
            offset: int, multi: bool, typed: str) -> tuple[list[str], int]:
    """Строки блока и новый сдвиг прокрутки. Список длиннее окна не отдаётся
    целиком: терминал бы его подскроллил, и «поднять курсор на N строк» уехало бы
    не туда — вместо этого рисуется окно вокруг курсора."""
    body = []
    for i, label in enumerate(labels):
        num = grey(f"{i + 1:>2}.")
        box = (green("[x]") if i in checked else "[ ]") + " " if multi else ""
        if i == pos:
            body.append(cyan("  › ") + num + " " + box + cyan(label))
        else:
            body.append(f"    {num} {box}{label}")

    avail = shutil.get_terminal_size((100, 25)).lines - 3 - (1 if title else 0)
    if len(body) <= max(avail, 1):
        view = body
        offset = 0
    else:
        height = max(1, avail - 2)
        offset = max(0, min(offset, len(body) - height))
        if pos < offset:
            offset = pos
        elif pos >= offset + height:
            offset = pos - height + 1
        above, below = offset, len(body) - offset - height
        view = ([grey(f"  ↑ ещё {above}") if above else ""]
                + body[offset:offset + height]
                + [grey(f"  ↓ ещё {below}") if below else ""])

    hint = "↑↓ или цифры — выбор, " + ("пробел — отметить, " if multi else "")
    hint += "Enter — ок, q — назад"
    if typed:
        hint = f"набрано: {typed}   " + hint
    return ([bold(title)] if title else []) + view + [grey("  " + hint)], offset


def _pick_by_number(labels: list[str], title: str, multi: bool) -> list[int] | None:
    """Запасной путь без настоящей консоли (пайп, ssh без tty): номера руками."""
    if title:
        print(bold(title))
    for i, label in enumerate(labels, start=1):
        print(f"  [{i}] {label}")
    question = ("Номера через пробел (Enter — отмена): " if multi
                else f"Номер [1-{len(labels)}] (Enter — отмена): ")
    try:
        raw = input(question).split()
    except (EOFError, KeyboardInterrupt):
        return None
    if not raw:
        return None
    chosen = []
    for token in raw if multi else raw[:1]:
        if not (token.isdigit() and 1 <= int(token) <= len(labels)):
            print(red(f"  негодный номер: {token}"))
            return None
        if int(token) - 1 not in chosen:
            chosen.append(int(token) - 1)
    return chosen


def ask(prompt: str, default: str = "") -> str:
    try:
        raw = input(prompt).strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return ""
    return raw or default


def confirm(prompt: str) -> bool:
    """Дефолт «нет» осознанный: этим вопросом закрывается удаление клиента."""
    return ask(f"{prompt} [y/N]: ").lower() in ("y", "yes", "д", "да")


# ============================================================================
#  Меню
# ============================================================================
def pause() -> None:
    ask(grey("Enter — назад "))


def menu_title(state: dict) -> str:
    rows = client_rows(state)
    online = sum(1 for r in rows if r["online"])
    up = green("поднят") if iface_is_up(state["iface"]) else red("лежит")
    return (f"AmneziaWG · {state['iface']} · {up} · клиентов {len(rows)} "
            f"(онлайн {online}) · {state['endpoint']}")


def menu_pick_clients(state: dict, title: str, multi: bool = False) -> list[str]:
    rows = client_rows(state)
    if not rows:
        print(yellow("клиентов пока нет"))
        return []
    labels = [f"{r['name']:<16} {r['ip']:<12} {status_cell(r):<20} "
              f"{human_ago(r['handshake'])}" for r in rows]
    chosen = pick(labels, title, multi=multi)
    return [rows[i]["name"] for i in (chosen or [])]


def menu_add(state: dict) -> None:
    name = ask("имя клиента (пусто — отмена): ")
    if not name:
        return
    note = ask("заметка (можно пусто): ")
    client = add_client(state, name, note=note)
    apply(state)
    print(green(f"добавлен {name} → {client['ip']}"))
    show_client(state, name, qr=confirm("показать qr"))
    pause()


def menu_share(state: dict) -> None:
    names = menu_pick_clients(state, "чей конфиг показать")
    if not names:
        return
    name = names[0]
    actions = ["показать конфиг текстом", "qr-код в терминал",
               "сохранить .conf в файл", "сохранить qr в png"]
    chosen = pick(actions, f"{name}: что сделать")
    if chosen is None:
        return
    action = chosen[0]
    if action == 0:
        show_client(state, name)
    elif action == 1:
        print_qr(client_config(state, name))
    elif action == 2:
        path = ask(f"путь [/root/{name}.conf]: ", f"/root/{name}.conf")
        show_client(state, name, out=path)
    else:
        path = ask(f"путь [/root/{name}.png]: ", f"/root/{name}.png")
        show_client(state, name, png=path)
    pause()


def menu_toggle(state: dict) -> None:
    names = menu_pick_clients(state, "кого включить/выключить (пробел — отметить)",
                              multi=True)
    if not names:
        return
    for name in names:
        client = get_client(state, name)
        client["enabled"] = not client.get("enabled", True)
        print(("включен " if client["enabled"] else "выключен ") + bold(name))
    apply(state)
    pause()


def menu_remove(state: dict) -> None:
    names = menu_pick_clients(state, "кого удалить (пробел — отметить)", multi=True)
    if not names:
        return
    if not confirm(f"удалить насовсем: {', '.join(names)}?"):
        print("отменено")
        return
    for name in names:
        state["clients"].pop(name, None)
    apply(state)
    print(green(f"удалено: {', '.join(names)}"))
    pause()


def menu(state: dict) -> None:
    items = [
        "список клиентов и трафик",
        "добавить клиента",
        "конфиг клиента: текст, qr, файл",
        "включить / выключить",
        "удалить клиента",
        "трафик в реальном времени",
        "сервер и параметры обфускации",
        "выход",
    ]
    pos = 0
    while True:
        chosen = pick(items, menu_title(state), start=pos)
        if chosen is None:
            return
        pos = chosen[0]
        if pos == 0:
            print_list(state, verbose=True)
            pause()
        elif pos == 1:
            menu_add(state)
        elif pos == 2:
            menu_share(state)
        elif pos == 3:
            menu_toggle(state)
        elif pos == 4:
            menu_remove(state)
        elif pos == 5:
            watch_stats(state)
        elif pos == 6:
            print_server(state)
            pause()
        else:
            return


# ============================================================================
#  CLI
# ============================================================================
def cmd_init(args) -> int:
    if os.path.exists(STATE_FILE) and not args.force:
        raise AppError(f"{STATE_FILE} уже есть (--force — перезаписать)")
    state = json.loads(json.dumps(DEFAULT_STATE))
    state.update({
        "iface": args.iface,
        "endpoint": args.endpoint,
        "subnet": args.subnet,
        "server_ip": args.server_ip or str(next(
            ipaddress.ip_network(args.subnet, strict=False).hosts())),
        "dns": [d.strip() for d in args.dns.split(",") if d.strip()],
        "client_mtu": args.mtu,
        "keepalive": args.keepalive,
        "allowed_ips": args.allowed_ips,
        "clients": {},
    })
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    state["server_pubkey"] = server_pubkey(state)
    save_state(state)
    print(green(f"разложено: {STATE_FILE}"))
    return 0


def cmd_list(args) -> int:
    state = load_state()
    if args.json:
        print(json.dumps(client_rows(state), ensure_ascii=False, indent=2))
        return 0
    print_list(state, verbose=args.verbose)
    return 0


def cmd_add(args) -> int:
    state = load_state()
    client = add_client(state, args.name, note=args.note, ip=args.ip,
                        client_pubkey=args.pubkey)
    apply(state)
    print(green(f"добавлен {args.name} → {client['ip']}"))
    if args.pubkey:
        print(yellow("приватного ключа нет — конфиг собирает клиент, параметры: "
                     "amwg server"))
        return 0
    show_client(state, args.name, qr=args.qr, png=args.png or "", out=args.out or "")
    return 0


def cmd_show(args) -> int:
    state = load_state()
    show_client(state, args.name, qr=args.qr, png=args.png or "", out=args.out or "")
    return 0


def cmd_rm(args) -> int:
    state = load_state()
    for name in args.names:
        get_client(state, name)
    if not args.yes and not confirm(f"удалить насовсем: {', '.join(args.names)}?"):
        print("отменено")
        return 1
    for name in args.names:
        state["clients"].pop(name, None)
    apply(state)
    print(green(f"удалено: {', '.join(args.names)}"))
    return 0


def cmd_toggle(args, enabled: bool) -> int:
    state = load_state()
    for name in args.names:
        get_client(state, name)["enabled"] = enabled
    apply(state)
    print(green(("включены: " if enabled else "выключены: ") + ", ".join(args.names)))
    return 0


def cmd_stats(args) -> int:
    state = load_state()
    if args.watch:
        watch_stats(state, interval=args.interval)
        return 0
    if args.json:
        rows = client_rows(state)
        if args.name:
            rows = [r for r in rows if r["name"] == args.name]
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    print_stats(state, args.name or "")
    return 0


def cmd_poll(args) -> int:
    state = load_state()
    poll_traffic(state)
    return 0


def cmd_apply(args) -> int:
    state = load_state()
    apply(state)
    return 0


def cmd_server(args) -> int:
    state = load_state()
    changed = False
    if args.endpoint:
        state["endpoint"] = args.endpoint
        changed = True
    if args.dns is not None:
        state["dns"] = [d.strip() for d in args.dns.split(",") if d.strip()]
        changed = True
    if args.mtu:
        state["client_mtu"] = args.mtu
        changed = True
    if args.keepalive is not None:
        state["keepalive"] = args.keepalive
        changed = True
    if args.allowed_ips:
        state["allowed_ips"] = args.allowed_ips
        changed = True
    if changed:
        save_state(state)
        print(green("сохранено; клиентам нужны новые конфиги (amwg show <имя>)"))
        return 0
    print_server(state)
    return 0


def cmd_menu(args) -> int:
    state = load_state()
    if not sys.stdin.isatty():
        raise AppError("меню нужна консоль; без неё — команды и флаги (--help)")
    menu(state)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="amwg", description="клиенты сервера AmneziaWG 3.x",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="без аргументов — интерактивное меню")
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("init", help="первичный state.json (зовёт установщик)")
    p.add_argument("--iface", default="awg0")
    p.add_argument("--endpoint", required=True, help="адрес сервера host:port")
    p.add_argument("--subnet", default="10.9.9.0/24")
    p.add_argument("--server-ip", default="")
    p.add_argument("--dns", default="1.1.1.1,1.0.0.1")
    p.add_argument("--mtu", type=int, default=1280)
    p.add_argument("--keepalive", type=int, default=25)
    p.add_argument("--allowed-ips", default="0.0.0.0/0, ::/0")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("list", aliases=["ls"], help="клиенты и трафик")
    p.add_argument("-v", "--verbose", action="store_true", help="+ всего, endpoint, заметки")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("add", help="новый клиент")
    p.add_argument("name")
    p.add_argument("--note", default="")
    p.add_argument("--ip", default="", help="конкретный адрес вместо следующего свободного")
    p.add_argument("--pubkey", default="", help="публичный ключ клиента: приватный "
                                                "остаётся у него, сервер его не хранит")
    p.add_argument("--qr", action="store_true")
    p.add_argument("--png", default="", help="сохранить qr картинкой")
    p.add_argument("--out", default="", help="сохранить конфиг в файл")
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("show", help="конфиг клиента: текст, qr, файл")
    p.add_argument("name")
    p.add_argument("--qr", action="store_true")
    p.add_argument("--png", default="")
    p.add_argument("--out", default="")
    p.set_defaults(func=cmd_show)

    p = sub.add_parser("rm", aliases=["del", "remove"], help="удалить клиента")
    p.add_argument("names", nargs="+")
    p.add_argument("--yes", "-y", action="store_true")
    p.set_defaults(func=cmd_rm)

    p = sub.add_parser("disable", help="выключить (пир снимается с интерфейса)")
    p.add_argument("names", nargs="+")
    p.set_defaults(func=lambda a: cmd_toggle(a, False))

    p = sub.add_parser("enable", help="включить обратно")
    p.add_argument("names", nargs="+")
    p.set_defaults(func=lambda a: cmd_toggle(a, True))

    p = sub.add_parser("stats", help="трафик и последнее подключение")
    p.add_argument("name", nargs="?", default="")
    p.add_argument("--watch", action="store_true", help="живая таблица со скоростью")
    p.add_argument("--interval", type=float, default=2.0)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_stats)

    p = sub.add_parser("poll", help="сложить счётчики в traffic.json (для таймера)")
    p.set_defaults(func=cmd_poll)

    p = sub.add_parser("apply", aliases=["sync"], help="перегенерить [Peer] и синкнуть")
    p.set_defaults(func=cmd_apply)

    p = sub.add_parser("server", help="сервер и параметры обфускации / правка настроек")
    p.add_argument("--endpoint", default="")
    p.add_argument("--dns", default=None)
    p.add_argument("--mtu", type=int, default=0)
    p.add_argument("--keepalive", type=int, default=None)
    p.add_argument("--allowed-ips", default="")
    p.set_defaults(func=cmd_server)

    p = sub.add_parser("menu", help="интерактивное меню")
    p.set_defaults(func=cmd_menu)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    require_root()
    if not getattr(args, "func", None):
        return cmd_menu(args)
    return args.func(args) or 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AppError as e:
        print(red(str(e)), file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("\nпрервано.", file=sys.stderr)
        raise SystemExit(130)
