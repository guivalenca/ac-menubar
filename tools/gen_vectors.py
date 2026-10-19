"""Generate golden test vectors from msmart-ng for the Swift port.

Self-contained: every input is a constant or synthetic, so anyone can regenerate the file without a
device. Run from the repository root:

  uvx --from msmart-ng==2026.9.0 python -I tools/gen_vectors.py > Tests/MideaKitTests/Vectors.json
"""
import asyncio, ipaddress, json, logging, sys
from hashlib import sha256
import msmart.crc8 as crc8
import msmart.lan as lan
from msmart.discover import Discover
from msmart.frame import Frame
from msmart.device.AC.command import Command, GetStateCommand, SetStateCommand, Response, StateResponse
from msmart.lan import Security, _Packet, _LanProtocolV3

# Fake unit used by every vector that needs one. None of these values belong to a real device.
FAKE_DEVICE_ID = 0x112233445566
FAKE_IP = "192.0.2.50"  # RFC 5737 documentation range
FAKE_PORT = 6444
FAKE_SERIAL = "FAKE0001".rjust(32, "0")
FAKE_NAME = "net_ac_FAKE"

# A state response from a unit. It holds only AC state (power, setpoint, mode, fan, swing and the
# indoor/outdoor temperatures), no identifiers.
STATE_FRAME = "aa22ac00000000000303c00041667f7f00300000005d56000000000000000000699dde"

v = {}

# CRC8 / checksum
data = bytes(range(0, 40, 3))
v["crc8"] = {"data": data.hex(), "crc": crc8.calculate(data), "checksum": Frame.checksum(data)}

# Commands (fix the message id)
Command._message_id = 0x10
v["get_state"] = GetStateCommand().tobytes().hex()

set_cases = []
for case in [
    dict(power_on=True, target_temperature=22.0, operational_mode=2, fan_speed=102, swing_mode=0x0, eco=False, turbo=False, sleep=False, beep_on=True),
    dict(power_on=False, target_temperature=16.0, operational_mode=3, fan_speed=40, swing_mode=0xC, eco=True, turbo=False, sleep=True, beep_on=False),
    dict(power_on=True, target_temperature=24.5, operational_mode=5, fan_speed=80, swing_mode=0xF, eco=False, turbo=True, sleep=False, beep_on=True),
    dict(power_on=True, target_temperature=30.0, operational_mode=1, fan_speed=60, swing_mode=0x3, eco=False, turbo=False, sleep=False, beep_on=False),
]:
    Command._message_id = 0x20
    cmd = SetStateCommand()
    cmd.fahrenheit = False
    cmd.follow_me = False
    cmd.purifier = False
    cmd.freeze_protection = False
    cmd.target_humidity = 40
    for k, val in case.items():
        setattr(cmd, k, val)
    set_cases.append({"input": case, "bytes": cmd.tobytes().hex()})
v["set_state"] = set_cases

# AES ECB with fixed key
plain = bytes(range(37))
v["aes_ecb"] = {"plain": plain.hex(), "cipher": Security.encrypt_aes(plain).hex()}

# MD5 sign
v["sign"] = {"data": plain.hex(), "md5": Security.sign(plain).hex()}

# udpid
dev_id = FAKE_DEVICE_ID
v["udpid"] = {"id": dev_id,
              "little": Security.udpid(dev_id.to_bytes(6, "little")).hex(),
              "big": Security.udpid(dev_id.to_bytes(6, "big")).hex()}

# V2 packet with fixed timestamp
ts = bytes([12, 34, 56, 21, 18, 10, 26, 20])
_Packet._timestamp = classmethod(lambda cls: ts)
frame = bytes.fromhex(v["get_state"])
pkt = _Packet.encode(dev_id, frame)
v["packet"] = {"id": dev_id, "timestamp": ts.hex(), "frame": frame.hex(), "packet": pkt.hex()}
assert _Packet.decode(pkt) == frame

# V3 handshake + encrypted request with fixed key and padding
proto = _LanProtocolV3()
token = bytes(range(64))
v["v3_handshake"] = {"packet_id": 0, "token": token.hex(), "packet": proto._encode_handshake_request(0, token).hex()}

local_key = bytes(range(100, 132))
proto._local_key = local_key
lan.get_random_bytes = lambda n: bytes([0xA5] * n)
enc = proto._encode_encrypted_request(5, pkt)
v["v3_encrypted"] = {"packet_id": 5, "local_key": local_key.hex(), "data": pkt.hex(), "packet": enc.hex()}

