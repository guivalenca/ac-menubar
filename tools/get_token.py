"""Fetch a Midea V3 unit's token and key from the user's own SmartHome (MSmartHome) account and save
them to ~/.config/ac-menubar/config.json, the file the app and actool read.

tools/get-token.command asks for the credentials and runs this script:

  AC_EMAIL=... AC_PASS=... uvx --from msmart-ng==2026.9.0 python -I tools/get_token.py

Optional environment:
  AC_DEVICE_ID  the unit's id, to skip picking it from the discovery list
  AC_HOST       the unit's IP, when discovery can't find it

The password is never printed, logged or stored, and the token and key are never printed.
"""
import asyncio
import getpass
import json
import logging
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from msmart.cloud import ApiError, CloudError, SmartHomeCloud
from msmart.const import DISCOVERY_MSG
from msmart.device import AirConditioner
from msmart.discover import Discover, DiscoverError
from msmart.lan import AuthenticationError, ProtocolError, Security

CONFIG_DIR = Path.home() / ".config" / "ac-menubar"
CONFIG_PATH = CONFIG_DIR / "config.json"
CONFIG_SHOWN = "~/.config/ac-menubar/config.json"
DEFAULT_PORT = 6444
AC_TYPE = 0xAC


class Abort(Exception):
    """Stops the script with a message for the user."""


def ask(prompt: str, default: str = "") -> str:
    try:
        answer = input(f"{prompt} [{default}]: " if default else f"{prompt}: ").strip()
    except EOFError:
        raise Abort("Entrada encerrada.")
    return answer or default


def confirm(prompt: str, default: bool) -> bool:
    answer = ask(f"{prompt} ({'S/n' if default else 's/N'})").lower()
    return default if not answer else answer in ("s", "sim", "y", "yes")


# Discovery ---------------------------------------------------------------------------------------

def broadcast_addresses() -> list[str]:
    """Subnet broadcast addresses of the active IPv4 interfaces. macOS rejects 255.255.255.255 on
    some setups (e.g. a VPN owning the default route), so discovery targets each subnet instead."""
    out = subprocess.run(["/sbin/ifconfig"], capture_output=True, text=True).stdout
    return sorted(set(re.findall(r"inet \S+ netmask \S+ broadcast (\S+)", out)))


async def discover(timeout: float = 4.0) -> list[dict]:
    """Broadcasts msmart-ng's discovery message and decodes replies with msmart-ng's parser.
    msmart's own Discover only enables SO_BROADCAST for 255.255.255.255, hence the socket here."""
    targets = broadcast_addresses()
    if not targets:
        raise Abort("Nenhuma rede local ativa. Conecte o Mac ao Wi-Fi de casa e tente de novo.")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(0.25)
    replies: dict[str, bytes] = {}
    send_error = None
    deadline = time.monotonic() + timeout
    next_send, sends_left = 0.0, 3  # units sometimes ignore a single broadcast
    try:
        while time.monotonic() < deadline:
            if sends_left and time.monotonic() >= next_send:
                for target in targets:
                    for port in (6445, 20086):
                        try:
                            sock.sendto(DISCOVERY_MSG, (target, port))
                        except OSError as e:
                            send_error = e
                sends_left -= 1
                next_send = time.monotonic() + 0.6
            try:
                data, (ip, _) = sock.recvfrom(2048)
            except socket.timeout:
                continue
            replies.setdefault(ip, data)
    finally:
        sock.close()

    if not replies and send_error is not None:
        print(f"Aviso: não consegui enviar a busca na rede ({send_error.strerror}).")
        print("Confira em Ajustes do Sistema → Privacidade e Segurança → Rede Local se o Terminal tem permissão.")

    units = []
    for ip, data in replies.items():
        try:
            version = Discover._get_device_version(data)
            info = await Discover._get_device_info(ip, version, data)
        except (DiscoverError, NotImplementedError, ValueError, IndexError, UnicodeDecodeError):
            continue
        info["udpid_endian"] = udpid_endian(info["device_id"], data) if version == 3 else None
        units.append(info)
    return sorted(units, key=lambda u: socket.inet_aton(u["ip"]))


