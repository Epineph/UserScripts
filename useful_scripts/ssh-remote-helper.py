#!/usr/bin/env python3
"""Inspect and configure ordinary OpenSSH for remote Linux access.

Python 3.9+; Rich is optional. Run --long-help for examples and boundaries.
The client-key action belongs on the client; setup belongs on the server.
"""

# --- Imports and constants ----------------------------------------------------

import argparse
import base64
import glob
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

try:
  from rich.console import Console
  from rich.table import Table
except ImportError:
  Console = Table = None

CONFIG = Path("/etc/ssh/sshd_config")
MANAGED = Path("/etc/ssh/remote-helper.conf")
STATE = Path("/var/lib/ssh-remote-helper/backups")
INCLUDE = f"Include {MANAGED}\n"
CONSOLE = Console(highlight=False) if Console else None
KEY_TYPES = {
  "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256",
  "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
  "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
}


# --- Terminal output and subprocesses ----------------------------------------

class SetupError(RuntimeError):
  """A condition requiring correction before setup can continue."""


def say(message=""):
  if CONSOLE:
    CONSOLE.print(str(message), markup=False)
  else:
    print(message)


def table(title, rows):
  if CONSOLE:
    result = Table(title=title, show_header=False, expand=False)
    result.add_column(style="cyan")
    result.add_column(overflow="fold")
    for label, value in rows:
      result.add_row(str(label), str(value))
    CONSOLE.print(result)
  else:
    say(f"\n{title}")
    for label, value in rows:
      say(f"  {label}: {value}")


def run(argv, *, check=True, live=False, timeout=20):
  """Use argument lists throughout: never execute an interpolated shell."""
  try:
    result = subprocess.run(
      [str(part) for part in argv], text=True,
      stdout=None if live else subprocess.PIPE,
      stderr=None if live else subprocess.PIPE, timeout=timeout,
    )
  except (OSError, subprocess.TimeoutExpired) as error:
    if not check:
      return subprocess.CompletedProcess(argv, 127, "", str(error))
    raise SetupError(f"Cannot run {argv[0]}: {error}") from error
  if check and result.returncode:
    detail = (result.stderr or result.stdout or "").strip()
    raise SetupError(f"{shlex.join(map(str, argv))} failed: {detail}")
  return result


def command_json(argv):
  result = run(argv, check=False, timeout=8)
  try:
    return json.loads(result.stdout) if result.returncode == 0 else None
  except (TypeError, json.JSONDecodeError):
    return None


def require_root():
  if os.geteuid() != 0:
    raise SetupError("Use sudo for setup --apply and restore --apply.")


def sshd_path():
  for candidate in (shutil.which("sshd"), "/usr/sbin/sshd"):
    if candidate and Path(candidate).is_file():
      return str(Path(candidate).resolve())
  raise SetupError("OpenSSH server is missing; install openssh first.")


def account(name=None):
  name = name or os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name
  try:
    user = pwd.getpwnam(name)
  except KeyError as error:
    raise SetupError(f"Linux account does not exist: {name}") from error
  if user.pw_uid == 0:
    raise SetupError("Select a non-root Linux login account with --user.")
  if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*[$]?", user.pw_name):
    raise SetupError("The account name is unsuitable for an SSH directive.")
  if Path(user.pw_shell).name in {"false", "nologin"}:
    raise SetupError(f"{name} does not have an interactive login shell.")
  return user


def port_number(value):
  try:
    number = int(value)
  except ValueError as error:
    raise argparse.ArgumentTypeError("Port must be an integer.") from error
  if not 1 <= number <= 65535:
    raise argparse.ArgumentTypeError("Port must be between 1 and 65535.")
  return number


def endpoint_name(value):
  """Permit an IP literal or ASCII DNS hostname, without scheme or port."""
  value = value.strip()
  try:
    return str(ipaddress.ip_address(value))
  except ValueError:
    labels = value.rstrip(".").split(".")
    valid = all(re.fullmatch(
      r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label,
    ) for label in labels)
    if not valid or len(value) > 253:
      raise argparse.ArgumentTypeError("Use an IP or DNS name, without :port.")
    return value.rstrip(".")


# --- Network discovery: local routes, egress address and Tailscale ------------

def public_ipv4():
  # HTTPS services observe this host's outbound address, possibly VPN egress.
  for url in ("https://api.ipify.org", "https://ipv4.icanhazip.com"):
    try:
      request = urllib.request.Request(url, headers={
        "User-Agent": "ssh-remote-helper/1.0",
      })
      with urllib.request.urlopen(request, timeout=3) as response:
        address = ipaddress.ip_address(response.read(128).decode().strip())
      if address.version == 4 and address.is_global:
        return str(address)
    except (OSError, ValueError, UnicodeError):
      continue
  return None


def tailscale_state():
  status = command_json(["tailscale", "status", "--json"]) or {}
  self_node = status.get("Self") or {}
  addresses = self_node.get("TailscaleIPs") or []
  ipv4 = next((ip for ip in addresses if ":" not in ip), None)
  prefs = command_json(["tailscale", "debug", "prefs"]) or {}
  return {
    "state": status.get("BackendState", "unavailable"),
    "ip": ipv4,
    "dns": self_node.get("DNSName", "").rstrip("."),
    "ssh_enabled": prefs.get("RunSSH"),
  }


