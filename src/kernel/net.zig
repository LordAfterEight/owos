const std = @import("std");
const owos = @import("root.zig");
const e1000 = owos.e1000;

// Network configuration (QEMU user-mode defaults)
pub const our_ip = [4]u8{ 10, 0, 2, 15 };
pub const gateway_ip = [4]u8{ 10, 0, 2, 2 };
pub const subnet_mask = [4]u8{ 255, 255, 255, 0 };
const dns_server = [4]u8{ 10, 0, 2, 3 };

const broadcast_mac = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
const zero_mac = [6]u8{ 0, 0, 0, 0, 0, 0 };

// Ethertypes
const ETH_ARP: u16 = 0x0806;
const ETH_IPV4: u16 = 0x0800;

// ARP operations
const ARP_REQUEST: u16 = 1;
const ARP_REPLY: u16 = 2;

// IP protocols
const PROTO_ICMP: u8 = 1;
const PROTO_TCP: u8 = 6;
const PROTO_UDP: u8 = 17;

// ICMP types
const ICMP_ECHO_REPLY: u8 = 0;
const ICMP_ECHO_REQUEST: u8 = 8;

// TCP flags
const TCP_FIN: u8 = 0x01;
const TCP_SYN: u8 = 0x02;
const TCP_RST: u8 = 0x04;
const TCP_PSH: u8 = 0x08;
const TCP_ACK: u8 = 0x10;

// ARP cache
const ARP_CACHE_SIZE = 16;
const ArpEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool,
};

var arp_cache: [ARP_CACHE_SIZE]ArpEntry = [1]ArpEntry{.{
    .ip = .{ 0, 0, 0, 0 },
    .mac = .{ 0, 0, 0, 0, 0, 0 },
    .valid = false,
}} ** ARP_CACHE_SIZE;

// Ping state
var ping_seq: u16 = 0;
var ping_got_reply: bool = false;
var ping_reply_ttl: u8 = 0;

// IP identification counter
var ip_id: u16 = 1;

// DNS state
const DNS_LOCAL_PORT: u16 = 54321;
var dns_response_ready: bool = false;
var dns_resolved_ip: [4]u8 = undefined;

// TCP connection state
const TcpState = enum { closed, syn_sent, established };
var tcp_state: TcpState = .closed;
var tcp_local_port: u16 = 0;
var tcp_remote_port: u16 = 0;
var tcp_remote_ip: [4]u8 = undefined;
var tcp_remote_mac: [6]u8 = undefined;
var tcp_seq: u32 = 0;
var tcp_ack: u32 = 0;
var tcp_recv_buf: [4096]u8 = undefined;
var tcp_recv_len: usize = 0;

// Ephemeral port counter
var ephemeral_port: u16 = 49152;

pub fn init() void {
    e1000.init();
}

// ── Byte-order helpers ──────────────────────────────────────────────────

fn write_be16(buf: []u8, off: usize, val: u16) void {
    buf[off] = @truncate(val >> 8);
    buf[off + 1] = @truncate(val);
}

fn read_be16(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) << 8 | buf[off + 1];
}

fn write_be32(buf: []u8, off: usize, val: u32) void {
    buf[off] = @truncate(val >> 24);
    buf[off + 1] = @truncate(val >> 16);
    buf[off + 2] = @truncate(val >> 8);
    buf[off + 3] = @truncate(val);
}

fn read_be32(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) << 24 | @as(u32, buf[off + 1]) << 16 |
        @as(u32, buf[off + 2]) << 8 | buf[off + 3];
}

// ── Internet checksum ───────────────────────────────────────────────────

fn cksum_add(sum: u32, data: []const u8) u32 {
    var s = sum;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        s += @as(u32, data[i]) << 8 | @as(u32, data[i + 1]);
    }
    if (i < data.len) {
        s += @as(u32, data[i]) << 8;
    }
    return s;
}

fn cksum_finish(sum: u32) u16 {
    var s = sum;
    s = (s >> 16) + (s & 0xFFFF);
    s += s >> 16;
    return @truncate(~s);
}

fn inet_checksum(data: []const u8) u16 {
    return cksum_finish(cksum_add(0, data));
}

