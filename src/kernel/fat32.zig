const std = @import("std");
const owos = @import("root.zig");
const ahci = owos.ahci;

pub var mounted: bool = false;

// BPB fields
var partition_lba: u64 = 0;
var bytes_per_sector: u32 = 512;
var sectors_per_cluster: u32 = 0;
var reserved_sectors: u32 = 0;
var num_fats: u32 = 0;
var fat_size: u32 = 0;
pub var root_cluster: u32 = 0;
var total_sectors: u32 = 0;
var data_start_lba: u64 = 0;
pub var volume_label: [11]u8 = undefined;
pub var volume_label_len: usize = 0;

// FAT sector cache
var fat_cache: [512]u8 = undefined;
var fat_cache_lba: u64 = 0xFFFFFFFF_FFFFFFFF;
var fat_cache_dirty: bool = false;

// Block device backend
var use_usb: bool = false;

fn block_read(lba: u64, count: u32, out: []u8) bool {
    if (use_usb) {
        if (!owos.usb_storage.ready) {
            mounted = false;
            return false;
        }
        return owos.usb_storage.read_sectors(lba, count, out);
    }
    return ahci.read_sectors(lba, count, out);
}

fn block_write(lba: u64, count: u32, data: []const u8) bool {
    if (use_usb) {
        if (!owos.usb_storage.ready) {
            mounted = false;
            return false;
        }
        return owos.usb_storage.write_sectors(lba, count, data);
    }
    return ahci.write_sectors(lba, count, data);
}

// ── Directory entry ─────────────────────────────────────────────────────