def udpid_endian(device_id: int, reply: bytes):
    """V3 units end their discovery reply with their udpid, which tells which byte order of the id
    the cloud knows them by."""
    for endian in ("big", "little"):
        try:
            if reply[-16:] == Security.udpid(device_id.to_bytes(6, endian)):
                return endian
        except OverflowError:
            return None
    return None


async def pick_unit() -> dict:
    wanted = os.environ.get("AC_DEVICE_ID", "").strip()
    print("Procurando aparelhos na rede local...")
    units = await discover()
    acs = [u for u in units if u["device_type"] == AC_TYPE and u["version"] == 3]

    for u in units:
        if u not in acs:
            print(f"  (ignorado) {u['name']}  id {u['device_id']}  {u['ip']}  V{u['version']}: só aparelhos V3 usam token")

    if wanted:
        if not wanted.isdigit():
            raise Abort("AC_DEVICE_ID precisa ser um número.")
        found = next((u for u in acs if u["device_id"] == int(wanted)), None)
        if found:
            return found
        print(f"O aparelho {wanted} não respondeu à busca.")
        return manual_unit(int(wanted))

    if not acs:
        print("Nenhum ar-condicionado V3 respondeu. Confira se o Mac está no mesmo Wi-Fi do aparelho.")
        typed = ask("ID do aparelho (deixe vazio para cancelar)")
        if not typed:
            raise Abort("Cancelado.")
        if not typed.isdigit():
            raise Abort("O ID precisa ser um número.")
        return manual_unit(int(typed))

    print("Aparelhos encontrados:")
    for i, u in enumerate(acs, 1):
        print(f"  {i}) {u['name']}  id {u['device_id']}  {u['ip']}:{u['port']}")
    if len(acs) == 1:
        if not confirm("Usar este aparelho?", default=True):
            raise Abort("Cancelado.")
        return acs[0]
    choice = ask(f"Número do aparelho (1-{len(acs)})")
    if not choice.isdigit() or not 1 <= int(choice) <= len(acs):
        raise Abort("Opção inválida.")
    return acs[int(choice) - 1]


def manual_unit(device_id: int) -> dict:
    host = os.environ.get("AC_HOST", "").strip() or ask("IP do aparelho na rede local")
    try:
        socket.inet_aton(host)
    except OSError:
        raise Abort("IP inválido.")
    return {"device_id": device_id, "ip": host, "port": DEFAULT_PORT, "name": None, "udpid_endian": None}


# Config file -------------------------------------------------------------------------------------

def load_config() -> dict:
    """The current file, or an empty config if there is none. Refuses files it can't parse, so they
    are never overwritten."""
    try:
        text = CONFIG_PATH.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {"homeRouterMACs": [], "devices": []}
    except OSError as e:
        raise Abort(f"Não consegui ler {CONFIG_SHOWN}: {e.strerror}.")
    try:
        config = json.loads(text)
    except ValueError:
        config = None
    if not isinstance(config, dict) or not isinstance(config.get("devices", []), list) \
            or not all(isinstance(d, dict) for d in config.get("devices", [])):
        raise Abort(f"{CONFIG_SHOWN} existe, mas não é uma configuração válida. "
                    "Corrija ou mova o arquivo e rode de novo; ele não foi alterado.")
    return config


def save_device(entry: dict) -> None:
    config = load_config()  # re-read: keep anything written since the start
    config.setdefault("homeRouterMACs", [])
    devices = config.setdefault("devices", [])
    for i, d in enumerate(devices):
        if str(d.get("id")) == str(entry["id"]):
            devices[i] = {**d, **entry}
            break
    else:
        devices.append(entry)

    CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    fd, tmp = tempfile.mkstemp(dir=CONFIG_DIR, prefix=".config.", suffix=".tmp")  # created 0600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG_PATH)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


# Cloud and LAN -----------------------------------------------------------------------------------

def credentials() -> tuple[str, str]:
    email = os.environ.pop("AC_EMAIL", "").strip()
    password = os.environ.pop("AC_PASS", "")
    if not email and sys.stdin.isatty():
        email = ask("E-mail da conta SmartHome")
    if not password and sys.stdin.isatty():
        password = getpass.getpass("Senha (não aparece enquanto você digita): ")
    if not email or not password:
        raise Abort("Informe o e-mail e a senha da conta SmartHome.")
    return email, password


