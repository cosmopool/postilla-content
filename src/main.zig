//! Pipeline de conteúdo do Postilla: `fetch`, `dict`, `stories`, `pack`.
//! Lê de `data/`, escreve em `out/`. Contrato dos bancos em CONTRACT.md.
const std = @import("std");
const Io = std.Io;
const c = @import("c");

pub const dict = @import("dict.zig");
pub const stories = @import("stories.zig");

const Command = enum { fetch, dict, stories, pack };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cmd = if (args.len > 1) std.meta.stringToEnum(Command, args[1]) else null;
    switch (cmd orelse {
        std.debug.print("uso: postilla-content <fetch|dict|stories|pack>\n", .{});
        std.process.exit(2);
    }) {
        .fetch => try fetch(init.io, init.gpa),
        .dict => try dict.build(init.io, init.gpa),
        .stories => try stories.build(init.io, init.gpa),
        .pack => try pack(init.io, init.gpa),
    }
}

// ---------------------------------------------------------------- fetch

pub const Source = struct { file: []const u8, url: []const u8 };

/// Fontes baixadas por `fetch`. Os dois arquivos do it.wiktionary são do mesmo dump.
/// O JSONL do kaikki it não tem URL por data: o `fetch` pula arquivo que já existe.
pub const sources = [_]Source{
    .{ .file = "kaikki-it.jsonl.gz", .url = "https://kaikki.org/itwiktionary/Italiano/kaikki.org-dictionary-Italiano.jsonl.gz" },
    .{ .file = "itwiktionary-pages-articles.xml.bz2", .url = "https://dumps.wikimedia.org/itwiktionary/20261001/itwiktionary-20261001-pages-articles.xml.bz2" },
    .{ .file = "wikdict-it-pt.sqlite3", .url = "https://download.wikdict.com/dictionaries/sqlite/2/it-pt.sqlite3" },
    .{ .file = "wikdict-en-pt.sqlite3", .url = "https://download.wikdict.com/dictionaries/sqlite/2/en-pt.sqlite3" },
    .{ .file = "kaikki-en-it.jsonl.gz", .url = "https://kaikki.org/dictionary/Italian/kaikki.org-dictionary-Italian.jsonl.gz" },
};

fn fetch(io: Io, gpa: std.mem.Allocator) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, "data");
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    for (sources) |s| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "data/{s}", .{s.file});
        if (cwd.access(io, path, .{})) |_| {
            std.debug.print("{s}: já existe\n", .{path});
            continue;
        } else |_| {}
        std.debug.print("{s} ← {s}\n", .{ path, s.url });
        var tmp_buf: [256]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.part", .{path});
        const file = try cwd.createFile(io, tmp, .{});
        var wbuf: [1 << 16]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        const res = try client.fetch(.{ .location = .{ .url = s.url }, .response_writer = &fw.interface });
        try fw.interface.flush();
        file.close(io);
        if (res.status != .ok) {
            std.debug.print("{s}: HTTP {d}\n", .{ s.url, @intFromEnum(res.status) });
            return error.FetchFailed;
        }
        try cwd.rename(tmp, cwd, path, io);
    }
}

// ---------------------------------------------------------------- pack