pub const DirEntry = struct {
    name: [256]u8 = undefined,
    name_len: usize = 0,
    attr: u8 = 0,
    cluster: u32 = 0,
    size: u32 = 0,

    pub fn get_name(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn is_dir(self: DirEntry) bool {
        return self.attr & 0x10 != 0;
    }
};

const MAX_DIR_ENTRIES = 128;
var dir_buf: [MAX_DIR_ENTRIES]DirEntry = undefined;
var dir_count: usize = 0;

// ── Init ────────────────────────────────────────────────────────────────

pub fn init() void {
    // Try AHCI backend
    if (ahci.ready) {
        use_usb = false;
        if (try_find_fat32()) return;
    }
    // Try USB backend
    if (owos.usb_storage.ready) {
        use_usb = true;
        if (try_find_fat32()) return;
    }
    owos.klog.warn("FAT32: no FAT32 filesystem found", .{});
}

fn try_find_fat32() bool {
    var sector: [512]u8 = undefined;
    if (!block_read(0, 1, &sector)) return false;

    if (sector[0x1FE] == 0x55 and sector[0x1FF] == 0xAA) {
        for (0..4) |i| {
            const base = 0x1BE + i * 16;
            const ptype = sector[base + 4];
            if (ptype == 0x0B or ptype == 0x0C) {
                const lba = std.mem.readInt(u32, sector[base + 8 ..][0..4], .little);
                if (try_mount(@as(u64, lba))) return true;
            }
        }
        if (try_mount(0)) return true;
    } else {
        if (try_mount(0)) return true;
    }
    return false;
}

fn try_mount(lba: u64) bool {
    var bpb: [512]u8 = undefined;
    if (!block_read(lba, 1, &bpb)) return false;

    if (bpb[0x1FE] != 0x55 or bpb[0x1FF] != 0xAA) return false;

    const bps = std.mem.readInt(u16, bpb[0x0B..0x0D], .little);
    if (bps != 512) return false;

    const spc = bpb[0x0D];
    if (spc == 0) return false;

    const rsvd = std.mem.readInt(u16, bpb[0x0E..0x10], .little);
    const nfats = bpb[0x10];
    const root_ent_cnt = std.mem.readInt(u16, bpb[0x11..0x13], .little);
    if (root_ent_cnt != 0) return false;

    const fatsz16 = std.mem.readInt(u16, bpb[0x16..0x18], .little);
    const fatsz32 = std.mem.readInt(u32, bpb[0x24..0x28], .little);
    const fs = if (fatsz16 != 0) @as(u32, fatsz16) else fatsz32;
    if (fs == 0) return false;

    const tot16 = std.mem.readInt(u16, bpb[0x13..0x15], .little);
    const tot32 = std.mem.readInt(u32, bpb[0x20..0x24], .little);
    const tot = if (tot16 != 0) @as(u32, tot16) else tot32;

    const root_clus = std.mem.readInt(u32, bpb[0x2C..0x30], .little);
    if (root_clus < 2) return false;

    partition_lba = lba;
    bytes_per_sector = bps;
    sectors_per_cluster = spc;
    reserved_sectors = rsvd;
    num_fats = nfats;
    fat_size = fs;
    root_cluster = root_clus;
    total_sectors = tot;
    data_start_lba = lba + rsvd + @as(u64, nfats) * fs;

    @memcpy(&volume_label, bpb[0x47..0x52]);
    volume_label_len = 11;
    while (volume_label_len > 0 and volume_label[volume_label_len - 1] == ' ') {
        volume_label_len -= 1;
    }

    mounted = true;
    fat_cache_lba = 0xFFFFFFFF_FFFFFFFF;
    fat_cache_dirty = false;

    const backend: []const u8 = if (use_usb) "USB" else "AHCI";
    owos.klog.info("FAT32: mounted via {s} at LBA {d}  label=\"{s}\"", .{ backend, lba, volume_label[0..volume_label_len] });
    owos.klog.info("FAT32: {d} sec/cluster  FAT={d} sectors  root=cluster {d}", .{ spc, fs, root_clus });
    return true;
}

// ── FAT navigation ──────────────────────────────────────────────────────

fn cluster_to_lba(cluster: u32) u64 {
    if (cluster < 2) return data_start_lba; // guard against underflow
    return data_start_lba + @as(u64, cluster -% 2) * sectors_per_cluster;
}

fn fat_sector_for(cluster: u32) u64 {
    return partition_lba + reserved_sectors + @as(u64, cluster) * 4 / bytes_per_sector;
}

fn fat_offset_for(cluster: u32) usize {
    return @intCast((@as(u64, cluster) * 4) % bytes_per_sector);
}

fn ensure_fat_cache(sector: u64) bool {
    if (sector == fat_cache_lba) return true;
    if (!flush_fat_cache()) return false;
    if (!block_read(sector, 1, &fat_cache)) return false;
    fat_cache_lba = sector;
    return true;
}

fn fat_next(cluster: u32) ?u32 {
    const sector = fat_sector_for(cluster);
    const entry_off = fat_offset_for(cluster);
    if (!ensure_fat_cache(sector)) return null;
    const val = std.mem.readInt(u32, fat_cache[entry_off..][0..4], .little) & 0x0FFFFFFF;
    if (val >= 0x0FFFFFF8 or val < 2) return null;
    return val;
}

// ── FAT writing ─────────────────────────────────────────────────────────

fn flush_fat_cache() bool {
    if (!fat_cache_dirty) return true;
    if (!block_write(fat_cache_lba, 1, &fat_cache)) return false;
    // Also update the backup FAT (FAT #2) if present
    if (num_fats > 1) {
        const backup_lba = fat_cache_lba + fat_size;
        _ = block_write(backup_lba, 1, &fat_cache);
    }
    fat_cache_dirty = false;
    return true;
}

fn write_fat_entry(cluster: u32, value: u32) bool {
    const sector = fat_sector_for(cluster);
    const entry_off = fat_offset_for(cluster);
    if (!ensure_fat_cache(sector)) return false;
    // Preserve high 4 bits of existing entry
    const old = std.mem.readInt(u32, fat_cache[entry_off..][0..4], .little);
    const new_val = (old & 0xF0000000) | (value & 0x0FFFFFFF);
    std.mem.writeInt(u32, fat_cache[entry_off..][0..4], new_val, .little);
    fat_cache_dirty = true;
    return true;
}

fn find_free_cluster() ?u32 {
    const total = cluster_count() + 2;
    var clus: u32 = 2;
    while (clus < total) : (clus += 1) {
        const sector = fat_sector_for(clus);
        const entry_off = fat_offset_for(clus);
        if (!ensure_fat_cache(sector)) return null;
        const val = std.mem.readInt(u32, fat_cache[entry_off..][0..4], .little) & 0x0FFFFFFF;
        if (val == 0) return clus;
    }
    return null;
}

fn alloc_chain(count: u32) ?u32 {
    if (count == 0) return null;
    var first: u32 = 0;
    var prev: u32 = 0;
    for (0..count) |_| {
        const clus = find_free_cluster() orelse return null;
        if (first == 0) first = clus;
        if (prev != 0) {
            if (!write_fat_entry(prev, clus)) return null;
        }
        if (!write_fat_entry(clus, 0x0FFFFFF8)) return null;
        prev = clus;
    }
    if (!flush_fat_cache()) return null;
    return first;
}

fn free_chain(start: u32) void {
    if (start < 2) return;
    const max = cluster_count() + 2;
    var clus = start;
    var limit: u32 = 0;
    while (limit < max) : (limit += 1) {
        const next = fat_next(clus);
        _ = write_fat_entry(clus, 0);
        clus = next orelse break;
        if (clus < 2 or clus >= max) break;
    }
    _ = flush_fat_cache();
}

fn write_cluster_data(cluster: u32, data: []const u8) bool {
    const lba = cluster_to_lba(cluster);
    const csize = sectors_per_cluster * bytes_per_sector;
    // Write full cluster: pad remaining sectors with zeros
    return block_write_padded(lba, sectors_per_cluster, data, csize);
}

fn block_write_padded(lba: u64, count: u32, data: []const u8, total: u32) bool {
    _ = total;
    var cur_lba = lba;
    var offset: usize = 0;
    for (0..count) |_| {
        var sector: [512]u8 = .{0} ** 512;
        if (offset < data.len) {
            const copy = @min(512, data.len - offset);
            @memcpy(sector[0..copy], data[offset..][0..copy]);
        }
        if (!block_write(cur_lba, 1, &sector)) return false;
        offset += 512;
        cur_lba += 1;
    }
    return true;
}

// ── Directory parsing ───────────────────────────────────────────────────

fn format_83(raw: *const [11]u8, out: *[256]u8) usize {
    var len: usize = 0;
    var name_end: usize = 8;
    while (name_end > 0 and raw[name_end - 1] == ' ') name_end -= 1;
    for (raw[0..name_end]) |c| {
        out[len] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        len += 1;
    }
    var ext_end: usize = 3;
    while (ext_end > 0 and raw[8 + ext_end - 1] == ' ') ext_end -= 1;
    if (ext_end > 0) {
        out[len] = '.';
        len += 1;
        for (raw[8..][0..ext_end]) |c| {
            out[len] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            len += 1;
        }
    }
    return len;
}

fn collect_lfn(entry: *const [32]u8, buf: *[256]u8, len: *usize) void {
    const ordinal = entry[0] & 0x3F;
    if (ordinal == 0 or ordinal > 20) return;
    const base = (@as(usize, ordinal) - 1) * 13;
    const offsets = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    for (offsets, 0..) |off, i| {
        const pos = base + i;
        if (pos >= 255) break;
        const c = entry[off];
        const hi = entry[off + 1];
        if (c == 0x00 and hi == 0x00) break;
        if (c == 0xFF and hi == 0xFF) break;
        buf[pos] = c;
        if (pos + 1 > len.*) len.* = pos + 1;
    }
}

pub fn list_dir(cluster: u32) []const DirEntry {
    if (!mounted) return dir_buf[0..0];
    var count: usize = 0;

    var lfn_buf: [256]u8 = undefined;
    var lfn_len: usize = 0;
    var has_lfn = false;

    var cur_cluster = cluster;
    outer: while (true) {
        const base_lba = cluster_to_lba(cur_cluster);
        for (0..sectors_per_cluster) |s| {
            var sec: [512]u8 = undefined;
            if (!block_read(base_lba + s, 1, &sec)) break :outer;

            var off: usize = 0;
            while (off + 32 <= 512) : (off += 32) {
                const raw = sec[off..][0..32];
                if (raw[0] == 0x00) break :outer;
                if (raw[0] == 0xE5) {
                    has_lfn = false;
                    lfn_len = 0;
                    continue;
                }

                const attr = raw[0x0B];
                if (attr == 0x0F) {
                    collect_lfn(raw, &lfn_buf, &lfn_len);
                    has_lfn = true;
                    continue;
                }
                if (attr & 0x08 != 0) {
                    has_lfn = false;
                    lfn_len = 0;
                    continue;
                }

                if (count >= MAX_DIR_ENTRIES) break :outer;

                dir_buf[count].attr = attr;
                const hi: u32 = std.mem.readInt(u16, raw[0x14..0x16], .little);
                const lo: u32 = std.mem.readInt(u16, raw[0x1A..0x1C], .little);
                dir_buf[count].cluster = (hi << 16) | lo;
                dir_buf[count].size = std.mem.readInt(u32, raw[0x1C..0x20], .little);
                if (has_lfn and lfn_len > 0) {
                    const n = @min(lfn_len, 255);
                    @memcpy(dir_buf[count].name[0..n], lfn_buf[0..n]);
                    dir_buf[count].name_len = n;
                } else {
                    dir_buf[count].name_len = format_83(raw[0..11], &dir_buf[count].name);
                }
                count += 1;
                has_lfn = false;
                lfn_len = 0;
            }
        }
        cur_cluster = fat_next(cur_cluster) orelse break;
    }
    dir_count = count;
    return dir_buf[0..count];
}

// ── File reading ────────────────────────────────────────────────────────

pub fn read_file(cluster: u32, file_size: u32, out: []u8) usize {
    if (!mounted or cluster < 2 or file_size == 0) return 0;
    var bytes_read: usize = 0;
    var cur_cluster = cluster;
    var sec: [512]u8 = undefined;

    while (bytes_read < file_size and bytes_read < out.len) {
        const base_lba = cluster_to_lba(cur_cluster);
        for (0..sectors_per_cluster) |s| {
            if (bytes_read >= file_size or bytes_read >= out.len) break;
            if (!block_read(base_lba + s, 1, &sec)) return bytes_read;
            const want = @min(file_size - bytes_read, 512);
            const copy: usize = @min(want, out.len - bytes_read);
            @memcpy(out[bytes_read..][0..copy], sec[0..copy]);
            bytes_read += copy;
        }
        cur_cluster = fat_next(cur_cluster) orelse break;
    }
    return bytes_read;
}

// ── File writing ────────────────────────────────────────────────────────

fn make_83(name: []const u8, out: *[11]u8) void {
    @memset(out, ' ');
    var dot: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '.') {
            dot = i;
            break;
        }
    }
    const base = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| (if (d + 1 < name.len) name[d + 1 ..] else &[_]u8{}) else &[_]u8{};
    for (0..@min(base.len, 8)) |i| {
        out[i] = if (base[i] >= 'a' and base[i] <= 'z') base[i] - 32 else base[i];
    }
    for (0..@min(ext.len, 3)) |i| {
        out[8 + i] = if (ext[i] >= 'a' and ext[i] <= 'z') ext[i] - 32 else ext[i];
    }
}

