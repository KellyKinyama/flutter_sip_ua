/// Native implementation of [discoverLocalIpv4].
///
/// When [targetHost] is provided, we ask the OS for the address it would
/// actually use to reach that peer by opening a short-lived TCP socket
/// toward it and reading back the socket's local address. This is the
/// only reliable way on multi-homed machines (Windows laptops with WSL,
/// Docker, Hyper-V, VPN adapters, etc.) where `NetworkInterface.list()`
/// returns interfaces in arbitrary order and the first non-loopback IPv4
/// is very often a virtual adapter unreachable from the real LAN.
///
/// Falls back to enumerating interfaces when the target probe fails (no
/// route, no DNS, port closed, etc.).
library;

import 'dart:io';

/// One IPv4 address belonging to a named interface. Pure data type so
/// [pickBestIpv4] can be unit-tested without touching real sockets.
class IfaceAddr {
  const IfaceAddr(this.ifaceName, this.address);
  final String ifaceName;
  final String address;
}

Future<String?> discoverLocalIpv4({
  String? targetHost,
  int targetPort = 0,
  void Function(String line)? debug,
}) async {
  String? targetIp;
  // Dump all candidate interfaces up-front so callers can see what the
  // picker had to choose among.
  if (debug != null) {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: true,
        type: InternetAddressType.IPv4,
      );
      debug('iface enumeration (${ifaces.length} interfaces):');
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          final virt = _looksVirtual(iface.name) || _isKnownVirtualIp(a.address)
              ? ' [virtual]'
              : '';
          final rfc = _isRfc1918(a.address) ? ' [rfc1918]' : '';
          debug('  - ${iface.name}: ${a.address}$virt$rfc');
        }
      }
    } catch (e) {
      debug('iface enumeration failed: $e');
    }
  }
  if (targetHost != null && targetHost.isNotEmpty) {
    // NOTE: a TCP route probe is tempting here but `Socket.address` in
    // dart:io returns the REMOTE endpoint, not the local source IP, so
    // it can't actually tell us which interface Windows would send from.
    // Resolve the target so the picker can prefer same-subnet addresses.
    if (_looksLikeIpv4(targetHost)) {
      targetIp = targetHost;
    } else {
      try {
        final addrs = await InternetAddress.lookup(
          targetHost,
          type: InternetAddressType.IPv4,
        );
        if (addrs.isNotEmpty) targetIp = addrs.first.address;
      } catch (_) {}
    }
    debug?.call(
      'targetIp for picker preference: ${targetIp ?? "<unresolved>"}',
    );
  }
  final picked = await _firstUsableInterface(targetIp: targetIp);
  debug?.call('picker chose: ${picked ?? "<none>"}');
  return picked;
}

/// Open a short-lived TCP socket toward [host] (trying [port] first, then
/// a small set of likely-open SIP/HTTP ports) and return the local
/// address the OS chose for that route. Returns `null` if no port
/// answered before the timeout.
///
/// Public so tests can target a server bound to `localhost`.
Future<String?> probeRouteTo(String host, int port) async {
  final candidatePorts = <int>{if (port > 0) port, 7443, 7080, 5060, 80, 443};
  for (final p in candidatePorts) {
    try {
      final sock = await Socket.connect(
        host,
        p,
        timeout: const Duration(milliseconds: 400),
      );
      final addr = sock.address.address;
      // ignore: discarded_futures
      sock.destroy();
      if (addr.isNotEmpty && addr != '0.0.0.0') return addr;
    } catch (_) {
      // try next port
    }
  }
  return null;
}

Future<String?> _firstUsableInterface({String? targetIp}) async {
  try {
    final ifaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    final flat = <IfaceAddr>[
      for (final iface in ifaces)
        for (final a in iface.addresses)
          if (a.type == InternetAddressType.IPv4 && !a.isLoopback)
            IfaceAddr(iface.name, a.address),
    ];
    return pickBestIpv4(flat, targetIp: targetIp);
  } catch (_) {
    return null;
  }
}