# Encrypted response decode: build a response the device would send (type 0x3) and decode it
payload = pkt
remainder = (len(payload) + 2) % 16
pad = 16 - remainder if remainder else 0
header = b"\x83\x70" + (len(payload) + pad + 32).to_bytes(2, "big") + b"\x20" + bytes([pad << 4 | 0x3])
inner = (7).to_bytes(2, "big") + payload + bytes([0x5A] * pad)
resp = header + Security.encrypt_aes_cbc(local_key, inner) + sha256(header + inner).digest()
assert proto._decode_encrypted_response(memoryview(resp)) == payload
v["v3_response"] = {"local_key": local_key.hex(), "packet": resp.hex(), "payload": payload.hex()}

# Local key derivation
cloud_key = bytes(range(200, 232))
plain_key = bytes(range(1, 33))
hs = Security.encrypt_aes_cbc(cloud_key, plain_key) + sha256(plain_key).digest()
v["local_key"] = {"cloud_key": cloud_key.hex(), "handshake_payload": hs.hex(),
                  "local_key": proto._get_local_key(cloud_key, memoryview(hs)).hex()}

# State frame + msmart's parse
sf = bytes.fromhex(STATE_FRAME)
r = Response.construct(sf)
assert isinstance(r, StateResponse)
v["state_response"] = {"frame": sf.hex(), "parsed": {
    "power_on": r.power_on, "target_temperature": r.target_temperature, "operational_mode": r.operational_mode,
    "fan_speed": r.fan_speed, "swing_mode": r.swing_mode, "turbo": r.turbo, "eco": r.eco, "sleep": r.sleep,
    "fahrenheit": r.fahrenheit, "indoor_temperature": r.indoor_temperature, "outdoor_temperature": r.outdoor_temperature,
    "display_on": r.display_on, "error_code": r.error_code}}


def discovery_reply(device_id: int, ip: str, port: int, serial: str, name: str) -> bytes:
    """A V3 discovery reply built from scratch, laid out the way a unit sends it.

    8-byte V3 header: 0x8370, size of what follows it (big endian), 0x20, 0x0F, packet id 0.
    V2 packet: 40-byte header (magic 0x7A80, device id at 20..28), AES-ECB info block, MD5 sign.
    16-byte trailer: the unit's udpid (from its big-endian id).
    The info block is 122 bytes, like a real unit's: IP (reversed), port (LE), 2 zero bytes,
    32-byte serial, name length and name. Every other field is zero.
    """
    assert len(serial) == 32 and 41 + len(name) <= 122
    info = bytearray(122)
    info[0:4] = ipaddress.IPv4Address(ip).packed[::-1]
    info[4:6] = port.to_bytes(2, "little")
    info[8:40] = serial.encode()
    info[40] = len(name)
    info[41:41 + len(name)] = name.encode()
    encrypted = Security.encrypt_aes(bytes(info))
    packet = (b"\x5a\x5a" + b"\x01\x11" + (40 + len(encrypted) + 16).to_bytes(2, "little") + b"\x7a\x80"
              + bytes(4) + ts + device_id.to_bytes(8, "little") + bytes(12) + encrypted)
    packet += Security.sign(packet)
    trailer = Security.udpid(device_id.to_bytes(6, "big"))
    return b"\x83\x70" + (len(packet) + len(trailer)).to_bytes(2, "big") + b"\x20\x0f" + bytes(2) + packet + trailer


class _Warnings(logging.Handler):
    def __init__(self):
        super().__init__(logging.WARNING)
        self.messages = []

    def emit(self, record):
        self.messages.append(record.getMessage())


# msmart-ng's own parser must decode the synthetic reply to the fake values.
reply = discovery_reply(FAKE_DEVICE_ID, FAKE_IP, FAKE_PORT, FAKE_SERIAL, FAKE_NAME)
warnings = _Warnings()
logging.getLogger("msmart.discover").addHandler(warnings)
assert Discover._get_device_version(reply) == 3
info = asyncio.run(Discover._get_device_info(FAKE_IP, 3, reply))
# msmart warns when the IP inside the reply differs from the sender's: no warning means it decoded FAKE_IP.
assert warnings.messages == [], warnings.messages
assert info == {"ip": FAKE_IP, "port": FAKE_PORT, "device_id": FAKE_DEVICE_ID, "name": FAKE_NAME,
                "sn": FAKE_SERIAL, "device_type": 0xAC, "version": 3}, info
v["discovery_reply"] = {"packet": reply.hex(), "parsed": {
    "ip": info["ip"], "port": info["port"], "id": info["device_id"], "name": info["name"],
    "serial": info["sn"], "version": info["version"]}}

json.dump(v, sys.stdout, indent=1)