fn needs_lfn(name: []const u8) bool {
    // Check if name fits in 8.3 format without loss
    var dot: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '.') {
            if (dot != null) return true; // multiple dots
            dot = i;
        }
    }
    const base_len = if (dot) |d| d else name.len;
    const ext_len = if (dot) |d| name.len - d - 1 else 0;
    if (base_len > 8 or ext_len > 3) return true;
    // Check for lowercase (8.3 is uppercase only)
    for (name) |c| {
        if (c >= 'a' and c <= 'z') return true;
    }
    return false;
}

fn lfn_checksum(short: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| {
        sum = ((sum & 1) << 7) +% (sum >> 1) +% c;
    }
    return sum;
}

fn build_lfn_entry(buf: *[32]u8, ordinal: u8, name: []const u8, base_off: usize, chk: u8, is_last: bool) void {
    @memset(buf, 0);
    buf[0] = ordinal | (if (is_last) @as(u8, 0x40) else @as(u8, 0));
    buf[0x0B] = 0x0F; // LFN attribute
    buf[0x0D] = chk;

    // 13 UTF-16LE characters per LFN entry at specific offsets
    const offsets = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
    for (offsets, 0..) |off, i| {
        const pos = base_off + i;
        if (pos < name.len) {
            buf[off] = name[pos];
            buf[off + 1] = 0; // ASCII → UTF-16LE high byte
        } else if (pos == name.len) {
            buf[off] = 0x00; // null terminator
            buf[off + 1] = 0x00;
        } else {
            buf[off] = 0xFF; // padding
            buf[off + 1] = 0xFF;
        }
    }
}