/// Checksum over a pseudo-header + transport segment (TCP or UDP).
fn transport_checksum(src_ip: [4]u8, dst_ip: [4]u8, protocol: u8, segment: []const u8) u16 {
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..4], &src_ip);
    @memcpy(pseudo[4..8], &dst_ip);
    pseudo[8] = 0;
    pseudo[9] = protocol;
    write_be16(&pseudo, 10, @intCast(segment.len));
    var sum = cksum_add(0, &pseudo);
    sum = cksum_add(sum, segment);
    return cksum_finish(sum);
}

// ── IPv4 builder ────────────────────────────────────────────────────────

/// Write an IPv4 header at pkt[14..34]. Returns a slice to the full IP header.
fn build_ip_header(pkt: []u8, protocol: u8, dst_ip: [4]u8, payload_len: usize) void {
    const ip = pkt[14..];
    const ip_len: u16 = @intCast(20 + payload_len);
    ip[0] = 0x45;
    ip[1] = 0;
    write_be16(ip, 2, ip_len);
    write_be16(ip, 4, ip_id);
    ip_id +%= 1;
    write_be16(ip, 6, 0x4000); // DF
    ip[8] = 64; // TTL
    ip[9] = protocol;
    write_be16(ip, 10, 0);
    @memcpy(ip[12..16], &our_ip);
    @memcpy(ip[16..20], &dst_ip);
    write_be16(ip, 10, inet_checksum(ip[0..20]));
}

fn build_eth_header(pkt: []u8, dst_mac: [6]u8, ethertype: u16) void {
    @memcpy(pkt[0..6], &dst_mac);
    @memcpy(pkt[6..12], &e1000.mac);
    write_be16(pkt, 12, ethertype);
}

// ── ARP ─────────────────────────────────────────────────────────────────

fn arp_lookup(ip: [4]u8) ?[6]u8 {
    for (&arp_cache) |*entry| {
        if (entry.valid and ip[0] == entry.ip[0] and ip[1] == entry.ip[1] and
            ip[2] == entry.ip[2] and ip[3] == entry.ip[3])
            return entry.mac;
    }
    return null;
}

fn arp_store(ip: [4]u8, mac: [6]u8) void {
    for (&arp_cache) |*entry| {
        if (entry.valid and ip[0] == entry.ip[0] and ip[1] == entry.ip[1] and
            ip[2] == entry.ip[2] and ip[3] == entry.ip[3])
        {
            entry.mac = mac;
            return;
        }
    }
    for (&arp_cache) |*entry| {
        if (!entry.valid) {
            entry.* = .{ .ip = ip, .mac = mac, .valid = true };
            return;
        }
    }
    arp_cache[0] = .{ .ip = ip, .mac = mac, .valid = true };
}

fn send_arp_request(target_ip: [4]u8) void {
    var pkt: [42]u8 = undefined;
    @memcpy(pkt[0..6], &broadcast_mac);
    @memcpy(pkt[6..12], &e1000.mac);
    write_be16(&pkt, 12, ETH_ARP);
    write_be16(&pkt, 14, 1); // HTYPE
    write_be16(&pkt, 16, 0x0800); // PTYPE
    pkt[18] = 6;
    pkt[19] = 4;
    write_be16(&pkt, 20, ARP_REQUEST);
    @memcpy(pkt[22..28], &e1000.mac);
    @memcpy(pkt[28..32], &our_ip);
    @memcpy(pkt[32..38], &zero_mac);
    @memcpy(pkt[38..42], &target_ip);
    e1000.send(&pkt);
}

fn send_arp_reply(dst_mac: [6]u8, dst_ip: [4]u8) void {
    var pkt: [42]u8 = undefined;
    @memcpy(pkt[0..6], &dst_mac);
    @memcpy(pkt[6..12], &e1000.mac);
    write_be16(&pkt, 12, ETH_ARP);
    write_be16(&pkt, 14, 1);
    write_be16(&pkt, 16, 0x0800);
    pkt[18] = 6;
    pkt[19] = 4;
    write_be16(&pkt, 20, ARP_REPLY);
    @memcpy(pkt[22..28], &e1000.mac);
    @memcpy(pkt[28..32], &our_ip);
    @memcpy(pkt[32..38], &dst_mac);
    @memcpy(pkt[38..42], &dst_ip);
    e1000.send(&pkt);
}