def network_info(no_public_ip=False):
  interfaces = command_json(["ip", "-j", "address", "show"]) or []
  route = command_json(["ip", "-j", "-4", "route", "get", "1.1.1.1"])
  route = route[0] if route else {}
  addresses = []
  for interface in interfaces:
    if interface.get("ifname") == "lo":
      continue
    for item in interface.get("addr_info", []):
      if item.get("scope") != "global":
        continue
      addresses.append({
        "interface": interface["ifname"], "ip": item.get("local"),
        "prefix": item.get("prefixlen"), "family": item.get("family"),
      })
  return {
    "hostname": socket.gethostname(), "addresses": addresses,
    "route_ip": route.get("prefsrc", route.get("src")),
    "interface": route.get("dev"), "gateway": route.get("gateway"),
    "egress_ipv4": None if no_public_ip else public_ipv4(),
    "tailscale": tailscale_state(),
  }


def nat_explanation(router_wan, egress):
  if not router_wan:
    return (
      "Unknown: supply the router's WAN IPv4 with --router-wan. "
      "A private LAN address alone does not establish CGNAT."
    )
  address = ipaddress.ip_address(router_wan)
  if address.version != 4:
    return "This comparison concerns IPv4; use the router's WAN IPv4."
  if address in ipaddress.ip_network("100.64.0.0/10"):
    return "Shared WAN IPv4: CGNAT is likely; use Tailscale or a public IPv4."
  if not address.is_global:
    return "Non-public WAN IPv4: upstream NAT; forwarding here is insufficient."
  if not egress:
    return "Public WAN IPv4 supplied; outbound address comparison unavailable."
  if str(address) != egress:
    return "WAN differs from egress: investigate upstream NAT or VPN routing."
  return "Public WAN matches egress; inbound reachability still needs testing."


def firewall_info(interface):
  ufw = run(["ufw", "status"], check=False).stdout.strip()
  firewalld = run(["firewall-cmd", "--state"], check=False).stdout.strip()
  zone = ""
  if firewalld == "running":
    if interface:
      zone = run([
        "firewall-cmd", f"--get-zone-of-interface={interface}",
      ], check=False).stdout.strip()
    if not zone or zone == "no zone":
      zone = run([
        "firewall-cmd", "--get-default-zone",
      ], check=False).stdout.strip()
  return {"ufw": ufw, "firewalld": firewalld, "zone": zone}


def connection_command(user, host, port, identity=None):
  arguments = ["ssh"]
  if identity:
    arguments.extend(["-i", identity, "-o", "IdentitiesOnly=yes"])
  return shlex.join(arguments + ["-p", str(port), f"{user}@{host}"])


# --- Keys: validate the public half; generate private keys on the client ------

def read_public_key(path):
  text = Path(path).expanduser().read_text(encoding="utf-8").strip()
  lines = [line for line in text.splitlines() if line.strip()]
  if len(lines) != 1 or len(text) > 32768:
    raise SetupError("Supply one ordinary OpenSSH public key in a .pub file.")
  parts = text.split()
  if len(parts) < 2 or parts[0] not in KEY_TYPES:
    raise SetupError("Expected a public key, never a private key or options.")
  if any(ord(char) < 32 for char in text):
    raise SetupError("Public key contains control characters.")
  try:
    base64.b64decode(parts[1], validate=True)
  except ValueError as error:
    raise SetupError("Public key has invalid base64 data.") from error
  with tempfile.TemporaryDirectory(prefix="ssh-public-check-") as directory:
    key_file = Path(directory) / "key.pub"
    key_file.write_text(text + "\n", encoding="utf-8")
    fingerprint = run(["ssh-keygen", "-lf", key_file]).stdout.strip()
  if parts[0] == "ssh-rsa" and int(fingerprint.split()[0]) < 3072:
    raise SetupError("Use Ed25519 or an RSA key with at least 3072 bits.")
  return text, fingerprint


def key_contents(existing, public_key):
  """Keep other keys and refuse to bypass a restricted duplicate."""
  key_type, blob = public_key.split()[:2]
  found = False
  for line in existing.splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
      continue
    try:
      tokens = shlex.split(line)
    except ValueError:
      continue
    for index, token in enumerate(tokens[:-1]):
      if token == key_type and tokens[index + 1] == blob:
        if index:
          raise SetupError(
            "This key already has authorized_keys restrictions. "
            "Use another key or review its existing options manually."
          )
        found = True
  if found:
    return existing
  return existing.rstrip("\n") + ("\n" if existing else "") + public_key + "\n"


def client_key(args):
  if os.geteuid() == 0:
    raise SetupError("Generate the client key without sudo, as a normal user.")
  path = Path(args.key_path).expanduser().absolute()
  reject_symlinks(path)
  if not shutil.which("ssh-keygen"):
    raise SetupError("Install the OpenSSH client to obtain ssh-keygen.")
  if path.exists() or Path(str(path) + ".pub").exists():
    if not path.is_file() or not Path(str(path) + ".pub").is_file():
      raise SetupError("An incomplete key pair exists; it will not be replaced.")
    say("Reusing the existing key pair; no key was overwritten.")
  else:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    say("ssh-keygen will ask for a passphrase. Set a strong passphrase.")
    run([
      "ssh-keygen", "-t", "ed25519", "-a", "100", "-f", path,
      "-C", f"{pwd.getpwuid(os.getuid()).pw_name}@{socket.gethostname()}",
    ], live=True, timeout=None)
  text, fingerprint = read_public_key(str(path) + ".pub")
  table("Client authentication", [
    ("Private key, stays on client", path),
    ("Public key, copy to server", str(path) + ".pub"),
    ("Public key fingerprint", fingerprint),
  ])
  say("\nPublic key:\n" + text)
  say("\nLoad the private key into an existing agent, if desired:\n" +
      shlex.join(["ssh-add", str(path)]))