fn create_dir_entry(dir_cluster: u32, name: []const u8, cluster: u32, size: u32) bool {
    var short: [11]u8 = undefined;
    make_83(name, &short);

    const use_lfn = needs_lfn(name);
    const lfn_entries: usize = if (use_lfn) (name.len + 12) / 13 else 0;
    const total_entries = lfn_entries + 1; // LFN entries + 8.3 entry

    const chk = lfn_checksum(&short);

    // Find `total_entries` consecutive free slots in the directory
    var cur = dir_cluster;
    while (true) {
        const base_lba = cluster_to_lba(cur);
        for (0..sectors_per_cluster) |s| {
            var sec: [512]u8 = undefined;
            if (!block_read(base_lba + s, 1, &sec)) return false;

            // Count consecutive free entries starting at each position
            var off: usize = 0;
            while (off + 32 <= 512) : (off += 32) {
                if (sec[off] != 0x00 and sec[off] != 0xE5) continue;

                // Count how many consecutive free entries from here
                var free: usize = 0;
                var check = off;
                while (check + 32 <= 512 and free < total_entries) : (check += 32) {
                    if (sec[check] != 0x00 and sec[check] != 0xE5) break;
                    free += 1;
                }
                if (free < total_entries) continue;

                // Found enough space — write LFN entries (reverse order)
                var pos = off;
                for (0..lfn_entries) |li| {
                    const ordinal: u8 = @intCast(lfn_entries - li);
                    const char_off = (ordinal - 1) * 13;
                    build_lfn_entry(sec[pos..][0..32], ordinal, name, char_off, chk, li == 0);
                    pos += 32;
                }

                // Write the 8.3 entry
                @memset(sec[pos..][0..32], 0);
                @memcpy(sec[pos..][0..11], &short);
                sec[pos + 0x0B] = 0x20; // ARCHIVE
                std.mem.writeInt(u16, sec[pos + 0x14 ..][0..2], @truncate(cluster >> 16), .little);
                std.mem.writeInt(u16, sec[pos + 0x1A ..][0..2], @truncate(cluster), .little);
                std.mem.writeInt(u32, sec[pos + 0x1C ..][0..4], size, .little);
                return block_write(base_lba + s, 1, &sec);
            }
        }
        cur = fat_next(cur) orelse break;
    }
    return false;
}