fn handle_arp(data: []const u8) void {
    if (data.len < 42) return;
    const oper = read_be16(data, 20);
    const sha = data[22..28];
    const spa = data[28..32];
    const tpa = data[38..42];

    if (oper == ARP_REQUEST) {
        if (tpa[0] == our_ip[0] and tpa[1] == our_ip[1] and
            tpa[2] == our_ip[2] and tpa[3] == our_ip[3])
        {
            arp_store(spa[0..4].*, sha[0..6].*);
            send_arp_reply(sha[0..6].*, spa[0..4].*);
        }
    } else if (oper == ARP_REPLY) {
        arp_store(spa[0..4].*, sha[0..6].*);
    }
}

// ── ARP resolution helper ───────────────────────────────────────────────

fn resolve_mac(target_ip: [4]u8) ?[6]u8 {
    const next_hop = if (same_subnet(target_ip, our_ip)) target_ip else gateway_ip;
    if (arp_lookup(next_hop)) |mac| return mac;

    send_arp_request(next_hop);
    var w: usize = 0;
    while (w < 5_000_000) : (w += 1) {
        process_rx();
        if (arp_lookup(next_hop)) |mac| return mac;
    }
    return null;
}

// ── UDP ─────────────────────────────────────────────────────────────────

fn send_udp(dst_mac: [6]u8, dst_ip: [4]u8, src_port: u16, dst_port: u16, payload: []const u8) void {
    const udp_len: u16 = @intCast(8 + payload.len);
    const total: usize = 14 + 20 + 8 + payload.len;
    if (total > 1500) return;
    var pkt: [1500]u8 = undefined;

    build_eth_header(&pkt, dst_mac, ETH_IPV4);
    build_ip_header(&pkt, PROTO_UDP, dst_ip, 8 + payload.len);

    const udp = pkt[34..];
    write_be16(udp, 0, src_port);
    write_be16(udp, 2, dst_port);
    write_be16(udp, 4, udp_len);
    write_be16(udp, 6, 0); // Checksum optional for IPv4
    @memcpy(udp[8..][0..payload.len], payload);

    e1000.send(pkt[0..total]);
}

fn handle_udp(ip: []const u8, ihl: usize) void {
    const ip_total = read_be16(ip, 2);
    if (ip.len < ip_total) return;
    const udp = ip[ihl..ip_total];
    if (udp.len < 8) return;

    const src_port = read_be16(udp, 0);
    const dst_port = read_be16(udp, 2);
    const udp_len = read_be16(udp, 4);
    if (udp.len < udp_len) return;
    const payload = udp[8..udp_len];

    // DNS response
    if (src_port == 53 and dst_port == DNS_LOCAL_PORT) {
        if (parse_dns_response(payload)) |resolved| {
            dns_resolved_ip = resolved;
            dns_response_ready = true;
        }
    }
}

// ── DNS ─────────────────────────────────────────────────────────────────

fn encode_dns_name(hostname: []const u8, buf: []u8) ?usize {
    var pos: usize = 0;
    var start: usize = 0;
    for (hostname, 0..) |c, i| {
        if (c == '.') {
            const label_len = i - start;
            if (label_len == 0 or label_len > 63 or pos + 1 + label_len >= buf.len) return null;
            buf[pos] = @truncate(label_len);
            pos += 1;
            @memcpy(buf[pos..][0..label_len], hostname[start..i]);
            pos += label_len;
            start = i + 1;
        }
    }
    const label_len = hostname.len - start;
    if (label_len == 0 or label_len > 63 or pos + 2 + label_len >= buf.len) return null;
    buf[pos] = @truncate(label_len);
    pos += 1;
    @memcpy(buf[pos..][0..label_len], hostname[start..]);
    pos += label_len;
    buf[pos] = 0;
    pos += 1;
    return pos;
}

fn skip_dns_name(data: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < data.len) {
        const len = data[pos];
        if (len == 0) return pos + 1;
        if (len & 0xC0 == 0xC0) return pos + 2; // Compression pointer
        if (pos + 1 + len > data.len) return null;
        pos += 1 + len;
    }
    return null;
}

