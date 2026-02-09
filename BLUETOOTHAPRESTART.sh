sudo pip3 install dbus-next --break-system-packages



sudo nano /etc/bluetooth/main.conf
[General]
JustWorksRepairing = always
Experimental = true








sudo tee /usr/local/bin/mirako_bt.py >/dev/null <<'EOF'
#!/usr/bin/env python3
import os
import time
import asyncio
import subprocess
import threading
import logging
from typing import Optional

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, dbus_property, PropertyAccess
from dbus_next.constants import BusType
from dbus_next import Variant

logging.basicConfig(level=logging.INFO)

BT_NAME = "MirakoAP"
PIN_STR = "1234"
PASSKEY = 1234

PROFILES = "/usr/local/bin/profiles.sh"

# BLE Nordic UART Service (NUS)
NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX_UUID      = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # write
NUS_TX_UUID      = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # notify

# Classic SPP UUID
SPP_UUID = "00001101-0000-1000-8000-00805f9b34fb"
SPP_CHANNEL = 1

BLUEZ = "org.bluez"
DBUS_OM = "org.freedesktop.DBus.ObjectManager"
DBUS_PROP = "org.freedesktop.DBus.Properties"


def exec_profile(p):
    try:
        out = subprocess.check_output([PROFILES, p], stderr=subprocess.STDOUT, text=True, timeout=180)
        return out.strip() or "ok"
    except subprocess.CalledProcessError as e:
        return (e.output or "erro").strip()
    except Exception as e:
        return f"erro: {e}"


def handle_command(cmd: str) -> str:
    cmd = (cmd or "").strip().lower()

    if cmd == "help":
        return "help | ap | client-wifi | reboot"

    if cmd == "ap":
        return exec_profile("ap")

    if cmd == "client-wifi":
        return exec_profile("client-wifi")

    if cmd in ("reboot", "restart"):
        subprocess.Popen(["/sbin/reboot"])
        return "Reiniciando..."

    return "Comando invalido"


# ---------------------------
# Agent DBus (pareamento)
# ---------------------------
class Agent(ServiceInterface):
    def __init__(self, path="/mirako/agent"):
        super().__init__("org.bluez.Agent1")
        self.path = path

    @method()
    def Release(self):
        return

    @method()
    def RequestPinCode(self, device: "o") -> "s":
        return PIN_STR

    @method()
    def RequestPasskey(self, device: "o") -> "u":
        return PASSKEY

    @method()
    def DisplayPinCode(self, device: "o", pincode: "s"):
        return

    @method()
    def DisplayPasskey(self, device: "o", passkey: "u", entered: "q"):
        return

    @method()
    def RequestConfirmation(self, device: "o", passkey: "u"):
        return

    @method()
    def RequestAuthorization(self, device: "o"):
        return

    @method()
    def AuthorizeService(self, device: "o", uuid: "s"):
        return

    @method()
    def Cancel(self):
        return


# ---------------------------
# BLE GATT (NUS)
# ---------------------------
class GattCharacteristic(ServiceInterface):
    def __init__(self, path, uuid, flags, service_path):
        super().__init__("org.bluez.GattCharacteristic1")
        self.path = path
        self.uuid = uuid
        self.flags = flags
        self.service_path = service_path
        self.value: bytes = b""
        self.notifying = False
        self.notify_cb = None

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return self.uuid

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> "o":
        return self.service_path

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> "as":
        return self.flags

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> "ay":
        return self.value

    @method()
    def ReadValue(self, options: "a{sv}") -> "ay":
        return self.value

    @method()
    def WriteValue(self, value: "ay", options: "a{sv}"):
        data = bytes(value)
        self.value = data

        if self.uuid.lower() == NUS_RX_UUID.lower():
            cmd = data.decode(errors="ignore").strip()
            logging.info("BLE RX: %r", cmd)
            resp = handle_command(cmd)
            if self.notify_cb:
                self.notify_cb(resp)

    @method()
    def StartNotify(self):
        self.notifying = True
        logging.info("BLE: StartNotify %s", self.uuid)

    @method()
    def StopNotify(self):
        self.notifying = False
        logging.info("BLE: StopNotify %s", self.uuid)


class GattService(ServiceInterface):
    def __init__(self, path, uuid, primary=True):
        super().__init__("org.bluez.GattService1")
        self.path = path
        self.uuid = uuid
        self.primary = primary
        self.chars = []

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return self.uuid

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> "b":
        return self.primary

    @dbus_property(access=PropertyAccess.READ)
    def Characteristics(self) -> "ao":
        return [c.path for c in self.chars]