/// Create a new file at the given path (e.g. "subdir/file.txt").
/// Resolves parent directories; creates in root if no directory component.
pub fn create_file(dir_cluster: u32, path: []const u8, data: []const u8) bool {
    if (!mounted) return false;

    // Resolve parent directory from path
    var parent = dir_cluster;
    var name = path;
    if (name.len > 0 and name[0] == '/') name = name[1..];

    // Walk directory components
    while (true) {
        var slash: usize = 0;
        while (slash < name.len and name[slash] != '/') slash += 1;
        if (slash >= name.len) break; // no more slashes, `name` is the filename
        const component = name[0..slash];
        name = name[slash + 1 ..];

        // Find this subdirectory
        const entries = list_dir(parent);
        var found: ?u32 = null;
        for (entries) |e| {
            if (name_eq_ci(e.get_name(), component) and e.is_dir()) {
                found = e.cluster;
                break;
            }
        }
        parent = found orelse return false; // subdirectory not found
    }
    if (name.len == 0) return false;

    const csize = sectors_per_cluster * bytes_per_sector;
    const n_clusters: u32 = if (data.len == 0) 1 else @intCast((data.len + csize - 1) / csize);

    const first = alloc_chain(n_clusters) orelse {
        owos.klog.warn("FAT32: alloc_chain({d}) failed", .{n_clusters});
        return false;
    };

    // Write data to clusters
    var cur = first;
    var offset: usize = 0;
    while (offset < data.len) {
        const remaining = data.len - offset;
        const chunk = @min(remaining, csize);
        if (!write_cluster_data(cur, data[offset..][0..chunk])) {
            owos.klog.warn("FAT32: write_cluster_data(cluster={d}) failed", .{cur});
            return false;
        }
        offset += chunk;
        if (offset < data.len) cur = fat_next(cur) orelse break;
    }

    if (!create_dir_entry(parent, name, first, @intCast(data.len))) {
        owos.klog.warn("FAT32: create_dir_entry failed", .{});
        return false;
    }
    return true;
}