fn parse_dns_response(data: []const u8) ?[4]u8 {
    if (data.len < 12) return null;
    const flags = read_be16(data, 2);
    if (flags & 0x8000 == 0) return null; // Not a response
    const qdcount = read_be16(data, 4);
    const ancount = read_be16(data, 6);

    // Skip questions
    var pos: usize = 12;
    for (0..qdcount) |_| {
        pos = skip_dns_name(data, pos) orelse return null;
        if (pos + 4 > data.len) return null;
        pos += 4; // QTYPE + QCLASS
    }

    // Parse answers looking for A record
    for (0..ancount) |_| {
        pos = skip_dns_name(data, pos) orelse return null;
        if (pos + 10 > data.len) return null;
        const rtype = read_be16(data, pos);
        const rdlength = read_be16(data, pos + 8);
        pos += 10;
        if (rtype == 1 and rdlength == 4) { // A record
            if (pos + 4 > data.len) return null;
            return .{ data[pos], data[pos + 1], data[pos + 2], data[pos + 3] };
        }
        pos += rdlength;
    }
    return null;
}

/// Resolve a hostname to an IPv4 address via DNS.
pub fn dns_resolve(hostname: []const u8) ?[4]u8 {
    if (!e1000.ready) return null;

    // Build DNS query
    var query: [512]u8 = undefined;
    write_be16(&query, 0, 0xBEEF); // ID
    write_be16(&query, 2, 0x0100); // Standard query, recursion desired
    write_be16(&query, 4, 1); // QDCOUNT
    write_be16(&query, 6, 0);
    write_be16(&query, 8, 0);
    write_be16(&query, 10, 0);

    var pos: usize = 12;
    const name_len = encode_dns_name(hostname, query[pos..]) orelse return null;
    pos += name_len;
    write_be16(&query, pos, 1); // QTYPE A
    pos += 2;
    write_be16(&query, pos, 1); // QCLASS IN
    pos += 2;

    drain_rx();
    dns_response_ready = false;

    // Resolve MAC for DNS server
    const mac = resolve_mac(dns_server) orelse return null;

    send_udp(mac, dns_server, DNS_LOCAL_PORT, 53, query[0..pos]);

    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) {
        process_rx();
        if (dns_response_ready) return dns_resolved_ip;
    }
    return null;
}

// ── ICMP ────────────────────────────────────────────────────────────────

fn send_icmp_echo(dst_mac: [6]u8, dst_ip: [4]u8, seq: u16) void {
    const icmp_data_len = 32;
    const icmp_len = 8 + icmp_data_len;
    var pkt: [14 + 20 + 8 + 32]u8 = undefined;

    build_eth_header(&pkt, dst_mac, ETH_IPV4);
    build_ip_header(&pkt, PROTO_ICMP, dst_ip, icmp_len);

    const icmp = pkt[34..];
    icmp[0] = ICMP_ECHO_REQUEST;
    icmp[1] = 0;
    write_be16(icmp, 2, 0);
    write_be16(icmp, 4, 0x4F57); // Identifier "OW"
    write_be16(icmp, 6, seq);
    for (0..icmp_data_len) |i| {
        icmp[8 + i] = @truncate(i);
    }
    write_be16(icmp, 2, inet_checksum(icmp[0..icmp_len]));

    e1000.send(&pkt);
}

fn handle_icmp(ip: []const u8, ihl: usize, data: []const u8) void {
    const icmp = ip[ihl..];
    if (icmp.len < 8) return;

    if (icmp[0] == ICMP_ECHO_REPLY and icmp[1] == 0) {
        if (read_be16(icmp, 4) == 0x4F57) {
            ping_got_reply = true;
            ping_reply_ttl = ip[8];
        }
    } else if (icmp[0] == ICMP_ECHO_REQUEST) {
        const dst_ip = ip[16..20];
        if (dst_ip[0] == our_ip[0] and dst_ip[1] == our_ip[1] and
            dst_ip[2] == our_ip[2] and dst_ip[3] == our_ip[3])
        {
            send_icmp_reply(data, ip[12..16][0..4].*, ihl);
        }
    }
}