# --- Managed configuration and validation ------------------------------------

def configuration(user, port):
  # Keep modern OpenSSH algorithm defaults; no obsolete cipher lists.
  return f"""# Managed by ssh-remote-helper.py; restore from its backup.
Port {port}
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::
AllowUsers {user}
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthorizedKeysFile .ssh/authorized_keys
StrictModes yes
UsePAM yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
GatewayPorts no
LogLevel VERBOSE
"""


def reject_match_blocks(path, stack=None):
  """Refuse conditional policies instead of silently overriding their intent."""
  stack = set() if stack is None else stack
  resolved = path.resolve()
  if resolved in stack or len(stack) > 20:
    raise SetupError("Recursive or excessively deep sshd Include configuration.")
  if not path.exists():
    return
  stack = stack | {resolved}
  for line in path.read_text(encoding="utf-8").splitlines():
    try:
      words = shlex.split(line, comments=True)
    except ValueError as error:
      raise SetupError(f"Cannot parse SSH configuration: {path}") from error
    if not words:
      continue
    directive = words[0].lower()
    if directive == "match":
      raise SetupError(
        f"Existing Match block in {path}. This personal-host helper refuses "
        "conditional policies; configure that installation manually."
      )
    if directive == "include":
      for pattern in words[1:]:
        if not Path(pattern).is_absolute():
          pattern = str(CONFIG.parent / pattern)
        for child in glob.glob(pattern):
          reject_match_blocks(Path(child), stack)


def effective_configuration(binary, user):
  result = run([
    binary, "-T", "-C", f"user={user},host=localhost,addr=127.0.0.1",
  ])
  values = {}
  for line in result.stdout.splitlines():
    key, _, value = line.partition(" ")
    values.setdefault(key.lower(), []).append(value.strip())
  return values


def verify_configuration(binary, user, port):
  validation = run([binary, "-t"], check=False)
  # On Debian, systemd creates /run/sshd only when the service starts. Test mode
  # also needs it. Recreate only this known runtime directory, never an
  # arbitrary path parsed from stderr; it does not contain configuration.
  if (validation.returncode and
      "Missing privilege separation directory: /run/sshd" in validation.stderr):
    runtime = Path("/run/sshd")
    reject_symlinks(runtime)
    if not runtime.exists():
      runtime.mkdir(mode=0o755)
      os.chown(runtime, 0, 0)
    validation = run([binary, "-t"], check=False)
  if validation.returncode:
    raise SetupError("SSH test failed: " + validation.stderr.strip())
  values = effective_configuration(binary, user)
  expected = {
    "permitrootlogin": "no", "pubkeyauthentication": "yes",
    "passwordauthentication": "no", "kbdinteractiveauthentication": "no",
    "authenticationmethods": "publickey", "strictmodes": "yes",
    "authorizedkeysfile": ".ssh/authorized_keys", "usepam": "yes",
    "forcecommand": "none", "chrootdirectory": "none",
    "authorizedkeyscommand": "none",
  }
  for name, value in expected.items():
    if values.get(name) != [value]:
      raise SetupError(f"Effective SSH setting conflicts: {name}.")
  users = " ".join(values.get("allowusers", [])).split()
  if set(users) != {user}:
    raise SetupError("Existing AllowUsers adds accounts; review it manually.")
  for restriction in ("denyusers", "allowgroups", "denygroups"):
    if values.get(restriction):
      raise SetupError(f"Existing {restriction} needs manual review.")
  if set(values.get("port", [])) != {str(port)}:
    raise SetupError("Another Port directive exists; review it manually.")
  listeners = values.get("listenaddress", [])
  if not listeners or any(
    value not in {f"0.0.0.0:{port}", f"[::]:{port}"} for value in listeners
  ):
    raise SetupError("Existing ListenAddress conflicts with the chosen port.")
  return values


def service_for(requested=None):
  names = [requested] if requested else ["sshd", "ssh"]
  for name in names:
    unit = f"{name}.service"
    loaded = run([
      "systemctl", "show", "-p", "LoadState", "--value", unit,
    ], check=False).stdout.strip()
    if loaded == "loaded":
      return unit
  raise SetupError("No sshd/ssh systemd service found; use --service if needed.")


def service_state(service):
  enabled = run([
    "systemctl", "is-enabled", service,
  ], check=False).stdout.strip()
  active = run([
    "systemctl", "is-active", service,
  ], check=False).stdout.strip() == "active"
  return {"active": active, "enabled": enabled}