class Application(ServiceInterface):
    def __init__(self, path="/mirako/app"):
        super().__init__(DBUS_OM)
        self.path = path
        self.services = []

    @method()
    def GetManagedObjects(self) -> "a{oa{sa{sv}}}":
        objs = {}
        for s in self.services:
            objs[s.path] = {
                "org.bluez.GattService1": {
                    "UUID": Variant("s", s.uuid),
                    "Primary": Variant("b", s.primary),
                    "Characteristics": Variant("ao", [c.path for c in s.chars]),
                }
            }
            for c in s.chars:
                objs[c.path] = {
                    "org.bluez.GattCharacteristic1": {
                        "UUID": Variant("s", c.uuid),
                        "Service": Variant("o", c.service_path),
                        "Flags": Variant("as", c.flags),
                        "Value": Variant("ay", c.value),
                    }
                }
        return objs


class Advertisement(ServiceInterface):
    """
    Fix: BlueZ pode pedir TxPower como propriedade.
    Se Includes contiver "tx-power", BlueZ espera TxPower existir.
    """
    def __init__(self, path="/mirako/adv"):
        super().__init__("org.bluez.LEAdvertisement1")
        self.path = path
        self.local_name = BT_NAME
        self.service_uuids = [NUS_SERVICE_UUID]
        self.type = "peripheral"
        self._tx_power = 0  # dBm (pode ficar 0)

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> "s":
        return self.type

    @dbus_property(access=PropertyAccess.READ)
    def ServiceUUIDs(self) -> "as":
        return self.service_uuids

    @dbus_property(access=PropertyAccess.READ)
    def LocalName(self) -> "s":
        return self.local_name

    @dbus_property(access=PropertyAccess.READ)
    def Includes(self) -> "as":
        return ["tx-power"]

    @dbus_property(access=PropertyAccess.READ)
    def TxPower(self) -> "n":
        # "n" = int16
        return int(self._tx_power)

    @method()
    def Release(self):
        return


# ---------------------------
# Classic SPP real (Profile1)
# ---------------------------
class SPPProfile(ServiceInterface):
    def __init__(self, path="/mirako/spp_profile"):
        super().__init__("org.bluez.Profile1")
        self.path = path
        self._conn_fd: Optional[int] = None
        self._stop = False

    def _close_current(self):
        try:
            if self._conn_fd is not None:
                os.close(self._conn_fd)
        except Exception:
            pass
        self._conn_fd = None

    @method()
    def Release(self):
        self._stop = True
        self._close_current()

    @method()
    def Cancel(self):
        return

    @method()
    def NewConnection(self, device: "o", fd: "h", fd_properties: "a{sv}"):
        self._close_current()
        self._conn_fd = int(fd)
        logging.info("SPP: NewConnection device=%s fd=%s props=%s", device, self._conn_fd, fd_properties)
        threading.Thread(target=self._io_loop, daemon=True).start()

    @method()
    def RequestDisconnection(self, device: "o"):
        logging.info("SPP: RequestDisconnection %s", device)
        self._close_current()

    def _write_line(self, fd: int, text: str):
        os.write(fd, (text + "\r\n").encode())

    def _io_loop(self):
        fd = self._conn_fd
        if fd is None:
            return

        try:
            self._write_line(fd, "MirakoAP conectado (Classic SPP)")
            self._write_line(fd, "Comandos: help | ap | client-wifi | reboot")

            buf = b""
            while not self._stop and self._conn_fd == fd:
                try:
                    data = os.read(fd, 1)
                    if not data:
                        time.sleep(0.05)
                        continue
                except OSError:
                    break

                if data in b"\r\n":
                    cmd = buf.decode(errors="ignore").strip()
                    buf = b""
                    if not cmd:
                        continue
                    logging.info("SPP RX: %r", cmd)
                    resp = handle_command(cmd)
                    self._write_line(fd, resp)
                else:
                    if len(buf) < 256:
                        buf += data

        except Exception as e:
            logging.warning("SPP loop erro: %s", e)
        finally:
            if self._conn_fd == fd:
                self._close_current()
            logging.info("SPP: conexão encerrada")