/// Delete a file by path — frees its cluster chain and marks the dir entry as deleted.
pub fn delete_file(path: []const u8) bool {
    if (!mounted) return false;

    // Find the containing directory and the entry
    var dir_cluster = root_cluster;
    var remaining = path;
    if (remaining.len > 0 and remaining[0] == '/') remaining = remaining[1..];

    // Walk to parent directory
    while (remaining.len > 0) {
        var end: usize = 0;
        while (end < remaining.len and remaining[end] != '/') end += 1;
        const component = remaining[0..end];
        const rest = if (end < remaining.len) remaining[end + 1 ..] else remaining[end..];

        if (rest.len == 0) {
            // `component` is the file name to delete in dir_cluster
            return delete_entry_in_dir(dir_cluster, component);
        }

        // Navigate into subdirectory
        const entries = list_dir(dir_cluster);
        var found: ?DirEntry = null;
        for (entries) |e| {
            if (name_eq_ci(e.get_name(), component) and e.is_dir()) {
                found = e;
                break;
            }
        }
        dir_cluster = (found orelse return false).cluster;
        remaining = rest;
    }
    return false;
}

fn delete_entry_in_dir(dir_cluster: u32, name: []const u8) bool {
    // Use list_dir to find the entry (handles both LFN and 8.3 names)
    const entries = list_dir(dir_cluster);
    var target_cluster: u32 = 0;
    var found_name = false;
    for (entries) |e| {
        if (name_eq_ci(e.get_name(), name)) {
            target_cluster = e.cluster;
            found_name = true;
            break;
        }
    }
    if (!found_name) return false;

    // Free the cluster chain
    if (target_cluster >= 2) free_chain(target_cluster);

    // Now find and mark the 8.3 entry as deleted (scan raw sectors)
    var cur = dir_cluster;
    while (true) {
        const base_lba = cluster_to_lba(cur);
        for (0..sectors_per_cluster) |s| {
            var sec: [512]u8 = undefined;
            if (!block_read(base_lba + s, 1, &sec)) return false;

            // Track LFN entries so we can delete them too
            var lfn_start: ?usize = null;
            var off: usize = 0;
            while (off + 32 <= 512) : (off += 32) {
                if (sec[off] == 0x00) return false;
                if (sec[off] == 0xE5) {
                    lfn_start = null;
                    continue;
                }
                const attr = sec[off + 0x0B];
                if (attr == 0x0F) {
                    if (lfn_start == null) lfn_start = off;
                    continue;
                }
                if (attr & 0x08 != 0) {
                    lfn_start = null;
                    continue;
                }

                // Check if this 8.3 entry's cluster matches
                const hi: u32 = std.mem.readInt(u16, sec[off + 0x14 ..][0..2], .little);
                const lo: u32 = std.mem.readInt(u16, sec[off + 0x1A ..][0..2], .little);
                const cluster = (hi << 16) | lo;
                if (cluster != target_cluster) {
                    lfn_start = null;
                    continue;
                }

                // Mark LFN entries as deleted
                if (lfn_start) |ls| {
                    var d = ls;
                    while (d < off) : (d += 32) sec[d] = 0xE5;
                }
                // Mark 8.3 entry as deleted
                sec[off] = 0xE5;
                return block_write(base_lba + s, 1, &sec);
            }
        }
        cur = fat_next(cur) orelse break;
    }
    return false;
}

// ── Path resolution ─────────────────────────────────────────────────────

fn name_eq_ci(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

pub fn resolve_path(path: []const u8) ?DirEntry {
    if (!mounted) return null;
    var cluster = root_cluster;
    var rem = path;

    if (rem.len > 0 and rem[0] == '/') rem = rem[1..];
    if (rem.len == 0) return null;

    while (rem.len > 0) {
        var end: usize = 0;
        while (end < rem.len and rem[end] != '/') end += 1;
        const component = rem[0..end];
        rem = if (end < rem.len) rem[end + 1 ..] else rem[end..];

        const entries = list_dir(cluster);
        var found: ?DirEntry = null;
        for (entries) |e| {
            if (name_eq_ci(e.get_name(), component)) {
                found = e;
                break;
            }
        }

        if (found == null) {
            owos.klog.warn("FAT32: resolve '{s}' not found in cluster {d} ({d} entries)", .{ component, cluster, entries.len });
            return null;
        }
        const entry = found.?;
        if (rem.len == 0) return entry;
        if (!entry.is_dir()) return null;
        cluster = entry.cluster;
    }
    return null;
}

pub fn cluster_count() u32 {
    const data_sectors = total_sectors - (reserved_sectors + num_fats * fat_size);
    return data_sectors / sectors_per_cluster;
}