/// Pure helper: pick the best candidate IPv4 from a list of interface
/// addresses, preferring real physical adapters over obvious virtual
/// ones (WSL / Hyper-V / Docker / VirtualBox / VMware vEthernet). Within
/// the "real" group, when [targetIp] is supplied we prefer an interface
/// in the same RFC1918 prefix as the target (so reaching `10.1.101.155`
/// from a host with both a `10.x.x.x` and a `192.168.x.x` NIC picks the
/// `10.x` one). Otherwise RFC1918 LAN ranges win over anything else so
/// that a machine with both a public IPv6 and a LAN IPv4 still puts a
/// LAN IP in SDP (the PBX wouldn't route public IPv4 from a private peer
/// anyway).
String? pickBestIpv4(Iterable<IfaceAddr> candidates, {String? targetIp}) {
  IfaceAddr? bestReal;
  IfaceAddr? bestVirtual;
  for (final c in candidates) {
    if (c.address.isEmpty) continue;
    if (_looksVirtual(c.ifaceName) || _isKnownVirtualIp(c.address)) {
      bestVirtual ??= c;
      continue;
    }
    if (bestReal == null) {
      bestReal = c;
      continue;
    }
    // Target-aware: same RFC1918 prefix as the destination beats everything.
    if (targetIp != null) {
      final cMatches = _sharesPrivatePrefix(c.address, targetIp);
      final bMatches = _sharesPrivatePrefix(bestReal.address, targetIp);
      if (cMatches && !bMatches) {
        bestReal = c;
        continue;
      }
      if (bMatches && !cMatches) continue;
    }
    // Prefer RFC1918 LAN address over anything else when more than one
    // real interface exists.
    if (_isRfc1918(c.address) && !_isRfc1918(bestReal.address)) {
      bestReal = c;
    }
  }
  return (bestReal ?? bestVirtual)?.address;
}

bool _looksVirtual(String name) {
  final s = name.toLowerCase();
  return s.contains('vethernet') ||
      s.contains('virtualbox') ||
      s.contains('vmware') ||
      s.contains('vmnet') ||
      s.contains('hyper-v') ||
      s.contains('docker') ||
      s.contains('wsl') ||
      s.contains('loopback');
}

bool _isRfc1918(String ipv4) {
  final parts = ipv4.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == null || b == null) return false;
  if (a == 10) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  return false;
}

/// Addresses inside subnets that are virtually always synthetic on
/// developer machines regardless of how the OS labels the adapter.
/// Catches VirtualBox host-only (192.168.56.0/24) which Windows often
/// surfaces as a generic "Ethernet N" name that bypasses [_looksVirtual].
bool _isKnownVirtualIp(String ipv4) {
  final parts = ipv4.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  final c = int.tryParse(parts[2]);
  if (a == null || b == null || c == null) return false;
  // VirtualBox host-only default.
  if (a == 192 && b == 168 && c == 56) return true;
  // APIPA / link-local — means DHCP failed, never useful for SIP.
  if (a == 169 && b == 254) return true;
  return false;
}

bool _looksLikeIpv4(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

/// True if [a] and [b] are both RFC1918 and fall inside the same
/// canonical private prefix (10/8, 172.16/12, or 192.168/16). This is
/// the cheapest reasonable proxy for "same LAN" without netmasks.
bool _sharesPrivatePrefix(String a, String b) {
  if (!_isRfc1918(a) || !_isRfc1918(b)) return false;
  final ap = a.split('.');
  final bp = b.split('.');
  if (ap.length != 4 || bp.length != 4) return false;
  if (ap[0] != bp[0]) return false;
  // 10/8 — first octet alone is enough.
  if (ap[0] == '10') return true;
  // 172.16-31/12 — second octet must also match the /12 grouping.
  if (ap[0] == '172') return ap[1] == bp[1];
  // 192.168/16 — both are already known to be RFC1918, so equal first
  // two octets is the strongest signal we can give without netmasks.
  if (ap[0] == '192') return ap[1] == bp[1];
  return false;
}