fn send_icmp_reply(orig: []const u8, dst_ip: [4]u8, ihl: usize) void {
    if (orig.len > 1500) return;
    var pkt: [1500]u8 = undefined;
    const len = orig.len;
    @memcpy(pkt[0..len], orig[0..len]);

    @memcpy(pkt[0..6], orig[6..12]);
    @memcpy(pkt[6..12], &e1000.mac);
    @memcpy(pkt[14 + 12 .. 14 + 16], &our_ip);
    @memcpy(pkt[14 + 16 .. 14 + 20], &dst_ip);
    write_be16(pkt[14..], 10, 0);
    write_be16(pkt[14..], 10, inet_checksum(pkt[14 .. 14 + ihl]));

    const icmp_off = 14 + ihl;
    pkt[icmp_off] = ICMP_ECHO_REPLY;
    const ip_total_len = read_be16(orig, 16);
    const icmp_len = ip_total_len - ihl;
    write_be16(pkt[icmp_off..], 2, 0);
    write_be16(pkt[icmp_off..], 2, inet_checksum(pkt[icmp_off .. icmp_off + icmp_len]));

    e1000.send(pkt[0..len]);
}

// ── TCP ─────────────────────────────────────────────────────────────────

fn send_tcp(dst_mac: [6]u8, dst_ip: [4]u8, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) void {
    const tcp_hdr_len: usize = if (flags & TCP_SYN != 0) 24 else 20;
    const total: usize = 14 + 20 + tcp_hdr_len + payload.len;
    if (total > 1500) return;
    var pkt: [1500]u8 = undefined;

    build_eth_header(&pkt, dst_mac, ETH_IPV4);
    build_ip_header(&pkt, PROTO_TCP, dst_ip, tcp_hdr_len + payload.len);

    const tcp = pkt[34..];
    write_be16(tcp, 0, src_port);
    write_be16(tcp, 2, dst_port);
    write_be32(tcp, 4, seq);
    write_be32(tcp, 8, ack);
    tcp[12] = @as(u8, @intCast(tcp_hdr_len / 4)) << 4;
    tcp[13] = flags;
    write_be16(tcp, 14, 8192); // Window
    write_be16(tcp, 16, 0); // Checksum placeholder
    write_be16(tcp, 18, 0); // Urgent

    // MSS option on SYN
    if (flags & TCP_SYN != 0) {
        tcp[20] = 2; // Kind: MSS
        tcp[21] = 4; // Length
        write_be16(tcp, 22, 1460); // MSS value
    }

    if (payload.len > 0) {
        @memcpy(pkt[34 + tcp_hdr_len ..][0..payload.len], payload);
    }

    const seg_len = tcp_hdr_len + payload.len;
    write_be16(tcp, 16, transport_checksum(our_ip, dst_ip, PROTO_TCP, pkt[34..][0..seg_len]));

    e1000.send(pkt[0..total]);
}

fn send_tcp_conn(flags: u8, payload: []const u8) void {
    send_tcp(tcp_remote_mac, tcp_remote_ip, tcp_local_port, tcp_remote_port, tcp_seq, tcp_ack, flags, payload);
}

fn handle_tcp(ip: []const u8, ihl: usize) void {
    const ip_total: usize = read_be16(ip, 2);
    if (ip.len < ip_total) return;
    const tcp = ip[ihl..ip_total];
    if (tcp.len < 20) return;

    const src_port = read_be16(tcp, 0);
    const dst_port = read_be16(tcp, 2);
    const seq = read_be32(tcp, 4);
    const ack_num = read_be32(tcp, 8);
    const data_off = @as(usize, tcp[12] >> 4) * 4;
    const flags = tcp[13];

    if (tcp_state == .closed) return;
    if (dst_port != tcp_local_port or src_port != tcp_remote_port) return;

    if (tcp_state == .syn_sent) {
        if (flags & TCP_SYN != 0 and flags & TCP_ACK != 0) {
            tcp_seq = ack_num; // Confirmed: ISN + 1
            tcp_ack = seq + 1; // ACK their SYN
            tcp_state = .established;
            send_tcp_conn(TCP_ACK, &.{});
        } else if (flags & TCP_RST != 0) {
            tcp_state = .closed;
        }
    } else if (tcp_state == .established) {
        if (flags & TCP_RST != 0) {
            tcp_state = .closed;
            return;
        }
        if (data_off <= tcp.len) {
            const payload = tcp[data_off..];
            if (payload.len > 0) {
                const space = tcp_recv_buf.len - tcp_recv_len;
                const n = @min(payload.len, space);
                @memcpy(tcp_recv_buf[tcp_recv_len..][0..n], payload[0..n]);
                tcp_recv_len += n;
                tcp_ack = seq +% @as(u32, @intCast(payload.len));
                send_tcp_conn(TCP_ACK, &.{});
            }
        }
        if (flags & TCP_FIN != 0) {
            tcp_ack +%= 1;
            send_tcp_conn(TCP_ACK, &.{});
            tcp_state = .closed;
        }
    }
}