def service_preflight(service):
  if service_state(service)["enabled"] not in {
    "enabled", "enabled-runtime", "disabled",
  }:
    raise SetupError("SSH service is masked or has an unsupported unit state.")
  for unit in ("ssh.socket", "sshd.socket"):
    state = service_state(unit)
    if state["active"] or state["enabled"] in {"enabled", "enabled-runtime"}:
      raise SetupError(
        f"{unit} uses socket activation. Follow the guide's daemon-service "
        "conversion before applying this helper."
      )
  start = run([
    "systemctl", "show", "-p", "ExecStart", "--value", service,
  ]).stdout
  if re.search(r"(?:^|\s)-(?:f|p|o)(?:\s|\S)", start):
    raise SetupError("SSH unit command-line overrides require manual review.")
  for path, variable in (
    (Path("/etc/default/ssh"), "SSHD_OPTS"),
    (Path("/etc/sysconfig/sshd"), "OPTIONS"),
  ):
    if path.exists():
      for line in path.read_text(encoding="utf-8").splitlines():
        if re.match(rf"\s*(?:export\s+)?{variable}\s*=", line):
          value = line.split("=", 1)[1].strip().strip("\"'")
          if value and not value.startswith("#"):
            raise SetupError(f"Nonempty {variable} in {path}; review manually.")


# --- Atomic writes, backup journal and conservative restoration ---------------

def reject_symlinks(path):
  for component in (path, *path.parents):
    if component.is_symlink():
      raise SetupError(f"Refusing to write through a symbolic link: {component}")


def file_hash(path):
  return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def atomic_write(path, data, mode=0o600, uid=0, gid=0):
  reject_symlinks(path)
  descriptor, temporary = tempfile.mkstemp(
    prefix=".ssh-helper-", dir=path.parent,
  )
  try:
    with os.fdopen(descriptor, "wb") as stream:
      stream.write(data)
      stream.flush()
      os.fsync(stream.fileno())
      os.fchmod(stream.fileno(), mode)
      os.fchown(stream.fileno(), uid, gid)
    os.replace(temporary, path)
  finally:
    if os.path.exists(temporary):
      os.unlink(temporary)


def snapshot(path, directory=False):
  reject_symlinks(path)
  entry = {"path": str(path), "exists": path.exists(), "directory": directory}
  if path.exists():
    metadata = path.stat()
    correct = path.is_dir() if directory else path.is_file()
    if not correct or (not directory and metadata.st_nlink != 1):
      raise SetupError(f"Expected a regular, unlinked file/directory: {path}")
    entry.update(mode=stat.S_IMODE(metadata.st_mode), uid=metadata.st_uid,
                 gid=metadata.st_gid)
    if not directory:
      entry["data"] = base64.b64encode(path.read_bytes()).decode("ascii")
  return entry


def backup_files(user, service):
  ssh_dir = Path(user.pw_dir) / ".ssh"
  entries = [snapshot(path) for path in (
    CONFIG, MANAGED, ssh_dir / "authorized_keys",
  )]
  entries.append(snapshot(ssh_dir, directory=True))
  reject_symlinks(STATE)
  STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
  os.chmod(STATE.parent, 0o700)
  os.chmod(STATE, 0o700)
  stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
  directory = STATE / f"{stamp}-{uuid.uuid4().hex[:8]}"
  directory.mkdir(mode=0o700)
  journal = {
    "version": 1, "user": user.pw_name, "service": service,
    "service_before": service_state(service), "files": entries,
    "deployed_hashes": {}, "completed": False,
  }
  atomic_write(directory / "backup.json", json.dumps(journal).encode())
  return directory, journal


def restore_files(journal):
  # Restore files before attempting to remove a newly created .ssh directory.
  for entry in journal["files"]:
    path = Path(entry["path"])
    reject_symlinks(path)
    if entry["directory"]:
      if entry["exists"]:
        os.chmod(path, entry["mode"])
        os.chown(path, entry["uid"], entry["gid"])
      elif path.exists():
        try:
          path.rmdir()
        except OSError:
          say(f"Kept nonempty directory: {path}")
    elif entry["exists"]:
      atomic_write(path, base64.b64decode(entry["data"]), entry["mode"],
                   entry["uid"], entry["gid"])
    elif path.exists():
      path.unlink()


def restore_service(journal):
  service = journal["service"]
  before = journal["service_before"]
  if before["active"]:
    run([sshd_path(), "-t"])
    action = "reload" if service_state(service)["active"] else "start"
    run(["systemctl", action, service])
  else:
    run(["systemctl", "stop", service])
  run(["systemctl", "disable", service])
  if before["enabled"] in {"enabled", "enabled-runtime"}:
    command = ["systemctl", "enable"]
    if before["enabled"] == "enabled-runtime":
      command.append("--runtime")
    run(command + [service])


def restore_backup(args):
  require_root()
  if args.backup == "latest":
    candidates = sorted(STATE.glob("*/backup.json"))
    if not candidates:
      raise SetupError("No helper backups found.")
    directory = candidates[-1].parent
  else:
    directory = Path(args.backup).expanduser().absolute()
  reject_symlinks(directory)
  if directory.parent.resolve() != STATE.resolve():
    raise SetupError(f"Select a direct backup directory under {STATE}.")
  journal_path = directory / "backup.json"
  reject_symlinks(journal_path)
  journal = json.loads(journal_path.read_text(encoding="utf-8"))
  user = account(journal["user"])
  expected = {str(CONFIG), str(MANAGED),
              str(Path(user.pw_dir) / ".ssh" / "authorized_keys"),
              str(Path(user.pw_dir) / ".ssh")}
  actual = {item["path"] for item in journal["files"]}
  if (journal.get("version") != 1 or actual != expected or
      journal["service"] not in {"sshd.service", "ssh.service"}):
    raise SetupError("Invalid backup journal or account home has changed.")
  if not args.force:
    for path, deployed in journal.get("deployed_hashes", {}).items():
      if file_hash(Path(path)) != deployed:
        raise SetupError(
          f"Changed since setup: {path}. Review before using restore --force."
        )
  table("Restore plan", [("Backup", directory),
                         ("Service", journal["service"]),
                         ("Files and metadata", ", ".join(sorted(expected)))])
  if not args.apply:
    say("Preview only. Add --apply to restore these files and service state.")
    return
  restore_files(journal)
  restore_service(journal)
  say("Restored SSH files and their previous service state.")
  say("Packages, host keys, Tailscale login and manual firewall rules remain.")