/// gzip -9 de cada `.db` de `out/` e um `out/SHA256SUMS` com o `.db` e o `.gz`.
/// Os pacotes saem com a versão no nome (`dict-1.0.0.db.gz`), como o lock do app espera.
fn pack(io: Io, gpa: std.mem.Allocator) !void {
    _ = gpa;
    const cwd = Io.Dir.cwd();
    const packages = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "dict", .version = dict.version },
        .{ .name = "stories", .version = stories.version },
    };
    var sums: [4096]u8 = undefined;
    var sums_len: usize = 0;
    for (packages) |p| {
        var db_buf: [64]u8 = undefined;
        var gz_buf: [64]u8 = undefined;
        const db_path = try std.fmt.bufPrint(&db_buf, "out/{s}.db", .{p.name});
        const gz_path = try std.fmt.bufPrint(&gz_buf, "out/{s}-{s}.db.gz", .{ p.name, p.version });
        std.debug.print("{s} → {s}\n", .{ db_path, gz_path });

        const in = try cwd.openFile(io, db_path, .{});
        defer in.close(io);
        var rbuf: [1 << 16]u8 = undefined;
        var fr = in.reader(io, &rbuf);
        const out = try cwd.createFile(io, gz_path, .{});
        defer out.close(io);
        var wbuf: [1 << 16]u8 = undefined;
        var fw = out.writer(io, &wbuf);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var z = try std.compress.flate.Compress.init(&fw.interface, &window, .gzip, .best);
        _ = try fr.interface.streamRemaining(&z.writer);
        try z.finish();
        try fw.interface.flush();

        const db_sum = try sha256File(io, db_path);
        const gz_sum = try sha256File(io, gz_path);
        const line = try std.fmt.bufPrint(sums[sums_len..], "{s}  {s}.db\n{s}  {s}-{s}.db.gz\n", .{ &db_sum, p.name, &gz_sum, p.name, p.version });
        sums_len += line.len;
    }
    try cwd.writeFile(io, .{ .sub_path = "out/SHA256SUMS", .data = sums[0..sums_len] });
    std.debug.print("{s}", .{sums[0..sums_len]});
}

// ---------------------------------------------------------------- compartilhado

/// SQLite com o mínimo: exec, statements preparados e erro no stderr.
pub const Db = struct {
    h: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var h: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path.ptr, &h, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_URI, null) != c.SQLITE_OK) {
            std.debug.print("sqlite open {s}: {s}\n", .{ path, c.sqlite3_errmsg(h) });
            return error.Sqlite;
        }
        return .{ .h = h.? };
    }

    pub fn close(db: Db) void {
        _ = c.sqlite3_close(db.h);
    }

    pub fn exec(db: Db, sql: [:0]const u8) !void {
        var err: [*c]u8 = null;
        if (c.sqlite3_exec(db.h, sql.ptr, null, null, &err) != c.SQLITE_OK) {
            std.debug.print("sqlite: {s}\n  em: {s}\n", .{ err, sql });
            c.sqlite3_free(err);
            return error.Sqlite;
        }
    }

    pub fn prepare(db: Db, sql: [:0]const u8) !Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.h, sql.ptr, @intCast(sql.len), &s, null) != c.SQLITE_OK) {
            std.debug.print("sqlite: {s}\n  em: {s}\n", .{ c.sqlite3_errmsg(db.h), sql });
            return error.Sqlite;
        }
        return .{ .s = s.?, .db = db.h };
    }
};

/// Os `bind` não copiam (SQLITE_STATIC): o valor precisa viver até o `step`/`run`.
pub const Stmt = struct {
    s: *c.sqlite3_stmt,
    db: *c.sqlite3,

    pub fn text(st: Stmt, i: c_int, v: []const u8) void {
        _ = c.sqlite3_bind_text(st.s, i, v.ptr, @intCast(v.len), null);
    }
    pub fn int(st: Stmt, i: c_int, v: i64) void {
        _ = c.sqlite3_bind_int64(st.s, i, v);
    }
    pub fn blob(st: Stmt, i: c_int, v: []const u8) void {
        _ = c.sqlite3_bind_blob(st.s, i, v.ptr, @intCast(v.len), null);
    }
    /// true enquanto houver linha; false no fim.
    pub fn step(st: Stmt) !bool {
        return switch (c.sqlite3_step(st.s)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => {
                std.debug.print("sqlite step: {s}\n", .{c.sqlite3_errmsg(st.db)});
                return error.Sqlite;
            },
        };
    }
    /// Roda uma escrita e deixa o statement pronto para a próxima.
    pub fn run(st: Stmt) !void {
        _ = try st.step();
        _ = c.sqlite3_reset(st.s);
        _ = c.sqlite3_clear_bindings(st.s);
    }
    pub fn reset(st: Stmt) void {
        _ = c.sqlite3_reset(st.s);
        _ = c.sqlite3_clear_bindings(st.s);
    }
    pub fn colText(st: Stmt, i: c_int) []const u8 {
        const p = c.sqlite3_column_text(st.s, i) orelse return "";
        return p[0..@intCast(c.sqlite3_column_bytes(st.s, i))];
    }
    pub fn colInt(st: Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(st.s, i);
    }
    pub fn colFloat(st: Stmt, i: c_int) f64 {
        return c.sqlite3_column_double(st.s, i);
    }
    pub fn finalize(st: Stmt) void {
        _ = c.sqlite3_finalize(st.s);
    }
};

