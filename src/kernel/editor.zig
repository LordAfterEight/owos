const std = @import("std");
const owos = @import("root.zig");
const rendering = owos.fb.rendering;
const C = rendering.Color;
const ramfs = owos.ramfs;

const max_lines = 256;
const max_line_len = 480;
const max_yank = 32;

const Mode = enum { normal, insert, visual, command, search };

fn is_word(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

pub const Editor = struct {
    lines: [max_lines][max_line_len]u8 = [_][max_line_len]u8{[_]u8{0} ** max_line_len} ** max_lines,
    line_lens: [max_lines]usize = [_]usize{0} ** max_lines,
    line_count: usize = 1,

    cx: usize = 0,
    cy: usize = 0,
    scroll_y: usize = 0,
    scroll_x: usize = 0,

    mode: Mode = .normal,
    quit: bool = false,

    filename: [32]u8 = [_]u8{0} ** 32,
    filename_len: usize = 0,
    is_new: bool = true,
    modified: bool = false,

    view_rows: usize = 60,
    view_cols: usize = 170,

    status_buf: [80]u8 = [_]u8{0} ** 80,
    status_len: usize = 0,

    // Command / search input
    cmd_buf: [128]u8 = [_]u8{0} ** 128,
    cmd_len: usize = 0,

    // Search pattern (persists across searches)
    search_buf: [64]u8 = [_]u8{0} ** 64,
    search_len: usize = 0,

    // Yank register (linewise)
    yank_lines: [max_yank][max_line_len]u8 = [_][max_line_len]u8{[_]u8{0} ** max_line_len} ** max_yank,
    yank_lens: [max_yank]usize = [_]usize{0} ** max_yank,
    yank_count: usize = 0,

    // Visual mode anchor line
    vis_start: usize = 0,

    // Normal mode: pending key ('g','d','y','r') and count accumulator
    pending: u8 = 0,
    count_buf: usize = 0,

    pub var instance: Editor = .{};

    // ═════════════════════════════════════════════════════════════════
    // Entry points
    // ═════════════════════════════════════════════════════════════════

    pub fn open(self: *Editor, name_arg: []const u8) void {
        self.* = .{};
        if (rendering.GFB_VALID) {
            const h: usize = @intCast(rendering.GFB_HEIGHT);
            const w: usize = @intCast(rendering.GFB_WIDTH);
            const ch = rendering.ScrollingLog.char_height;
            const cw = rendering.ScrollingLog.char_width;
            self.view_rows = if (h / ch > 3) h / ch - 3 else 1;
            self.view_cols = @min(w / cw -| 1, max_line_len);
        }
        const nlen = @min(name_arg.len, 32);
        @memcpy(self.filename[0..nlen], name_arg[0..nlen]);
        self.filename_len = nlen;
        if (ramfs.get_file(name_arg)) |file| {
            self.is_new = false;
            var buf: [16384]u8 = undefined;
            const data = file.read_all(&buf) catch {
                self.set_status("Read error");
                return;
            };
            self.load_content(data);
        }
    }

    pub fn run(self: *Editor) void {
        self.render();
        while (!self.quit) {
            const sc = owos.ps2.poll() orelse continue;
            const ev = owos.ps2.process(sc) orelse continue;

            // Ctrl+S saves in normal/insert
            if (ev.ctrl and ev.char != null and (ev.char.? == 's' or ev.char.? == 'S') and
                (self.mode == .normal or self.mode == .insert))
            {
                self.save();
                self.render();
                continue;
            }

            self.status_len = 0;
            switch (self.mode) {
                .normal => self.handle_normal(ev),
                .insert => self.handle_insert(ev),
                .visual => self.handle_visual(ev),
                .command => self.handle_command(ev),
                .search => self.handle_search(ev),
            }
            self.render();
        }
    }

    // ═════════════════════════════════════════════════════════════════
    // Normal mode
    // ═════════════════════════════════════════════════════════════════

    fn handle_normal(self: *Editor, ev: owos.ps2.KeyEvent) void {
        if (self.do_arrows(ev)) {
            self.pending = 0;
            self.count_buf = 0;
            return;
        }

        const c = ev.char orelse return;

        // ── Pending replace ──────────────────────────────────────────
        if (self.pending == 'r') {
            self.pending = 0;
            if (c >= 0x20 and c < 0x7F and self.line_lens[self.cy] > 0) {
                self.lines[self.cy][self.cx] = c;
                self.modified = true;
            }
            return;
        }

        // ── Count accumulation ───────────────────────────────────────
        if ((c >= '1' and c <= '9') or (c == '0' and self.count_buf > 0)) {
            self.count_buf = @min(self.count_buf * 10 + (c - '0'), 9999);
            return;
        }

        // ── Two-key sequences ────────────────────────────────────────
        if (self.pending == 'g' and c == 'g') {
            self.pending = 0;
            self.cy = if (self.count_buf > 0) @min(self.count_buf - 1, self.line_count - 1) else 0;
            self.count_buf = 0;
            self.cx = 0;
            self.ensure_visible();
            return;
        }
        if (self.pending == 'd' and c == 'd') {
            self.pending = 0;
            self.do_delete_lines(self.consume_count());
            return;
        }
        if (self.pending == 'y' and c == 'y') {
            self.pending = 0;
            self.do_yank_lines(self.consume_count());
            return;
        }
        // Unknown second key → cancel pending
        if (self.pending != 0) {
            self.pending = 0;
            self.count_buf = 0;
            return;
        }

        // ── Single-key commands ──────────────────────────────────────
        const n = self.consume_count();
        switch (c) {
            // Movement
            'h' => for (0..n) |_| {
                if (self.cx > 0) self.cx -= 1;
            },
            'l' => for (0..n) |_| self.move_right_normal(),
            'j' => for (0..n) |_| self.move_down(),
            'k' => for (0..n) |_| self.move_up(),
            'w' => for (0..n) |_| self.motion_w(),
            'b' => for (0..n) |_| self.motion_b(),
            'e' => for (0..n) |_| self.motion_e(),
            '0' => {
                self.cx = 0;
            },
            '$' => {
                self.cx = if (self.line_lens[self.cy] > 0) self.line_lens[self.cy] - 1 else 0;
            },
            '^' => {
                self.cx = self.first_non_space();
            },
            'G' => {
                // bare G = last line, <count>G = goto line
                self.cy = if (n > 1 or self.count_buf > 0) @min(n - 1, self.line_count - 1) else self.line_count - 1;
                self.clamp_normal();
            },
            // Enter insert mode
            'i' => {
                self.mode = .insert;
            },
            'a' => {
                if (self.line_lens[self.cy] > 0) self.cx = @min(self.cx + 1, self.line_lens[self.cy]);
                self.mode = .insert;
            },
            'A' => {
                self.cx = self.line_lens[self.cy];
                self.mode = .insert;
            },
            'I' => {
                self.cx = self.first_non_space();
                self.mode = .insert;
            },
            'o' => {
                self.open_line_below();
                self.mode = .insert;
            },
            'O' => {
                self.open_line_above();
                self.mode = .insert;
            },
            // Editing
            'x' => for (0..n) |_| self.del_char_at_cursor(),
            'D' => self.del_to_eol(),
            'C' => {
                self.del_to_eol();
                self.mode = .insert;
            },
            'J' => self.join_line(),
            'r' => {
                self.pending = 'r';
                return; // don't clear pending below
            },
            // Yank / paste
            'p' => self.paste_after(),
            'P' => self.paste_before(),
            // Pending sequences
            'g' => {
                self.pending = 'g';
                return;
            },
            'd' => {
                self.pending = 'd';
                return;
            },
            'y' => {
                self.pending = 'y';
                return;
            },
            // Mode switches
            'v' => {
                self.mode = .visual;
                self.vis_start = self.cy;
            },
            ':' => {
                self.mode = .command;
                self.cmd_len = 0;
            },
            '/' => {
                self.mode = .search;
                self.cmd_len = 0;
            },
            // Search repeat
            'n' => self.search_next(),
            'N' => self.search_prev(),
            else => {},
        }
        self.ensure_visible();
    }

    // ═════════════════════════════════════════════════════════════════
    // Insert mode
    // ═════════════════════════════════════════════════════════════════

    fn handle_insert(self: *Editor, ev: owos.ps2.KeyEvent) void {
        if (self.do_arrows(ev)) return;
        if (ev.delete) {
            self.delete_forward();
            return;
        }
        const c = ev.char orelse return;
        switch (c) {
            0x1B => { // Esc → normal
                self.mode = .normal;
                if (self.cx > 0) self.cx -= 1;
                self.clamp_normal();
            },
            '\n' => {
                self.insert_newline();
                self.ensure_visible();
            },
            0x08 => {
                self.delete_backward();
                self.ensure_visible();
            },
            '\t' => {
                for (0..4) |_| self.insert_char(' ');
                self.ensure_visible();
            },
            else => {
                if (c >= 0x20 and c < 0x7F) {
                    self.insert_char(c);
                    self.ensure_visible();
                }
            },
        }
    }

    // ═════════════════════════════════════════════════════════════════
    // Visual mode (linewise)
    // ═════════════════════════════════════════════════════════════════

    fn handle_visual(self: *Editor, ev: owos.ps2.KeyEvent) void {
        if (self.do_arrows(ev)) return;
        const c = ev.char orelse return;
        switch (c) {
            0x1B => self.mode = .normal,
            'j' => self.move_down(),
            'k' => self.move_up(),
            'h' => {
                if (self.cx > 0) self.cx -= 1;
            },
            'l' => self.move_right_normal(),
            'w' => self.motion_w(),
            'b' => self.motion_b(),
            'G' => {
                self.cy = self.line_count - 1;
                self.clamp_normal();
            },
            'd' => {
                self.visual_delete();
                self.mode = .normal;
            },
            'y' => {
                self.visual_yank();
                self.mode = .normal;
            },
            else => {},
        }
        self.ensure_visible();
    }

    // ═════════════════════════════════════════════════════════════════
    // Command mode  (:w :q :wq :q! :<line>)
    // ═════════════════════════════════════════════════════════════════

    fn handle_command(self: *Editor, ev: owos.ps2.KeyEvent) void {
        const c = ev.char orelse return;
        switch (c) {
            0x1B => self.mode = .normal,
            '\n' => {
                self.exec_command();
                if (self.mode == .command) self.mode = .normal;
            },
            0x08 => {
                if (self.cmd_len > 0) self.cmd_len -= 1;
            },
            else => {
                if (c >= 0x20 and c < 0x7F and self.cmd_len < self.cmd_buf.len) {
                    self.cmd_buf[self.cmd_len] = c;
                    self.cmd_len += 1;
                }
            },
        }
    }

    fn exec_command(self: *Editor) void {
        const cmd = self.cmd_buf[0..self.cmd_len];
        if (cmd.len == 0) return;
        if (std.mem.eql(u8, cmd, "w")) {
            self.save();
        } else if (std.mem.eql(u8, cmd, "q")) {
            if (self.modified)
                self.set_status("Unsaved changes! Use :q! to force or :wq to save")
            else
                self.quit = true;
        } else if (std.mem.eql(u8, cmd, "q!")) {
            self.quit = true;
        } else if (std.mem.eql(u8, cmd, "wq") or std.mem.eql(u8, cmd, "x")) {
            self.save();
            self.quit = true;
        } else if (std.fmt.parseInt(usize, cmd, 10)) |line_no| {
            if (line_no > 0 and line_no <= self.line_count) {
                self.cy = line_no - 1;
                self.cx = 0;
                self.ensure_visible();
            }
        } else |_| {
            self.set_status("Unknown command");
        }
    }

    // ═════════════════════════════════════════════════════════════════
    // Search mode  (/pattern  then n/N)
    // ═════════════════════════════════════════════════════════════════

    fn handle_search(self: *Editor, ev: owos.ps2.KeyEvent) void {
        const c = ev.char orelse return;
        switch (c) {
            0x1B => self.mode = .normal,
            '\n' => {
                // Commit pattern and jump
                @memcpy(self.search_buf[0..self.cmd_len], self.cmd_buf[0..self.cmd_len]);
                self.search_len = self.cmd_len;
                self.mode = .normal;
                self.search_next();
            },
            0x08 => {
                if (self.cmd_len > 0) self.cmd_len -= 1;
            },
            else => {
                if (c >= 0x20 and c < 0x7F and self.cmd_len < self.cmd_buf.len) {
                    self.cmd_buf[self.cmd_len] = c;
                    self.cmd_len += 1;
                }
            },
        }
    }

    fn search_next(self: *Editor) void {
        if (self.search_len == 0) {
            self.set_status("No search pattern");
            return;
        }
        const pat = self.search_buf[0..self.search_len];
        var y = self.cy;
        var x = self.cx + 1;
        var wrapped = false;
        while (true) {
            if (y >= self.line_count) {
                y = 0;
                x = 0;
                wrapped = true;
            }
            if (wrapped and y > self.cy) break;
            if (wrapped and y == self.cy and x > self.cx) break;
            const line = self.lines[y][0..self.line_lens[y]];
            if (x + pat.len <= line.len) {
                if (find_in(line, pat, x)) |pos| {
                    if (!wrapped or pos != self.cx or y != self.cy) {
                        self.cy = y;
                        self.cx = pos;
                        self.ensure_visible();
                        if (wrapped) self.set_status("Search wrapped");
                        return;
                    }
                }
            }
            y += 1;
            x = 0;
        }
        self.set_status("Pattern not found");
    }

    fn search_prev(self: *Editor) void {
        if (self.search_len == 0) {
            self.set_status("No search pattern");
            return;
        }
        const pat = self.search_buf[0..self.search_len];
        var iy: isize = @intCast(self.cy);
        const start_x: usize = if (self.cx > 0) self.cx - 1 else 0;
        var first = true;
        var wrapped = false;
        while (true) {
            if (iy < 0) {
                iy = @as(isize, @intCast(self.line_count)) - 1;
                wrapped = true;
            }
            const y: usize = @intCast(iy);
            if (wrapped and y < self.cy) break;
            const line = self.lines[y][0..self.line_lens[y]];
            const sx = if (first) start_x else if (line.len >= pat.len) line.len - pat.len else 0;
            first = false;
            if (rfind_in(line, pat, sx)) |pos| {
                self.cy = y;
                self.cx = pos;
                self.ensure_visible();
                if (wrapped) self.set_status("Search wrapped");
                return;
            }
            iy -= 1;
        }
        self.set_status("Pattern not found");
    }

    fn find_in(hay: []const u8, needle: []const u8, start: usize) ?usize {
        if (needle.len == 0 or hay.len < needle.len) return null;
        var i = start;
        while (i + needle.len <= hay.len) : (i += 1) {
            if (std.mem.eql(u8, hay[i .. i + needle.len], needle)) return i;
        }
        return null;
    }

    fn rfind_in(hay: []const u8, needle: []const u8, start: usize) ?usize {
        if (needle.len == 0 or hay.len < needle.len) return null;
        var i: isize = @intCast(@min(start, hay.len - needle.len));
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            if (std.mem.eql(u8, hay[ui .. ui + needle.len], needle)) return ui;
        }
        return null;
    }

    // ═════════════════════════════════════════════════════════════════
    // Arrow / extended key handling (shared by all modes)
    // ═════════════════════════════════════════════════════════════════

    fn do_arrows(self: *Editor, ev: owos.ps2.KeyEvent) bool {
        if (ev.arrow_up) {
            self.move_up();
            self.ensure_visible();
            return true;
        }
        if (ev.arrow_down) {
            self.move_down();
            self.ensure_visible();
            return true;
        }
        if (ev.arrow_left) {
            if (self.cx > 0) self.cx -= 1;
            self.ensure_visible();
            return true;
        }
        if (ev.arrow_right) {
            if (self.mode == .insert) {
                if (self.cx < self.line_lens[self.cy]) self.cx += 1;
            } else self.move_right_normal();
            self.ensure_visible();
            return true;
        }
        if (ev.home) {
            self.cx = 0;
            return true;
        }
        if (ev.end) {
            self.cx = self.line_lens[self.cy];
            if (self.mode != .insert) self.clamp_normal();
            return true;
        }
        if (ev.delete) {
            if (self.mode == .insert)
                self.delete_forward()
            else
                self.del_char_at_cursor();
            return true;
        }
        return false;
    }

    // ═════════════════════════════════════════════════════════════════
    // Movement helpers
    // ═════════════════════════════════════════════════════════════════

    fn move_up(self: *Editor) void {
        if (self.cy > 0) {
            self.cy -= 1;
            self.clamp_for_mode();
        }
    }
    fn move_down(self: *Editor) void {
        if (self.cy < self.line_count - 1) {
            self.cy += 1;
            self.clamp_for_mode();
        }
    }
    fn move_right_normal(self: *Editor) void {
        const mx = if (self.line_lens[self.cy] > 0) self.line_lens[self.cy] - 1 else 0;
        if (self.cx < mx) self.cx += 1;
    }

    fn motion_w(self: *Editor) void {
        var x = self.cx;
        const line = self.lines[self.cy][0..self.line_lens[self.cy]];
        if (x < line.len) {
            if (is_word(line[x])) {
                while (x < line.len and is_word(line[x])) x += 1;
            } else if (line[x] != ' ') {
                while (x < line.len and !is_word(line[x]) and line[x] != ' ') x += 1;
            }
            while (x < line.len and line[x] == ' ') x += 1;
        }
        if (x >= line.len) {
            if (self.cy < self.line_count - 1) {
                self.cy += 1;
                self.cx = 0;
            }
        } else {
            self.cx = x;
        }
    }

    fn motion_b(self: *Editor) void {
        var y = self.cy;
        var x = self.cx;
        if (x == 0) {
            if (y > 0) {
                y -= 1;
                x = if (self.line_lens[y] > 0) self.line_lens[y] - 1 else 0;
            }
            self.cy = y;
            self.cx = x;
            return;
        }
        x -= 1;
        const line = self.lines[y][0..self.line_lens[y]];
        while (x > 0 and line[x] == ' ') x -= 1;
        if (is_word(line[x])) {
            while (x > 0 and is_word(line[x - 1])) x -= 1;
        } else if (line[x] != ' ') {
            while (x > 0 and !is_word(line[x - 1]) and line[x - 1] != ' ') x -= 1;
        }
        self.cy = y;
        self.cx = x;
    }

    fn motion_e(self: *Editor) void {
        var y = self.cy;
        var x = self.cx + 1;
        while (true) {
            const line = self.lines[y][0..self.line_lens[y]];
            while (x < line.len and line[x] == ' ') x += 1;
            if (x < line.len) {
                if (is_word(line[x])) {
                    while (x + 1 < line.len and is_word(line[x + 1])) x += 1;
                } else {
                    while (x + 1 < line.len and !is_word(line[x + 1]) and line[x + 1] != ' ') x += 1;
                }
                self.cy = y;
                self.cx = x;
                return;
            }
            if (y < self.line_count - 1) {
                y += 1;
                x = 0;
            } else break;
        }
    }

    fn first_non_space(self: *Editor) usize {
        const len = self.line_lens[self.cy];
        var x: usize = 0;
        while (x < len and self.lines[self.cy][x] == ' ') x += 1;
        return if (x >= len) 0 else x;
    }

    // ═════════════════════════════════════════════════════════════════
    // Text editing primitives
    // ═════════════════════════════════════════════════════════════════

    fn insert_char(self: *Editor, c: u8) void {
        const len = self.line_lens[self.cy];
        if (len >= max_line_len - 1) return;
        var i = len;
        while (i > self.cx) : (i -= 1) self.lines[self.cy][i] = self.lines[self.cy][i - 1];
        self.lines[self.cy][self.cx] = c;
        self.line_lens[self.cy] += 1;
        self.cx += 1;
        self.modified = true;
    }

    fn insert_newline(self: *Editor) void {
        if (self.line_count >= max_lines) return;
        var i = self.line_count;
        while (i > self.cy + 1) : (i -= 1) {
            @memcpy(&self.lines[i], &self.lines[i - 1]);
            self.line_lens[i] = self.line_lens[i - 1];
        }
        const old_len = self.line_lens[self.cy];
        const right = old_len - self.cx;
        @memcpy(self.lines[self.cy + 1][0..right], self.lines[self.cy][self.cx..old_len]);
        @memset(self.lines[self.cy + 1][right..max_line_len], 0);
        self.line_lens[self.cy + 1] = right;
        @memset(self.lines[self.cy][self.cx..old_len], 0);
        self.line_lens[self.cy] = self.cx;
        self.line_count += 1;
        self.cy += 1;
        self.cx = 0;
        self.modified = true;
    }

    fn delete_backward(self: *Editor) void {
        if (self.cx > 0) {
            const len = self.line_lens[self.cy];
            var i = self.cx - 1;
            while (i < len - 1) : (i += 1) self.lines[self.cy][i] = self.lines[self.cy][i + 1];
            self.lines[self.cy][len - 1] = 0;
            self.line_lens[self.cy] -= 1;
            self.cx -= 1;
            self.modified = true;
        } else if (self.cy > 0) {
            self.merge_line_up();
        }
    }

    fn delete_forward(self: *Editor) void {
        const len = self.line_lens[self.cy];
        if (self.cx < len) {
            var i = self.cx;
            while (i < len - 1) : (i += 1) self.lines[self.cy][i] = self.lines[self.cy][i + 1];
            self.lines[self.cy][len - 1] = 0;
            self.line_lens[self.cy] -= 1;
            self.modified = true;
        } else if (self.cy < self.line_count - 1) {
            const nlen = self.line_lens[self.cy + 1];
            if (len + nlen <= max_line_len) {
                @memcpy(self.lines[self.cy][len .. len + nlen], self.lines[self.cy + 1][0..nlen]);
                self.line_lens[self.cy] = len + nlen;
                self.remove_line(self.cy + 1);
                self.modified = true;
            }
        }
    }

    fn merge_line_up(self: *Editor) void {
        const prev = self.line_lens[self.cy - 1];
        const cur = self.line_lens[self.cy];
        if (prev + cur > max_line_len) return;
        @memcpy(self.lines[self.cy - 1][prev .. prev + cur], self.lines[self.cy][0..cur]);
        self.line_lens[self.cy - 1] = prev + cur;
        self.remove_line(self.cy);
        self.cy -= 1;
        self.cx = prev;
        self.modified = true;
    }

    fn remove_line(self: *Editor, y: usize) void {
        var i = y;
        while (i < self.line_count - 1) : (i += 1) {
            @memcpy(&self.lines[i], &self.lines[i + 1]);
            self.line_lens[i] = self.line_lens[i + 1];
        }
        self.line_lens[self.line_count - 1] = 0;
        @memset(&self.lines[self.line_count - 1], 0);
        if (self.line_count > 1) self.line_count -= 1;
    }

    fn del_char_at_cursor(self: *Editor) void {
        const len = self.line_lens[self.cy];
        if (len == 0) return;
        var i = self.cx;
        while (i < len - 1) : (i += 1) self.lines[self.cy][i] = self.lines[self.cy][i + 1];
        self.lines[self.cy][len - 1] = 0;
        self.line_lens[self.cy] -= 1;
        self.clamp_normal();
        self.modified = true;
    }

    fn del_to_eol(self: *Editor) void {
        const len = self.line_lens[self.cy];
        if (self.cx < len) {
            @memset(self.lines[self.cy][self.cx..len], 0);
            self.line_lens[self.cy] = self.cx;
            self.clamp_normal();
            self.modified = true;
        }
    }

    fn join_line(self: *Editor) void {
        if (self.cy >= self.line_count - 1) return;
        const cl = self.line_lens[self.cy];
        const nl = self.line_lens[self.cy + 1];
        const need = if (cl > 0) cl + 1 + nl else nl;
        if (need > max_line_len) return;
        if (cl > 0) {
            self.lines[self.cy][cl] = ' ';
            @memcpy(self.lines[self.cy][cl + 1 .. cl + 1 + nl], self.lines[self.cy + 1][0..nl]);
            self.line_lens[self.cy] = cl + 1 + nl;
            self.cx = cl;
        } else {
            @memcpy(self.lines[self.cy][0..nl], self.lines[self.cy + 1][0..nl]);
            self.line_lens[self.cy] = nl;
        }
        self.remove_line(self.cy + 1);
        self.modified = true;
    }

    fn open_line_below(self: *Editor) void {
        if (self.line_count >= max_lines) return;
        var i = self.line_count;
        while (i > self.cy + 1) : (i -= 1) {
            @memcpy(&self.lines[i], &self.lines[i - 1]);
            self.line_lens[i] = self.line_lens[i - 1];
        }
        @memset(&self.lines[self.cy + 1], 0);
        self.line_lens[self.cy + 1] = 0;
        self.line_count += 1;
        self.cy += 1;
        self.cx = 0;
        self.modified = true;
    }

    fn open_line_above(self: *Editor) void {
        if (self.line_count >= max_lines) return;
        var i = self.line_count;
        while (i > self.cy) : (i -= 1) {
            @memcpy(&self.lines[i], &self.lines[i - 1]);
            self.line_lens[i] = self.line_lens[i - 1];
        }
        @memset(&self.lines[self.cy], 0);
        self.line_lens[self.cy] = 0;
        self.line_count += 1;
        self.cx = 0;
        self.modified = true;
    }

    // ═════════════════════════════════════════════════════════════════
    // Yank / paste / visual operations (linewise)
    // ═════════════════════════════════════════════════════════════════

    fn do_delete_lines(self: *Editor, count_arg: usize) void {
        const count = @min(count_arg, self.line_count - self.cy);
        // Yank before delete
        self.yank_count = 0;
        for (0..count) |i| {
            if (self.yank_count < max_yank) {
                @memcpy(&self.yank_lines[self.yank_count], &self.lines[self.cy + i]);
                self.yank_lens[self.yank_count] = self.line_lens[self.cy + i];
                self.yank_count += 1;
            }
        }
        if (count >= self.line_count) {
            self.line_lens[0] = 0;
            @memset(&self.lines[0], 0);
            self.line_count = 1;
        } else {
            var i = self.cy;
            while (i + count < self.line_count) : (i += 1) {
                @memcpy(&self.lines[i], &self.lines[i + count]);
                self.line_lens[i] = self.line_lens[i + count];
            }
            self.line_count -= count;
        }
        if (self.cy >= self.line_count) self.cy = self.line_count - 1;
        self.clamp_normal();
        self.modified = true;
        self.fmt_status("{d} line(s) deleted", .{count});
    }

    fn do_yank_lines(self: *Editor, count_arg: usize) void {
        const count = @min(count_arg, self.line_count - self.cy);
        self.yank_count = 0;
        for (0..count) |i| {
            if (self.yank_count < max_yank) {
                @memcpy(&self.yank_lines[self.yank_count], &self.lines[self.cy + i]);
                self.yank_lens[self.yank_count] = self.line_lens[self.cy + i];
                self.yank_count += 1;
            }
        }
        self.fmt_status("{d} line(s) yanked", .{count});
    }

    fn paste_after(self: *Editor) void {
        if (self.yank_count == 0) return;
        self.insert_yanked_at(self.cy + 1);
        self.cy += 1;
        self.cx = 0;
        self.modified = true;
        self.ensure_visible();
    }

    fn paste_before(self: *Editor) void {
        if (self.yank_count == 0) return;
        self.insert_yanked_at(self.cy);
        self.cx = 0;
        self.modified = true;
        self.ensure_visible();
    }

    fn insert_yanked_at(self: *Editor, at: usize) void {
        const n = @min(self.yank_count, max_lines - self.line_count);
        if (n == 0) return;
        // Shift existing lines down by n
        if (self.line_count > at) {
            var i = self.line_count - 1;
            while (true) {
                @memcpy(&self.lines[i + n], &self.lines[i]);
                self.line_lens[i + n] = self.line_lens[i];
                if (i == at) break;
                i -= 1;
            }
        }
        for (0..n) |j| {
            @memcpy(&self.lines[at + j], &self.yank_lines[j]);
            self.line_lens[at + j] = self.yank_lens[j];
        }
        self.line_count += n;
    }

    fn visual_delete(self: *Editor) void {
        const sy = @min(self.vis_start, self.cy);
        const ey = @max(self.vis_start, self.cy);
        self.cy = sy;
        self.do_delete_lines(ey - sy + 1);
    }

    fn visual_yank(self: *Editor) void {
        const sy = @min(self.vis_start, self.cy);
        const ey = @max(self.vis_start, self.cy);
        const saved = self.cy;
        self.cy = sy;
        self.do_yank_lines(ey - sy + 1);
        self.cy = saved;
    }

    // ═════════════════════════════════════════════════════════════════
    // File I/O
    // ═════════════════════════════════════════════════════════════════

    fn save(self: *Editor) void {
        const name = self.fname();
        var content: [16384]u8 = undefined;
        var pos: usize = 0;
        for (0..self.line_count) |i| {
            const len = self.line_lens[i];
            if (pos + len + 1 > content.len) {
                self.set_status("File too large!");
                return;
            }
            @memcpy(content[pos .. pos + len], self.lines[i][0..len]);
            pos += len;
            if (i < self.line_count - 1) {
                content[pos] = '\n';
                pos += 1;
            }
        }
        // Delete old file
        const flist = ramfs.get_files();
        for (flist, 0..) |*slot, idx| {
            if (slot.*) |*f| {
                if (std.mem.eql(u8, f.name(), name)) {
                    ramfs.delete_file(idx);
                    break;
                }
            }
        }
        const file = ramfs.create_file(name) catch {
            self.set_status("Create error");
            return;
        };
        if (pos > 0) {
            _ = file.write(content[0..pos]) catch {
                self.set_status("Write error");
                return;
            };
        }
        self.modified = false;
        self.is_new = false;
        self.fmt_status("\"{s}\" {d}L, {d}B written", .{ name, self.line_count, pos });
    }

    fn load_content(self: *Editor, data: []const u8) void {
        self.line_count = 0;
        var start: usize = 0;
        for (data, 0..) |c, i| {
            if (c == '\n') {
                const len = @min(i - start, max_line_len);
                if (self.line_count < max_lines) {
                    @memcpy(self.lines[self.line_count][0..len], data[start .. start + len]);
                    self.line_lens[self.line_count] = len;
                    self.line_count += 1;
                }
                start = i + 1;
            }
        }
        if (start <= data.len and self.line_count < max_lines) {
            const len = @min(data.len - start, max_line_len);
            if (len > 0)
                @memcpy(self.lines[self.line_count][0..len], data[start .. start + len]);
            self.line_lens[self.line_count] = len;
            self.line_count += 1;
        }
        if (self.line_count == 0) self.line_count = 1;
    }

    // ═════════════════════════════════════════════════════════════════
    // Rendering
    // ═════════════════════════════════════════════════════════════════

    fn render(self: *Editor) void {
        const ch = rendering.ScrollingLog.char_height;
        const cw = rendering.ScrollingLog.char_width;
        const fb_w: usize = @intCast(rendering.GFB_WIDTH);
        const fb_h: usize = @intCast(rendering.GFB_HEIGHT);
        const gutter: usize = 6;
        const text_x = 2 + gutter * cw;
        const text_top = ch + 2;

        rendering.draw_rect(0, 0, fb_w, fb_h, 0x000000);

        // ── Top bar ──────────────────────────────────────────────────
        rendering.draw_rect(0, 0, fb_w, ch, 0x222244);
        var title_buf: [80]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "BEFO  {s}{s}", .{
            self.fname(),
            if (self.modified) @as([]const u8, " [+]") else @as([]const u8, ""),
        }) catch "BEFO";
        rendering.draw_text(cw, 0, title, @intFromEnum(C.BrightYellow));

        // Cursor pos (top right)
        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d},{d}", .{ self.cy + 1, self.cx + 1 }) catch "";
        rendering.draw_text(fb_w -| (pos_str.len * cw + cw), 0, pos_str, @intFromEnum(C.White));

        // ── Visual selection bounds ──────────────────────────────────
        const vis_sy = if (self.mode == .visual) @min(self.vis_start, self.cy) else 0;
        const vis_ey = if (self.mode == .visual) @max(self.vis_start, self.cy) else 0;

        // ── Text area ────────────────────────────────────────────────
        var row: usize = 0;
        while (row < self.view_rows and self.scroll_y + row < self.line_count) : (row += 1) {
            const li = self.scroll_y + row;
            const y = text_top + row * ch;

            // Visual highlight (full line background)
            if (self.mode == .visual and li >= vis_sy and li <= vis_ey) {
                const hl_w = @min((@max(self.line_lens[li], 1) + gutter) * cw + 4, fb_w);
                rendering.draw_rect(0, y, hl_w, ch, 0x333366);
            }

            // Line number (highlight current line)
            var num_buf: [6]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d:>4}  ", .{li + 1}) catch "      ";
            rendering.draw_text(2, y, num, @intFromEnum(if (li == self.cy) C.BrightYellow else C.DarkGrey));

            // Line text
            const ll = self.line_lens[li];
            if (ll > self.scroll_x) {
                const vs = self.scroll_x;
                const vl = @min(ll - vs, self.view_cols -| gutter);
                rendering.draw_text(text_x, y, self.lines[li][vs .. vs + vl], @intFromEnum(C.White));
            }
        }

        // ── Tilde lines (beyond buffer) ──────────────────────────────
        while (row < self.view_rows) : (row += 1) {
            const y = text_top + row * ch;
            rendering.draw_text(2, y, "~", @intFromEnum(C.DarkBlue));
        }

        // ── Cursor ───────────────────────────────────────────────────
        const cr = self.cy -| self.scroll_y;
        const cc = if (self.cx >= self.scroll_x) self.cx - self.scroll_x else 0;
        const cpx = 2 + (gutter + cc) * cw;
        const cpy = text_top + cr * ch;

        if (self.mode == .insert) {
            // Thin line cursor
            rendering.draw_rect(cpx, cpy, 2, ch, @intFromEnum(C.BrightGreen));
        } else {
            // Block cursor
            rendering.draw_rect(cpx, cpy, cw, ch, @intFromEnum(C.BrightGreen));
            if (self.line_lens[self.cy] > self.cx) {
                const char_at = [1]u8{self.lines[self.cy][self.cx]};
                rendering.draw_text(cpx, cpy, &char_at, 0x000000);
            }
        }

        // ── Bottom bar ───────────────────────────────────────────────
        const bot_y = fb_h -| ch;
        rendering.draw_rect(0, bot_y, fb_w, ch, 0x222244);

        if (self.mode == .command or self.mode == .search) {
            const prefix: []const u8 = if (self.mode == .command) ":" else "/";
            rendering.draw_text(cw, bot_y, prefix, @intFromEnum(C.White));
            if (self.cmd_len > 0)
                rendering.draw_text(cw * 2, bot_y, self.cmd_buf[0..self.cmd_len], @intFromEnum(C.White));
        } else {
            // Mode indicator
            const mode_label: []const u8 = switch (self.mode) {
                .normal => "-- NORMAL --",
                .insert => "-- INSERT --",
                .visual => "-- VISUAL --",
                else => "",
            };
            const mode_color: u32 = @intFromEnum(switch (self.mode) {
                .insert => C.BrightGreen,
                .visual => C.BrightMagenta,
                else => C.Grey,
            });
            rendering.draw_text(cw, bot_y, mode_label, mode_color);

            // Status message (center area)
            if (self.status_len > 0) {
                const sx = cw + (mode_label.len + 2) * cw;
                rendering.draw_text(sx, bot_y, self.status_buf[0..self.status_len], @intFromEnum(C.BrightYellow));
            }

            // Pending / count indicator (right side)
            if (self.pending != 0 or self.count_buf > 0) {
                var pb: [16]u8 = undefined;
                var pl: usize = 0;
                if (self.count_buf > 0) {
                    const s = std.fmt.bufPrint(&pb, "{d}", .{self.count_buf}) catch "";
                    pl = s.len;
                }
                if (self.pending != 0) {
                    pb[pl] = self.pending;
                    pl += 1;
                }
                if (pl > 0)
                    rendering.draw_text(fb_w -| ((pl + 2) * cw), bot_y, pb[0..pl], @intFromEnum(C.BrightYellow));
            }
        }

        rendering.swap();
    }

    // ═════════════════════════════════════════════════════════════════
    // Small helpers
    // ═════════════════════════════════════════════════════════════════

    fn fname(self: *const Editor) []const u8 {
        return self.filename[0..self.filename_len];
    }

    fn set_status(self: *Editor, msg: []const u8) void {
        const len = @min(msg.len, self.status_buf.len);
        @memcpy(self.status_buf[0..len], msg[0..len]);
        self.status_len = len;
    }

    fn fmt_status(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.status_buf, fmt, args) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = msg.len;
    }

    fn consume_count(self: *Editor) usize {
        const c = if (self.count_buf == 0) @as(usize, 1) else self.count_buf;
        self.count_buf = 0;
        return c;
    }

    fn clamp_normal(self: *Editor) void {
        const mx = if (self.line_lens[self.cy] > 0) self.line_lens[self.cy] - 1 else 0;
        if (self.cx > mx) self.cx = mx;
    }

    fn clamp_for_mode(self: *Editor) void {
        if (self.mode == .insert) {
            if (self.cx > self.line_lens[self.cy]) self.cx = self.line_lens[self.cy];
        } else self.clamp_normal();
    }

    fn ensure_visible(self: *Editor) void {
        if (self.cy < self.scroll_y) self.scroll_y = self.cy;
        if (self.cy >= self.scroll_y + self.view_rows)
            self.scroll_y = self.cy - self.view_rows + 1;
        const tc = self.view_cols -| 6;
        if (self.cx < self.scroll_x) self.scroll_x = self.cx;
        if (self.cx >= self.scroll_x + tc) self.scroll_x = self.cx - tc + 1;
    }
};