# --- Package preparation and Tailscale login ----------------------------------

def prepare_dependencies(mode, install):
  required = ["ip", "ssh-keygen"]
  if mode == "tailscale":
    required.append("tailscale")
  missing = [program for program in required if not shutil.which(program)]
  try:
    sshd_path()
  except SetupError:
    missing.append("sshd")
  if not missing:
    return
  if not install:
    raise SetupError(
      f"Missing: {', '.join(missing)}. Install prerequisites or use --install."
    )
  if shutil.which("pacman"):
    packages = ["openssh", "iproute2"]
    if mode == "tailscale":
      packages.append("tailscale")
    run(["pacman", "-Syu", "--needed", *packages], live=True, timeout=None)
  elif shutil.which("apt-get"):
    run(["apt-get", "update"], live=True, timeout=None)
    run(["apt-get", "install", "openssh-server", "iproute2"],
        live=True, timeout=None)
    if mode == "tailscale" and not shutil.which("tailscale"):
      raise SetupError("Install Tailscale from its official Linux instructions.")
  elif shutil.which("dnf"):
    run(["dnf", "install", "openssh-server", "openssh-clients", "iproute"],
        live=True, timeout=None)
    if mode == "tailscale" and not shutil.which("tailscale"):
      raise SetupError("Install Tailscale from its official Linux instructions.")
  else:
    raise SetupError("Unsupported package manager; install packages manually.")
  if any(not shutil.which(program) for program in required):
    raise SetupError("Dependencies are still missing after installation.")


def prepare_tailscale():
  run(["systemctl", "enable", "--now", "tailscaled.service"])
  status = tailscale_state()
  if status["ssh_enabled"] is True:
    raise SetupError(
      "Tailscale SSH is enabled. For ordinary OpenSSH, first run "
      "sudo tailscale set --ssh=false, then rerun setup."
    )
  if status["state"] != "Running":
    say("Authenticate this server to your Tailscale account in the shown URL.")
    run(["tailscale", "up", "--timeout=60s"], live=True, timeout=75)
    status = tailscale_state()
  if status["state"] != "Running" or not status["ip"]:
    raise SetupError("Tailscale is not connected. Complete tailscale up first.")
  return status


def check_local_banner(port):
  for _ in range(12):
    try:
      with socket.create_connection(("127.0.0.1", port), timeout=0.5) as sock:
        sock.settimeout(0.5)
        if sock.recv(128).startswith(b"SSH-2.0-"):
          return
    except OSError:
      pass
    time.sleep(0.25)
  raise SetupError("No local SSH banner; check service logs and port conflicts.")


def host_fingerprints(user):
  """Prefer host identities selected by the actual effective configuration."""
  try:
    values = effective_configuration(sshd_path(), user)
    paths = [Path(path) for path in values.get("hostkey", [])]
    verified = True
  except SetupError:
    paths = sorted(CONFIG.parent.glob("ssh_host_*_key.pub"))
    verified = False
  rows = []
  for path in paths:
    public = Path(str(path) + ".pub")
    try:
      target = public if public.is_file() else path
      result = run(["ssh-keygen", "-lf", target], check=False)
      fingerprint = result.stdout.strip()
      if fingerprint:
        rows.append((str(target), fingerprint))
    except OSError:
      continue
  return verified, rows


# --- Human-readable connection report and firewall commands -------------------

def firewall_commands(args, info):
  interface = "tailscale0" if args.mode == "tailscale" else info["interface"]
  status = firewall_info(interface)
  commands = []
  port = args.port or 22
  if args.mode == "tailscale":
    commands.append(shlex.join([
      "sudo", "ufw", "allow", "in", "on", "tailscale0", "proto", "tcp",
      "to", "any", "port", str(port),
    ]))
  elif args.source_cidr:
    commands.append(shlex.join([
      "sudo", "ufw", "allow", "proto", "tcp", "from", args.source_cidr,
      "to", "any", "port", str(port),
    ]))
  else:
    commands.append(shlex.join(["sudo", "ufw", "allow", f"{port}/tcp"]))
  zone = status["zone"]
  if zone and re.fullmatch(r"[A-Za-z0-9_-]+", zone):
    destination = info["tailscale"]["ip"] if args.mode == "tailscale" else None
    if destination or args.source_cidr:
      source = args.source_cidr or "100.64.0.0/10"
      family = f"ipv{ipaddress.ip_network(source).version}"
      rule = f'rule family="{family}" source address="{source}" '
      if destination:
        rule += f'destination address="{destination}" '
      rule += f'port port="{port}" protocol="tcp" accept'
      switch = f"--add-rich-rule={rule}"
    else:
      switch = f"--add-port={port}/tcp"
    for permanent in (False, True):
      command = ["sudo", "firewall-cmd", f"--zone={zone}"]
      if permanent:
        command.append("--permanent")
      commands.append(shlex.join(command + [switch]))
  return status, commands


