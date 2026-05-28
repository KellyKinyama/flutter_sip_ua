import 'dart:io';

import 'package:flutter_sip_ua/sip/local_ip_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pickBestIpv4', () {
    test('returns null on empty input', () {
      expect(pickBestIpv4(const <IfaceAddr>[]), isNull);
    });

    test('picks the LAN 10.x address over WSL vEthernet', () {
      // Realistic Windows-with-WSL layout: the OS often returns the WSL
      // vEthernet first. The picker must skip it for the real LAN IP.
      final ifaces = const [
        IfaceAddr('vEthernet (WSL)', '172.30.16.1'),
        IfaceAddr('vEthernet (Default Switch)', '172.17.32.1'),
        IfaceAddr('Ethernet', '10.1.101.42'),
      ];
      expect(pickBestIpv4(ifaces), '10.1.101.42');
    });

    test('picks Wi-Fi LAN over Docker bridge', () {
      final ifaces = const [
        IfaceAddr('vEthernet (Docker)', '172.20.0.1'),
        IfaceAddr('Wi-Fi', '192.168.1.55'),
      ];
      expect(pickBestIpv4(ifaces), '192.168.1.55');
    });

    test('prefers RFC1918 LAN over public IPv4 when both are real', () {
      // Some dual-homed boxes have a public IPv4 NIC plus a LAN NIC.
      // For SDP toward a private PBX the LAN address is what we want.
      final ifaces = const [
        IfaceAddr('Ethernet 2', '203.0.113.10'),
        IfaceAddr('Ethernet', '10.0.0.7'),
      ];
      expect(pickBestIpv4(ifaces), '10.0.0.7');
    });

    test('keeps public IPv4 when no RFC1918 alternative exists', () {
      final ifaces = const [IfaceAddr('Ethernet', '203.0.113.10')];
      expect(pickBestIpv4(ifaces), '203.0.113.10');
    });

    test('falls back to a virtual adapter only if nothing else is offered', () {
      final ifaces = const [
        IfaceAddr('vEthernet (Hyper-V)', '172.18.0.1'),
        IfaceAddr('VirtualBox Host-Only Network', '192.168.56.1'),
      ];
      // Best of the virtuals is taken (first one wins).
      expect(pickBestIpv4(ifaces), '172.18.0.1');
    });

    test('matches VMware vmnet and Docker by name', () {
      final ifaces = const [
        IfaceAddr('vmnet8', '192.168.142.1'),
        IfaceAddr('docker0', '172.17.0.1'),
        IfaceAddr('Ethernet', '10.1.101.99'),
      ];
      expect(pickBestIpv4(ifaces), '10.1.101.99');
    });

    test('ignores empty address strings', () {
      final ifaces = const [
        IfaceAddr('Ethernet', ''),
        IfaceAddr('Wi-Fi', '192.168.0.5'),
      ];
      expect(pickBestIpv4(ifaces), '192.168.0.5');
    });

    test('a single LAN-looking interface is taken as-is', () {
      final ifaces = const [IfaceAddr('eth0', '10.1.101.155')];
      expect(pickBestIpv4(ifaces), '10.1.101.155');
    });

    test(
      'rejects VirtualBox host-only 192.168.56.x by IP, not just by name',
      () {
        // Realistic Windows misreport: friendly name is just "Ethernet 3",
        // not "VirtualBox Host-Only Network", so name-based filtering misses
        // it. The 192.168.56.0/24 subnet alone must disqualify it.
        final ifaces = const [
          IfaceAddr('Ethernet 3', '192.168.56.1'),
          IfaceAddr('Wi-Fi', '10.1.101.42'),
        ];
        expect(pickBestIpv4(ifaces), '10.1.101.42');
      },
    );

    test('rejects 192.168.56.x even when no other interface is RFC1918', () {
      final ifaces = const [
        IfaceAddr('Ethernet 3', '192.168.56.1'),
        IfaceAddr('Ethernet 2', '203.0.113.10'),
      ];
      // VBox-only gets demoted to virtual bucket, public IPv4 wins.
      expect(pickBestIpv4(ifaces), '203.0.113.10');
    });

    test('prefers same-prefix LAN over other LAN when target is given', () {
      // Two real RFC1918 NICs; without target hint the picker is free to
      // pick either, but with a 10.x target it must choose the 10.x NIC.
      final ifaces = const [
        IfaceAddr('Wi-Fi', '192.168.1.55'),
        IfaceAddr('Ethernet', '10.1.101.42'),
      ];
      expect(pickBestIpv4(ifaces, targetIp: '10.1.101.155'), '10.1.101.42');
    });

    test('same-prefix preference works for 192.168/16 targets too', () {
      final ifaces = const [
        IfaceAddr('Ethernet', '10.1.101.42'),
        IfaceAddr('Wi-Fi', '192.168.1.55'),
      ];
      expect(pickBestIpv4(ifaces, targetIp: '192.168.1.200'), '192.168.1.55');
    });
  });

  group('probeRouteTo', () {
    test(
      'returns the local address used to reach a loopback listener',
      () async {
        // Bind an ephemeral TCP server on loopback and prove the probe
        // returns 127.0.0.1 (the address the kernel chose for that route).
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close();
        });
        server.listen((s) => s.destroy());

        final result = await probeRouteTo('127.0.0.1', server.port);
        expect(result, '127.0.0.1');
      },
    );

    test('returns null when no candidate port answers', () async {
      // Reserved-for-documentation address per RFC 5737; should be
      // unroutable on a typical CI/dev box, all connects time out.
      final result = await probeRouteTo('192.0.2.1', 0);
      expect(result, isNull);
    });
  });

  group('discoverLocalIpv4 (integration)', () {
    test(
      'returns SOMETHING that is not loopback when the host has a NIC',
      () async {
        // Sanity check that on this machine the discovery resolves to a
        // non-empty, non-loopback IPv4. Skipped on hosts with no NICs (CI
        // containers with only lo).
        final ifaces = await NetworkInterface.list(
          includeLoopback: false,
          includeLinkLocal: false,
          type: InternetAddressType.IPv4,
        );
        if (ifaces.isEmpty) {
          markTestSkipped('no non-loopback IPv4 interfaces on this host');
          return;
        }
        final ip = await discoverLocalIpv4();
        expect(ip, isNotNull);
        expect(ip, isNot('127.0.0.1'));
        expect(
          RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip!),
          isTrue,
          reason: 'expected dotted IPv4, got $ip',
        );
      },
    );
  });
}