/// Lê um `.jsonl.gz` linha a linha. A linha devolvida vale até a próxima chamada.
pub const GzLines = struct {
    file: Io.File,
    fr: Io.File.Reader,
    dec: std.compress.flate.Decompress,
    line: Io.Writer.Allocating,
    fbuf: [1 << 16]u8,
    dbuf: [std.compress.flate.max_window_len]u8,

    /// `self` precisa ter endereço fixo (os readers apontam para os buffers).
    pub fn open(self: *GzLines, io: Io, gpa: std.mem.Allocator, path: []const u8) !void {
        self.file = try Io.Dir.cwd().openFile(io, path, .{});
        self.fr = self.file.reader(io, &self.fbuf);
        self.dec = .init(&self.fr.interface, .gzip, &self.dbuf);
        self.line = .init(gpa);
    }

    pub fn next(self: *GzLines) !?[]const u8 {
        self.line.clearRetainingCapacity();
        _ = self.dec.reader.streamDelimiter(&self.line.writer, '\n') catch |e| switch (e) {
            error.EndOfStream => return if (self.line.written().len > 0) self.line.written() else null,
            else => return e,
        };
        self.dec.reader.toss(1);
        return self.line.written();
    }

    pub fn close(self: *GzLines, io: Io) void {
        self.line.deinit();
        self.file.close(io);
    }
};

/// sha256 de um arquivo, em hexa.
pub fn sha256File(io: Io, path: []const u8) ![64]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [1 << 16]u8 = undefined;
    var fr = file.reader(io, &buf);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const chunk = fr.interface.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        h.update(chunk);
        fr.interface.toss(chunk.len);
    }
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{h.finalResult()}) catch unreachable;
    return out;
}

/// Minúscula e sem acento (ARQ-63): "Città" → "citta". Só o latim que o italiano usa;
/// o resto passa igual. Escreve em `out` e devolve a fatia escrita.
pub fn normalize(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |cs| {
        const cp = std.unicode.utf8Decode(cs) catch 0xFFFD;
        const base: u21 = switch (cp) {
            'A'...'Z' => cp + 32,
            0xC0...0xC5, 0xE0...0xE5 => 'a',
            0xC8...0xCB, 0xE8...0xEB => 'e',
            0xCC...0xCF, 0xEC...0xEF => 'i',
            0xD2...0xD6, 0xF2...0xF6 => 'o',
            0xD9...0xDC, 0xF9...0xFC => 'u',
            0xC7, 0xE7 => 'c',
            0xD1, 0xF1 => 'n',
            0x2019 => '\'',
            else => cp,
        };
        if (base < 0x80) {
            if (n >= out.len) break;
            out[n] = @intCast(base);
            n += 1;
        } else {
            if (n + cs.len > out.len) break;
            const len = std.unicode.utf8Encode(base, out[n..]) catch break;
            n += len;
        }
    }
    return out[0..n];
}

test normalize {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("citta", normalize(&buf, "Città"));
    try std.testing.expectEqualStrings("perche", normalize(&buf, "perché"));
    try std.testing.expectEqualStrings("l'aria", normalize(&buf, "L’aria"));
}

export fn bz_internal_error(code: c_int) void {
    std.debug.panic("bzip2 internal error {d}", .{code});
}

test {
    std.testing.refAllDecls(@This());
}