def report(args, user, info, *, configured=False):
  port = args.port or 22
  identity = args.client_identity
  tail = info["tailscale"]
  rows = [
    ("Server hostname", info["hostname"]), ("Linux login", user.pw_name),
    ("Requested server TCP port", port),
    ("Private-key path on CLIENT", identity),
    ("Outbound route interface", info["interface"] or "unknown"),
    ("Outbound route source IPv4", info["route_ip"] or "unknown"),
    ("Route gateway", info["gateway"] or "none/unknown"),
    ("Observed egress IPv4", info["egress_ipv4"] or "skipped/unavailable"),
    ("Tailscale state", tail["state"]),
    ("Tailscale IPv4", tail["ip"] or "unavailable"),
    ("Tailscale DNS name", tail["dns"] or "unavailable"),
    ("WAN/NAT assessment", nat_explanation(args.router_wan,
                                          info["egress_ipv4"])),
  ]
  for entry in info["addresses"]:
    rows.append((f"{entry['interface']} {entry['family']}",
                 f"{entry['ip']}/{entry['prefix']}"))
  table("Server and network", rows)
  say("\nAuthentication: the matching private key on the CLIENT, "
      "unlocked by its passphrase. No server password is retrieved.")
  say("The client identity path is a setting, not a discovered private key; "
      "change --client-identity if you use a different client key path.")
  key_file = Path(user.pw_dir) / ".ssh" / "authorized_keys"
  try:
    if key_file.exists():
      fingerprints = run(["ssh-keygen", "-lf", key_file], check=False).stdout
      if fingerprints.strip():
        say("Authorized public key fingerprints:\n" + fingerprints.strip())
  except OSError:
    say("Authorized-key fingerprints unavailable: the key directory is "
        "not readable. Inspect as its owner or with sudo on the server.")
  verified_hostkeys, fingerprints = host_fingerprints(user.pw_name)
  if not verified_hostkeys:
    say("Effective host identity unavailable; any default host fingerprints "
        "below require confirmation against the running daemon.")
  for path, fingerprint in fingerprints:
    say(f"Host fingerprint ({path}): {fingerprint}")
  if not fingerprints:
    say("No host fingerprints could be read; verify on the server with sudo.")
  say("Compare the host fingerprint through this trusted server terminal.")
  if info["route_ip"]:
    say("\nLAN command (check the listed interface is your actual LAN):\n" +
        connection_command(user.pw_name, info["route_ip"], port, identity))
  if args.mode == "tailscale":
    if tail["ip"]:
      say("\nRemote command, with Tailscale connected on BOTH devices:\n" +
          connection_command(user.pw_name, tail["ip"], port, identity))
      if tail["dns"]:
        say("MagicDNS alternative, when enabled:\n" +
            connection_command(user.pw_name, tail["dns"], port, identity))
    else:
      say("\nRemote command pending: connect this server to Tailscale first.")
  else:
    endpoint = args.endpoint or info["egress_ipv4"]
    if endpoint:
      remote_port = args.external_port
      try:
        if ipaddress.ip_address(endpoint).version == 6:
          remote_port = port
      except ValueError:
        pass
      say("\nPublic command, AFTER forwarding/firewall and off-site testing:\n" +
          connection_command(user.pw_name, endpoint, remote_port, identity))
      if not args.endpoint:
        say("Egress IP is a candidate only; VPN/CGNAT may make it unusable.")
    address = info["route_ip"] or "SERVER_LAN_IPV4"
    say(f"Router TCP rule: external {args.external_port} -> {address}:{port}")
    say("Reserve the server LAN address in DHCP. Forward TCP, not UDP.")
    say("For a public IPv6 endpoint, connect to the SERVER's global IPv6 "
        "and its server port; IPv4 router forwarding does not apply.")
  status, commands = firewall_commands(args, info)
  say("\nFirewall status: " + (status["ufw"] or "UFW unavailable/not readable"))
  say("firewalld: " + (status["firewalld"] or "unavailable/not readable"))
  say("Run ONLY the commands for the firewall you actually use:")
  for command in commands:
    say(command)
  say("The helper does not enable/reset a firewall or change router rules. "
      "Existing broader firewall rules may still allow other interfaces.")
  if args.mode == "tailscale":
    say("OpenSSH listens on local IPv4/IPv6 interfaces; Tailscale does not "
        "make those listeners private. Avoid public forwarding and audit "
        "the host's input firewall, especially on public Wi-Fi.")
  if configured:
    say("\nVerified: key-only settings, running service and local SSH banner.")
  else:
    say("\nInspection only: commands use the requested settings; setup and "
        "remote login have not been verified.")
  say("Final check: connect from a DIFFERENT network using the client key. "
      "Local success cannot establish Internet reachability.")
  if args.report:
    output = Path(args.report).expanduser().absolute()
    reject_symlinks(output)
    if not output.parent.is_dir():
      raise SetupError("The report's parent directory must already exist.")
    content = {"user": user.pw_name, "server_port": port,
               "client_identity": identity,
               "mode": args.mode, "external_port": args.external_port,
               "endpoint": args.endpoint, "network": info,
               "local_setup_verified": configured,
               "external_access_verified": False}
    atomic_write(output, (json.dumps(content, indent=2) + "\n").encode(),
                 uid=os.geteuid(), gid=os.getegid())
    say(f"Connection details saved with mode 600: {output}")


# --- Setup orchestration ------------------------------------------------------