# ---------------------------
# BlueZ helpers
# ---------------------------
async def find_adapter(bus):
    introspect = await bus.introspect(BLUEZ, "/")
    om = bus.get_proxy_object(BLUEZ, "/", introspect).get_interface(DBUS_OM)
    objs = await om.call_get_managed_objects()
    for path, ifaces in objs.items():
        if "org.bluez.Adapter1" in ifaces:
            return path
    raise RuntimeError("Nenhum Adapter1 encontrado (BlueZ).")


async def set_prop(bus, obj_path, iface, prop, value_variant):
    introspect = await bus.introspect(BLUEZ, obj_path)
    props = bus.get_proxy_object(BLUEZ, obj_path, introspect).get_interface(DBUS_PROP)
    await props.call_set(iface, prop, value_variant)


async def main_async():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    adapter_path = await find_adapter(bus)

    # Adapter sempre visível/pareável
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "Powered", Variant("b", True))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "Alias", Variant("s", BT_NAME))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "DiscoverableTimeout", Variant("u", 0))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "PairableTimeout", Variant("u", 0))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "Discoverable", Variant("b", True))
    await set_prop(bus, adapter_path, "org.bluez.Adapter1", "Pairable", Variant("b", True))

    # Agent
    agent = Agent()
    bus.export(agent.path, agent)
    bluez_root = "/org/bluez"
    introspect = await bus.introspect(BLUEZ, bluez_root)
    agent_mgr = bus.get_proxy_object(BLUEZ, bluez_root, introspect).get_interface("org.bluez.AgentManager1")
    await agent_mgr.call_register_agent(agent.path, "KeyboardDisplay")
    await agent_mgr.call_request_default_agent(agent.path)

    # BLE GATT + Adv
    app = Application()
    adv = Advertisement()

    nus = GattService("/mirako/app/service0", NUS_SERVICE_UUID)
    tx = GattCharacteristic("/mirako/app/service0/char0", NUS_TX_UUID, ["notify", "read"], nus.path)
    rx = GattCharacteristic("/mirako/app/service0/char1", NUS_RX_UUID, ["write", "write-without-response"], nus.path)

    def notify_send(text: str):
        if not tx.notifying:
            return
        data = (text + "\n").encode()
        tx.value = data
        tx.emit_properties_changed({"Value": data}, [])

    rx.notify_cb = notify_send
    nus.chars = [tx, rx]
    app.services = [nus]

    bus.export(app.path, app)
    bus.export(nus.path, nus)
    bus.export(tx.path, tx)
    bus.export(rx.path, rx)
    bus.export(adv.path, adv)

    introspect = await bus.introspect(BLUEZ, adapter_path)
    gatt_mgr = bus.get_proxy_object(BLUEZ, adapter_path, introspect).get_interface("org.bluez.GattManager1")
    adv_mgr  = bus.get_proxy_object(BLUEZ, adapter_path, introspect).get_interface("org.bluez.LEAdvertisingManager1")
    await gatt_mgr.call_register_application(app.path, {})
    await adv_mgr.call_register_advertisement(adv.path, {})

    # Classic SPP Profile1
    spp = SPPProfile()
    bus.export(spp.path, spp)

    introspect = await bus.introspect(BLUEZ, bluez_root)
    prof_mgr = bus.get_proxy_object(BLUEZ, bluez_root, introspect).get_interface("org.bluez.ProfileManager1")

    opts = {
        "Name": Variant("s", "MirakoAP SPP"),
        "Role": Variant("s", "server"),
        "Channel": Variant("q", SPP_CHANNEL),
        "RequireAuthentication": Variant("b", False),
        "RequireAuthorization": Variant("b", False),
        "AutoConnect": Variant("b", True),
    }

    await prof_mgr.call_register_profile(spp.path, SPP_UUID, opts)

    logging.info("MirakoAP pronto: BLE(NUS) + Classic SPP (Profile1) + PIN 1234")
    logging.info("Classic SPP: conecte no MirakoAP usando app Serial Bluetooth clássico")

    while True:
        await asyncio.sleep(5)


def main():
    asyncio.run(main_async())


if __name__ == "__main__":
    main()


EOF

sudo chmod +x /usr/local/bin/mirako_bt.py


sudo systemctl restart bluetooth
sudo systemctl restart mirako-bt


sudo tee /etc/systemd/system/mirako-bt.service >/dev/null <<'EOF'
[Unit]
Description=MirakoAP Bluetooth (Classic SPP + BLE NUS + PIN)
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/mirako_bt.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mirako-bt.service
journalctl -u mirako-bt.service -f



sudo systemctl restart bluetooth
sudo systemctl restart mirako-bt



ls -l /dev/rfcomm0