// ── IPv4 dispatch ───────────────────────────────────────────────────────

fn handle_ipv4(data: []const u8) void {
    if (data.len < 34) return;
    const ip = data[14..];
    if (ip[0] & 0xF0 != 0x40) return;
    const ihl = @as(usize, ip[0] & 0x0F) * 4;
    if (ip.len < ihl) return;

    switch (ip[9]) {
        PROTO_ICMP => handle_icmp(ip, ihl, data),
        PROTO_TCP => handle_tcp(ip, ihl),
        PROTO_UDP => handle_udp(ip, ihl),
        else => {},
    }
}

// ── RX processing ───────────────────────────────────────────────────────

fn process_rx() void {
    const frame = e1000.receive() orelse return;
    if (frame.len < 14) return;
    switch (read_be16(frame, 12)) {
        ETH_ARP => handle_arp(frame),
        ETH_IPV4 => handle_ipv4(frame),
        else => {},
    }
}

fn drain_rx() void {
    for (0..256) |_| {
        if (e1000.receive() == null) break;
    }
}

// ── Public API ──────────────────────────────────────────────────────────

fn same_subnet(a: [4]u8, b: [4]u8) bool {
    return (a[0] & subnet_mask[0]) == (b[0] & subnet_mask[0]) and
        (a[1] & subnet_mask[1]) == (b[1] & subnet_mask[1]) and
        (a[2] & subnet_mask[2]) == (b[2] & subnet_mask[2]) and
        (a[3] & subnet_mask[3]) == (b[3] & subnet_mask[3]);
}

pub const PingResult = struct { ttl: u8 };

pub fn ping(target_ip: [4]u8) ?PingResult {
    if (!e1000.ready) return null;
    drain_rx();

    const dst_mac = resolve_mac(target_ip) orelse return null;

    ping_got_reply = false;
    send_icmp_echo(dst_mac, target_ip, ping_seq);
    ping_seq +%= 1;

    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) {
        process_rx();
        if (ping_got_reply) return .{ .ttl = ping_reply_ttl };
    }
    return null;
}

pub const WpingResult = struct {
    status_code: u16,
    status_line: [80]u8,
    status_len: usize,
};