def setup(args):
  user = account(args.user)
  args.port = args.port or 22
  if args.mode == "tailscale" and args.source_cidr:
    raise SetupError("--source-cidr is public-mode only; use tailnet policy.")
  if args.public_key:
    key, fingerprint = read_public_key(args.public_key)
  else:
    key = fingerprint = None
  table("Setup plan", [
    ("Mode", args.mode), ("Linux account", user.pw_name),
    ("Server TCP port", args.port),
    ("Public external TCP port", args.external_port),
    ("Public key", fingerprint or "required before --apply"),
    ("Private-key path on CLIENT", args.client_identity),
    ("Managed settings", MANAGED), ("Main configuration", CONFIG),
    ("Authentication", "public key only; root login disabled"),
    ("SSH login accounts", "only the selected account"),
    ("Firewall/router", "commands generated; manual application"),
  ])
  if not args.apply:
    say("\nPreview only: no server configuration or services are changed.")
    say("\nProposed managed configuration:\n" + configuration(user.pw_name,
                                                               args.port))
    report(args, user, network_info(args.no_public_ip))
    return
  require_root()
  if not key:
    raise SetupError("--public-key CLIENT_KEY.pub is required before --apply.")
  home = Path(user.pw_dir)
  reject_symlinks(home)
  if (not home.is_dir() or home.stat().st_uid != user.pw_uid or
      stat.S_IMODE(home.stat().st_mode) & 0o022):
    raise SetupError("Login home must be user-owned and not writable by others.")
  reject_symlinks(CONFIG)
  reject_symlinks(MANAGED)
  if CONFIG.exists():
    reject_match_blocks(CONFIG)
  prepare_dependencies(args.mode, args.install)
  binary = sshd_path()
  service = service_for(args.service)
  service_preflight(service)
  if args.mode == "tailscale":
    prepare_tailscale()
  run(["ssh-keygen", "-A"])
  ssh_dir = home / ".ssh"
  authorized = ssh_dir / "authorized_keys"
  reject_symlinks(authorized)
  existing = (authorized.read_text(encoding="utf-8")
              if authorized.exists() else "")
  updated_keys = key_contents(existing, key)
  original = (CONFIG.read_text(encoding="utf-8") if CONFIG.exists() else
              "Subsystem sftp internal-sftp\n")
  if not original.startswith(INCLUDE):
    original = INCLUDE + original
  # Configuration and authorized_keys roll back together if any check fails.
  directory, journal = backup_files(user, service)
  try:
    ssh_dir.mkdir(mode=0o700, exist_ok=True)
    os.chmod(ssh_dir, 0o700)
    os.chown(ssh_dir, user.pw_uid, user.pw_gid)
    atomic_write(authorized, updated_keys.encode(), 0o600,
                 user.pw_uid, user.pw_gid)
    atomic_write(MANAGED, configuration(user.pw_name, args.port).encode(), 0o600)
    atomic_write(CONFIG, original.encode(), 0o600)
    verify_configuration(binary, user.pw_name, args.port)
    if journal["service_before"]["active"]:
      run(["systemctl", "reload", service])
    else:
      run(["systemctl", "start", service])
    run(["systemctl", "enable", service])
    if not service_state(service)["active"]:
      raise SetupError("SSH service did not become active.")
    check_local_banner(args.port)
    journal["deployed_hashes"] = {
      entry["path"]: file_hash(Path(entry["path"]))
      for entry in journal["files"] if not entry["directory"]
    }
    journal["completed"] = True
    atomic_write(directory / "backup.json", json.dumps(journal).encode())
  except BaseException as original_error:
    say("Setup failed; restoring the saved SSH files and service state.")
    try:
      restore_files(journal)
      restore_service(journal)
    except Exception as recovery_error:
      say(f"Recovery needs attention: {recovery_error}")
      say(f"Recovery backup: {directory}")
    raise original_error
  say(f"\nSSH configuration applied. Recovery backup: {directory}")
  say("Restore preview:\n" + shlex.join([
    "sudo", "python3", str(Path(__file__).absolute()), "restore",
    "--backup", str(directory),
  ]))
  report(args, user, network_info(args.no_public_ip), configured=True)


# --- Command-line interface and extended help ---------------------------------