async def fetch_candidates(email: str, password: str, device_id: int) -> dict[str, tuple[str, str]]:
    cloud = SmartHomeCloud("US", account=email, password=password)
    print("Entrando na conta SmartHome...")
    try:
        await cloud.login()
    except ApiError as e:
        if e.code == 3102:
            raise Abort("E-mail ou senha incorretos.")
        raise Abort(f"A conta SmartHome recusou o login ({e.code}: {e.message}).")
    except CloudError as e:
        raise Abort(f"Não consegui falar com a nuvem SmartHome: {e}")

    candidates = {}
    for endian in ("little", "big"):
        udpid = Security.udpid(device_id.to_bytes(6, endian)).hex()
        try:
            token, key = await cloud.get_token(udpid, device_id)
        except CloudError:
            continue
        try:
            bytes.fromhex(token), bytes.fromhex(key)
        except (TypeError, ValueError):
            continue
        candidates[endian] = (token.lower(), key.lower())
    if not candidates:
        raise Abort("A conta não devolveu token para este aparelho. "
                    "Ele está cadastrado nesta conta no app SmartHome?")
    return candidates


async def reachable(host: str, port: int) -> bool:
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=5)
    except (OSError, asyncio.TimeoutError):
        return False
    writer.close()
    return True


async def authenticates(unit: dict, token: str, key: str) -> bool:
    device = AirConditioner(ip=unit["ip"], port=unit["port"], device_id=unit["device_id"])
    try:
        await asyncio.wait_for(device.authenticate(token, key), timeout=20)
        await asyncio.wait_for(device.refresh(), timeout=20)
        return device.online
    except (AuthenticationError, ProtocolError, OSError, asyncio.TimeoutError):
        return False
    finally:
        try:
            device._lan._disconnect()
        except Exception:
            pass


async def choose(unit: dict, candidates: dict[str, tuple[str, str]]) -> tuple[str, str]:
    """Tries the byte order the unit's discovery reply points to first, then big endian (the one that
    worked in testing), and keeps the first candidate the unit accepts."""
    preferred = unit.get("udpid_endian") or "big"
    order = sorted(candidates, key=lambda e: (e != preferred, e != "big"))
    unique = []
    for endian in order:
        if candidates[endian] not in [candidates[e] for e in unique]:
            unique.append(endian)

    if not await reachable(unit["ip"], unit["port"]):
        print(f"Não consegui falar com o aparelho em {unit['ip']}:{unit['port']} para testar a chave.")
        print("Salvando a opção mais provável; se o app não conectar, rode este script de novo em casa.")
        return candidates[unique[0]]

    print("Testando a chave com o aparelho...")
    for endian in unique:
        if await authenticates(unit, *candidates[endian]):
            print("O aparelho aceitou a chave.")
            return candidates[endian]

    print("O aparelho recusou as chaves recebidas. Se o app da barra de menus estiver aberto, feche-o e tente de novo.")
    if confirm("Salvar mesmo assim a opção mais provável?", default=False):
        return candidates[unique[0]]
    raise Abort("Nada foi salvo.")


async def main() -> None:
    load_config()  # fail before contacting the cloud if the file can't be updated
    email, password = credentials()
    unit = await pick_unit()
    existing = next((d for d in load_config().get("devices", []) if str(d.get("id")) == str(unit["device_id"])), {})
    name = ask("Nome do cômodo", existing.get("name") or "Sala")

    candidates = await fetch_candidates(email, password, unit["device_id"])
    token, key = await choose(unit, candidates)

    save_device({"id": unit["device_id"], "name": name, "host": unit["ip"], "port": unit["port"],
                 "token": token, "key": key})
    print(f"Pronto: token e chave de “{name}” salvos em {CONFIG_SHOWN}.")


if __name__ == "__main__":
    # msmart-ng logs cloud replies and session keys at debug/info level; keep its logs quiet.
    logging.getLogger("msmart").setLevel(logging.CRITICAL)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    try:
        asyncio.run(main())
    except Abort as e:
        print(e)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nCancelado.")
        sys.exit(130)
    except Exception as e:  # no traceback: keep the output short and free of request details
        print(f"Erro inesperado ({type(e).__name__}): {e}")
        sys.exit(1)
