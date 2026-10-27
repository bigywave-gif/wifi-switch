import Testing
@testable import WiFiSwitch

struct DNSResolverTests {
    @Test func effectiveDNSComesFromWiFiScopedResolverNotGlobalVPNOrDomainRoutes() {
        let output = """
        DNS configuration
        resolver #1
          nameserver[0] : 198.51.100.1
        resolver #2
          domain : corp.example
          nameserver[0] : 198.51.100.2
        DNS configuration (for scoped queries)
        resolver #1
          nameserver[0] : 192.0.2.55
          nameserver[1] : 2001:db8::53
          nameserver[2] : 192.0.2.55
          if_index : 12 (en0)
          flags : Scoped, Request A records, Request AAAA records
        resolver #2
          nameserver[0] : 203.0.113.53
          if_index : 20 (utun7)
          flags : Scoped, Request A records
        resolver #3
          domain : special.example
          nameserver[0] : 192.0.2.53
          if_index : 12 (en0)
          flags : Scoped, Request A records
        DNS configuration (for service specific queries)
        resolver #1
          nameserver[0] : 192.0.2.54
          if_index : 12 (en0)
          flags : Scoped, Request A records
        """
        #expect(DNSResolverReader.servers(in: output, interface: "en0") == ["192.0.2.55", "2001:db8::53"])
        #expect(DNSResolverReader.servers(in: output, interface: "en1").isEmpty)
    }

    @Test func unreadableGlobalOnlyMulticastAndMalformedDataDoNotGuessEffectiveDNS() {
        for output in [nil, "Permission denied", "No DNS configuration available",
                       "DNS configuration\nresolver #1\n  nameserver[0] : 192.0.2.55",
                       "DNS configuration (for scoped queries)\nresolver #1\n  nameserver[0] : invalid\n  if_index : 12 (en0)\n  flags : Scoped",
                       "DNS configuration (for scoped queries)\nresolver #1\n  nameserver[0] : 224.0.0.251\n  if_index : 12 (en0)\n  flags : Scoped\n  options : mdns"] as [String?] {
            #expect(DNSResolverReader.servers(in: output, interface: "en0").isEmpty)
        }
    }

    @Test func ipv6ScopedAddressAndMultipleResolversKeepSystemOrder() {
        let output = """
        DNS configuration (for scoped queries)
        resolver #1
          nameserver[0] : fe80::1%en0
          if_index : 12 (en0)
          flags : Scoped, Request AAAA records
        resolver #2
          nameserver[0] : 192.0.2.53
          if_index : 12 (en0)
          flags : Scoped, Request A records
        """
        #expect(DNSResolverReader.servers(in: output, interface: "en0") == ["fe80::1%en0", "192.0.2.53"])
    }
}