LONG_HELP = r"""
QUICK START (Arch Linux)
  sudo pacman -Syu --needed openssh iproute2 python python-rich tailscale

CLIENT: create a passphrase-protected key without sudo.
  python3 ssh-remote-helper.py client-key
  # Copy ONLY ~/.ssh/id_ed25519_remote.pub to the server.

SERVER: preview, then apply for your existing Linux account.
  python3 ssh-remote-helper.py setup --user heini \
    --public-key /path/to/client-key.pub
  sudo python3 ssh-remote-helper.py setup --apply --user heini \
    --public-key /path/to/client-key.pub --mode tailscale

PUBLIC IPv4: forwarding external 2222 to server port 22.
  sudo python3 ssh-remote-helper.py setup --apply --user heini \
    --public-key /path/to/client-key.pub --mode public \
    --external-port 2222 --endpoint YOUR_PUBLIC_IP_OR_DNS

DIAGNOSTICS: host network and addresses; no configuration changes.
  python3 ssh-remote-helper.py inspect --user heini
  sudo python3 ssh-remote-helper.py inspect --mode public --user heini \
    --router-wan 100.64.12.34 --report /home/heini/ssh-details.json

RESTORE: preview first; add --apply to restore the tracked files.
  sudo python3 ssh-remote-helper.py restore --backup latest
  sudo python3 ssh-remote-helper.py restore --backup latest --apply

BEHAVIOUR AND LIMITS
  * Default setup is a preview. Only --apply changes SSH configuration.
  * Intended for a personal Linux host with systemd and one SSH login account.
  * Prepends an Include; retains the original file and included files.
  * Refuses Match policies, conflicting ports/users/listeners, socket activation
    and custom daemon flags. Existing keys are preserved, never overwritten.
  * Rich is optional. Python's standard library provides the plain-text fallback.
  * --install permits package installation, including a full pacman -Syu on Arch.
    Debian/Fedora still need Tailscale installed from its official instructions.
  * The server uses normal OpenSSH over Tailscale, not Tailscale SSH. Setup can
    start tailscaled and request browser authentication; it never stores a token.
  * SSH listens on local IPv4/IPv6 interfaces. Firewall scope is your decision.
    Firewall commands are printed; rules and router forwarding are not mutated.
  * Public egress lookups contact HTTPS IP services unless --no-public-ip is set.
    The reported egress address is not proof of inbound reachability or CGNAT.
  * --router-wan requires the IPv4 displayed in the router's Internet/WAN page.
  * Key passwords cannot be retrieved. A client private key and its passphrase
    are the credentials; the Linux username comes from the server account.
  * --client-identity sets a path on the CLIENT, never read by the server. Its
    default matches client-key: ~/.ssh/id_ed25519_remote.
  * Keep local console access and test a NEW client connection before closing
    the existing session. Validation cannot prove possession of the private key.
  * Restoration covers SSH configuration, authorized_keys and service state.
    It keeps packages, generated host keys, Tailscale login and manual rules.
  * Repeated apply does not duplicate keys/Includes; each apply has a backup.
  * No sleep/lid/power settings are changed. A sleeping host cannot accept SSH.

Read sshd-outside-network-guide.md for client configuration and troubleshooting.
"""


def parser():
  result = argparse.ArgumentParser(
    description="Inspect and configure key-only remote OpenSSH on Linux.",
    formatter_class=argparse.RawDescriptionHelpFormatter,
  )
  result.add_argument("--long-help", action="store_true",
                      help="show examples, behaviour and operational limits")
  commands = result.add_subparsers(dest="action")
  key = commands.add_parser("client-key", help="generate a key on the CLIENT")
  key.add_argument("--key-path", default="~/.ssh/id_ed25519_remote",
                   help="new client private-key path; existing pairs are reused")
  for name in ("inspect", "setup"):
    action = commands.add_parser(name, help=(
      "report network information" if name == "inspect" else
      "preview/apply a personal-host SSH configuration"
    ))
    action.add_argument("--user", help="Linux user; default: caller/sudo caller")
    action.add_argument("--mode", choices=("tailscale", "public"),
                        default="tailscale")
    action.add_argument("--port", type=port_number, default=None,
                        help="server SSH TCP port (default: 22)")
    action.add_argument("--external-port", type=port_number, default=2222,
                        help="public IPv4 router port (default: 2222)")
    action.add_argument("--endpoint", type=endpoint_name,
                        help="public IP/DNS; otherwise use observed egress IPv4")
    action.add_argument("--client-identity",
                        default="~/.ssh/id_ed25519_remote",
                        help="private-key path on CLIENT; never read on server")
    action.add_argument("--router-wan", type=ipaddress.IPv4Address,
                        help="router WAN IPv4, for upstream NAT/CGNAT diagnosis")
    action.add_argument("--source-cidr",
                        help="public-mode firewall source, e.g. CLIENT_IP/32")
    action.add_argument("--no-public-ip", action="store_true",
                        help="skip external HTTPS egress-address requests")
    action.add_argument("--report", help="connection report JSON, mode 600")
    if name == "setup":
      action.add_argument("--public-key", help="one CLIENT OpenSSH .pub file")
      action.add_argument("--service", choices=("ssh", "sshd"),
                          help="override auto-detected standard systemd service")
      action.add_argument("--install", action="store_true",
                          help="allow installation of missing packages")
      action.add_argument("--apply", action="store_true",
                          help="apply configuration; absent means preview only")
  restore = commands.add_parser("restore", help="preview/restore a setup backup")
  restore.add_argument("--backup", required=True,
                       help="backup directory printed by setup, or latest")
  restore.add_argument("--apply", action="store_true", help="apply restoration")
  restore.add_argument("--force", action="store_true",
                       help="overwrite tracked files modified since setup")
  return result


def main(argv=None):
  argument_parser = parser()
  args = argument_parser.parse_args(argv)
  if args.long_help:
    say(argument_parser.format_help())
    say(LONG_HELP)
    return 0
  if not args.action:
    argument_parser.print_help()
    return 0
  try:
    if getattr(args, "router_wan", None):
      args.router_wan = str(args.router_wan)
    if getattr(args, "source_cidr", None):
      args.source_cidr = str(ipaddress.ip_network(
        args.source_cidr, strict=False,
      ))
    if args.action == "client-key":
      client_key(args)
    elif args.action == "setup":
      setup(args)
    elif args.action == "inspect":
      report(args, account(args.user), network_info(args.no_public_ip))
    else:
      restore_backup(args)
    return 0
  except KeyboardInterrupt:
    say("Interrupted.")
    return 130
  except (SetupError, OSError, ValueError) as error:
    say(f"ERROR: {error}")
    return 1


if __name__ == "__main__":
  raise SystemExit(main())