/// Perform an HTTP HEAD request ("web ping") and return the status line.
pub fn wping(host: []const u8, port: u16) ?WpingResult {
    if (!e1000.ready) return null;

    // Resolve IP: try parsing as literal first, else DNS
    const ip = parse_ip(host) orelse dns_resolve(host) orelse return null;

    drain_rx();
    const dst_mac = resolve_mac(ip) orelse return null;

    // Set up TCP connection
    tcp_remote_mac = dst_mac;
    tcp_remote_ip = ip;
    tcp_remote_port = port;
    tcp_local_port = ephemeral_port;
    ephemeral_port +%= 1;
    if (ephemeral_port < 49152) ephemeral_port = 49152;

    var isn_buf: [4]u8 = undefined;
    owos.rdrand.fill(&isn_buf);
    tcp_seq = std.mem.readInt(u32, &isn_buf, .little);
    tcp_ack = 0;
    tcp_recv_len = 0;
    tcp_state = .syn_sent;

    send_tcp_conn(TCP_SYN, &.{});

    // Wait for connection
    var wait: usize = 0;
    while (wait < 20_000_000) : (wait += 1) {
        process_rx();
        if (tcp_state == .established) break;
        if (tcp_state == .closed) return null;
    }
    if (tcp_state != .established) {
        tcp_state = .closed;
        return null;
    }

    // Send HTTP HEAD request
    var req: [300]u8 = undefined;
    const head = "HEAD / HTTP/1.0\r\nHost: ";
    const tail = "\r\nConnection: close\r\n\r\n";
    const host_len = @min(host.len, req.len - head.len - tail.len);
    @memcpy(req[0..head.len], head);
    @memcpy(req[head.len..][0..host_len], host[0..host_len]);
    const req_len = head.len + host_len + tail.len;
    @memcpy(req[head.len + host_len ..][0..tail.len], tail);

    send_tcp_conn(TCP_PSH | TCP_ACK, req[0..req_len]);
    tcp_seq +%= @intCast(req_len);

    // Wait for response data
    wait = 0;
    while (wait < 30_000_000) : (wait += 1) {
        process_rx();
        if (tcp_recv_len > 0) {
            // Wait a little more for the full status line
            var extra: usize = 0;
            while (extra < 2_000_000) : (extra += 1) {
                process_rx();
                // Check if we have a complete first line
                for (tcp_recv_buf[0..tcp_recv_len]) |c| {
                    if (c == '\n') {
                        extra = 2_000_000; // break outer
                        break;
                    }
                }
            }
            break;
        }
        if (tcp_state == .closed) break;
    }

    // Close connection with RST
    if (tcp_state != .closed) {
        send_tcp_conn(TCP_RST | TCP_ACK, &.{});
        tcp_state = .closed;
    }

    if (tcp_recv_len == 0) return null;

    // Parse HTTP status line
    return parse_http_status();
}

fn parse_http_status() ?WpingResult {
    var result: WpingResult = .{
        .status_code = 0,
        .status_line = undefined,
        .status_len = 0,
    };
    const data = tcp_recv_buf[0..tcp_recv_len];

    // Find end of first line
    var line_end: usize = data.len;
    for (data, 0..) |c, i| {
        if (c == '\r' or c == '\n') {
            line_end = i;
            break;
        }
    }

    const line = data[0..line_end];
    const copy_len = @min(line.len, result.status_line.len);
    @memcpy(result.status_line[0..copy_len], line[0..copy_len]);
    result.status_len = copy_len;

    // Parse "HTTP/x.x NNN ..."
    if (line.len >= 12 and line[0] == 'H' and line[1] == 'T' and line[2] == 'T' and line[3] == 'P') {
        var i: usize = 4;
        while (i < line.len and line[i] != ' ') i += 1;
        i += 1;
        if (i + 3 <= line.len and
            line[i] >= '0' and line[i] <= '9' and
            line[i + 1] >= '0' and line[i + 1] <= '9' and
            line[i + 2] >= '0' and line[i + 2] <= '9')
        {
            result.status_code = @as(u16, line[i] - '0') * 100 +
                @as(u16, line[i + 1] - '0') * 10 +
                @as(u16, line[i + 2] - '0');
        }
    }

    if (result.status_code == 0) return null;
    return result;
}

// ── Utility ─────────────────────────────────────────────────────────────

pub fn parse_ip(s: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var octet: usize = 0;
    var val: u16 = 0;
    var has_digit = false;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            val = val * 10 + (c - '0');
            if (val > 255) return null;
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit or octet >= 3) return null;
            ip[octet] = @truncate(val);
            octet += 1;
            val = 0;
            has_digit = false;
        } else {
            return null;
        }
    }
    if (!has_digit or octet != 3) return null;
    ip[3] = @truncate(val);
    return ip;
}

pub fn format_ip(ip: [4]u8, buf: *[15]u8) []const u8 {
    var len: usize = 0;
    for (ip, 0..) |octet, i| {
        if (i > 0) {
            buf[len] = '.';
            len += 1;
        }
        if (octet >= 100) {
            buf[len] = '0' + octet / 100;
            len += 1;
        }
        if (octet >= 10) {
            buf[len] = '0' + (octet / 10) % 10;
            len += 1;
        }
        buf[len] = '0' + octet % 10;
        len += 1;
    }
    return buf[0..len];
}
