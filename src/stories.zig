//! Pacote `stories`: lê `stories/*.txt` e `stories/genres.txt` e grava `out/stories.db`.
//! Formato-fonte e esquema em CONTRACT.md. Uma história com erro de formato falha o build.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const base = @import("main.zig");
const Db = base.Db;

pub const version = "1.0.0";
const out_path = "out/stories.db";

const Str = []const u8;

/// Palavras por minuto, por nível (A1…B2). A duração é arredondada para cima.
const words_per_minute = [_]u32{ 60, 80, 100, 120 };

pub fn build(io: Io, gpa: Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();

    const genres = try parseGenres(arena, try cwd.readFileAlloc(io, "stories/genres.txt", arena, .unlimited));

    var names: std.ArrayList(Str) = .empty;
    var dir = try cwd.openDir(io, "stories", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt") or std.mem.eql(u8, entry.name, "genres.txt")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort(Str, names.items, {}, lessStr);

    var list: std.ArrayList(Story) = .empty;
    var failed = false;
    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, arena, .unlimited);
        var err: ParseError = .{};
        const story = parseStory(arena, text, genres, &err) catch {
            std.debug.print("stories/{s}:{d}: {s}\n", .{ name, err.line, err.msg });
            failed = true;
            continue;
        };
        try list.append(arena, story);
    }
    if (failed) return error.BadStory;

    try cwd.createDirPath(io, "out");
    cwd.deleteFile(io, out_path) catch {};
    const db = try Db.open(out_path);
    defer db.close();
    try write(arena, db, genres, list.items);
    std.debug.print("  {d} histórias\n", .{list.items.len});
}

fn lessStr(_: void, a: Str, b: Str) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------- formato-fonte

const Genre = struct { id: Str, pt: Str, it: Str };

const Paragraph = struct {
    it: Str,
    pt: Str,
    words: u32,
    it_words: []const Span,
    it_sents: []const Span,
    pt_sents: []const Span,
};

const Story = struct {
    id: Str,
    title: Str,
    subtitle: Str,
    level: u8, // 1 A1 · 2 A2 · 3 B1 · 4 B2
    genre: Str,
    work: Str = "",
    part: u32 = 0,
    words: u32,
    minutes: u32,
    paragraphs: []const Paragraph,
};

const ParseError = struct { line: usize = 0, msg: Str = "" };

fn parseGenres(arena: Allocator, text: Str) ![]const Genre {
    var out: std.ArrayList(Genre) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.trim(u8, l, " \r").len == 0) continue;
        var cols = std.mem.splitScalar(u8, l, '|');
        const id = std.mem.trim(u8, cols.next() orelse continue, " \r");
        const pt = std.mem.trim(u8, cols.next() orelse return error.BadGenre, " \r");
        const it = std.mem.trim(u8, cols.next() orelse return error.BadGenre, " \r");
        try out.append(arena, .{ .id = id, .pt = pt, .it = it });
    }
    return out.items;
}

/// Cabeçalho `chave: valor` até a primeira linha vazia; depois, parágrafos separados por linha
/// vazia, cada um com as frases em italiano, uma linha `--` e as frases em português, uma por linha.
fn parseStory(arena: Allocator, text: Str, genres: []const Genre, err: *ParseError) !Story {
    var s: Story = .{ .id = "", .title = "", .subtitle = "", .level = 0, .genre = "", .words = 0, .minutes = 0, .paragraphs = &.{} };
    var paragraphs: std.ArrayList(Paragraph) = .empty;
    var it_lines: std.ArrayList(Str) = .empty;
    var pt_lines: std.ArrayList(Str) = .empty;
    const State = enum { header, it, pt };
    var state: State = .header;
    var para_line: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (true) {
        const raw = lines.next();
        n += 1;
        const l = if (raw) |r| std.mem.trim(u8, r, " \t\r") else "";
        err.line = n;
        if (state == .header) {
            if (l.len == 0) {
                state = .it;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, l, ':') orelse return fail(err, "cabeçalho sem ':'");
            const key = std.mem.trim(u8, l[0..colon], " ");
            const val = std.mem.trim(u8, l[colon + 1 ..], " ");
            if (std.mem.eql(u8, key, "uuid")) s.id = val //
            else if (std.mem.eql(u8, key, "title")) s.title = val //
            else if (std.mem.eql(u8, key, "subtitle")) s.subtitle = val //
            else if (std.mem.eql(u8, key, "level")) s.level = levelOf(val) orelse return fail(err, "nível deve ser A1, A2, B1 ou B2") //
            else if (std.mem.eql(u8, key, "genre")) s.genre = val //
            else if (std.mem.eql(u8, key, "work")) s.work = val //
            else if (std.mem.eql(u8, key, "part")) s.part = std.fmt.parseInt(u32, val, 10) catch return fail(err, "part deve ser um número") //
            else return fail(err, "chave desconhecida no cabeçalho");
            if (raw == null) break;
            continue;
        }
        if (l.len == 0) {
            // Fim do parágrafo (ou linhas vazias a mais).
            if (it_lines.items.len > 0 or pt_lines.items.len > 0) {
                err.line = para_line;
                if (state != .pt) return fail(err, "parágrafo sem a linha '--' e o português");
                if (it_lines.items.len != pt_lines.items.len) return fail(err, "parágrafo com número diferente de frases em italiano e em português");
                try paragraphs.append(arena, try makeParagraph(arena, it_lines.items, pt_lines.items));
                it_lines = .empty;
                pt_lines = .empty;
            }
            state = .it;
            if (raw == null) break;
            continue;
        }
        if (it_lines.items.len == 0 and state == .it) para_line = n;
        if (std.mem.eql(u8, l, "--")) {
            if (state != .it or it_lines.items.len == 0) return fail(err, "'--' fora do lugar");
            state = .pt;
            continue;
        }
        switch (state) {
            .it => try it_lines.append(arena, l),
            .pt => try pt_lines.append(arena, l),
            .header => unreachable,
        }
        if (raw == null) break;
    }

    err.line = 1;
    if (!isUuid(s.id)) return fail(err, "uuid ausente ou inválido");
    if (s.title.len == 0) return fail(err, "title ausente");
    if (s.subtitle.len == 0) return fail(err, "subtitle ausente");
    if (s.level == 0) return fail(err, "level ausente");
    for (genres) |g| {
        if (std.mem.eql(u8, g.id, s.genre)) break;
    } else return fail(err, "genre ausente ou fora de genres.txt");
    if ((s.work.len == 0) != (s.part == 0)) return fail(err, "work e part vêm juntos");
    if (paragraphs.items.len == 0) return fail(err, "história sem parágrafos");

    s.paragraphs = paragraphs.items;
    for (s.paragraphs) |p| s.words += p.words;
    const wpm = words_per_minute[s.level - 1];
    s.minutes = @max(1, (s.words + wpm - 1) / wpm);
    return s;
}

fn fail(err: *ParseError, msg: Str) error{BadStory} {
    err.msg = msg;
    return error.BadStory;
}

fn levelOf(v: Str) ?u8 {
    const levels = [_]Str{ "A1", "A2", "B1", "B2" };
    for (levels, 1..) |l, i| if (std.mem.eql(u8, l, v)) return @intCast(i);
    return null;
}

fn isUuid(s: Str) bool {
    if (s.len != 36) return false;
    for (s, 0..) |ch, i| switch (i) {
        8, 13, 18, 23 => if (ch != '-') return false,
        else => if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return false,
    };
    return true;
}

// ---------------------------------------------------------------- texto, palavras e spans

/// Início e fim (exclusivo) em unidades UTF-16, que é como o Dart indexa uma String.
const Span = struct { start: u16, end: u16 };

fn makeParagraph(arena: Allocator, it_lines: []const Str, pt_lines: []const Str) !Paragraph {
    const it = try joinSentences(arena, it_lines);
    const pt = try joinSentences(arena, pt_lines);
    const words = try tokenize(arena, it.text);
    return .{
        .it = it.text,
        .pt = pt.text,
        .words = @intCast(words.len),
        .it_words = words,
        .it_sents = it.spans,
        .pt_sents = pt.spans,
    };
}

/// Junta as frases com um espaço e devolve o span de cada uma.
fn joinSentences(arena: Allocator, lines: []const Str) !struct { text: Str, spans: []const Span } {
    var text: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var u16pos: usize = 0;
    for (lines, 0..) |l, i| {
        if (i > 0) {
            try text.append(arena, ' ');
            u16pos += 1;
        }
        const len = try utf16Len(l);
        try spans.append(arena, .{ .start = try toU16(u16pos), .end = try toU16(u16pos + len) });
        try text.appendSlice(arena, l);
        u16pos += len;
    }
    return .{ .text = text.items, .spans = spans.items };
}

fn utf16Len(s: Str) !usize {
    return std.unicode.calcUtf16LeLen(s);
}

fn toU16(n: usize) !u16 {
    return std.math.cast(u16, n) orelse error.ParagraphTooLong;
}

/// Palavras de um parágrafo em italiano: letras e dígitos. O apóstrofo entre letras une
/// (l'aria, c'è, dell'acqua = uma palavra); o hífen entre letras também. O apóstrofo no fim
/// só fica nos truncamentos conhecidos (po', va', di'…). Pontuação nunca é palavra.
pub fn tokenize(arena: Allocator, text: Str) ![]const Span {
    var out: std.ArrayList(Span) = .empty;
    const view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    // Código a código, guardando a posição em UTF-16 e em bytes.
    var start: ?usize = null; // UTF-16
    var start_byte: usize = 0;
    var pos: usize = 0;
    var byte: usize = 0;
    var prev_word = false;
    while (true) {
        const cs = it.nextCodepointSlice();
        const cp: u21 = if (cs) |x| try std.unicode.utf8Decode(x) else 0;
        const units: usize = if (cp >= 0x10000) 2 else 1;
        const is_word = cs != null and isWordChar(cp);
        if (is_word) {
            if (start == null) {
                start = pos;
                start_byte = byte;
            }
        } else if (start != null) {
            const joiner = cp == '\'' or cp == 0x2019 or cp == '-';
            const next_is_word = blk: {
                const peek = it.peek(1);
                if (peek.len == 0) break :blk false;
                break :blk isWordChar(std.unicode.utf8Decode(peek) catch 0);
            };
            if (joiner and prev_word and next_is_word) {
                // continua a mesma palavra
            } else {
                var end = pos;
                if ((cp == '\'' or cp == 0x2019) and isTruncation(text[start_byte..byte])) end += 1;
                try out.append(arena, .{ .start = try toU16(start.?), .end = try toU16(end) });
                start = null;
            }
        }
        if (cs == null) break;
        prev_word = is_word;
        pos += units;
        byte += cs.?.len;
    }
    return out.items;
}

fn isWordChar(cp: u21) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F => true,
        else => false,
    };
}

fn isTruncation(word: Str) bool {
    const list = [_]Str{ "po", "mo", "va", "fa", "sta", "da", "di", "to", "be", "de", "pie", "Po", "Va", "Fa", "Sta", "Da", "Di", "To", "Be" };
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

// ---------------------------------------------------------------- SQLite

const schema =
    \\PRAGMA journal_mode = OFF;
    \\CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE TABLE genre (id TEXT PRIMARY KEY, name_pt TEXT NOT NULL, name_it TEXT NOT NULL);
    \\CREATE TABLE story (
    \\  id TEXT PRIMARY KEY, title TEXT NOT NULL, subtitle TEXT NOT NULL,
    \\  level INTEGER NOT NULL, genre TEXT NOT NULL REFERENCES genre(id),
    \\  work TEXT NOT NULL, part INTEGER NOT NULL,
    \\  words INTEGER NOT NULL, minutes INTEGER NOT NULL);
    \\CREATE TABLE paragraph (
    \\  story_id TEXT NOT NULL REFERENCES story(id), pos INTEGER NOT NULL,
    \\  it TEXT NOT NULL, pt TEXT NOT NULL, words INTEGER NOT NULL,
    \\  it_words BLOB NOT NULL, it_sents BLOB NOT NULL, pt_sents BLOB NOT NULL,
    \\  PRIMARY KEY (story_id, pos)) WITHOUT ROWID;
;

fn write(arena: Allocator, db: Db, genres: []const Genre, list: []const Story) !void {
    try db.exec(schema);
    try db.exec("BEGIN");
    const meta = try db.prepare("INSERT INTO meta (key, value) VALUES (?1, ?2)");
    defer meta.finalize();
    meta.text(1, "version");
    meta.text(2, version);
    try meta.run();

    const g = try db.prepare("INSERT INTO genre (id, name_pt, name_it) VALUES (?1, ?2, ?3)");
    defer g.finalize();
    for (genres) |x| {
        g.text(1, x.id);
        g.text(2, x.pt);
        g.text(3, x.it);
        try g.run();
    }

    const st = try db.prepare("INSERT INTO story (id, title, subtitle, level, genre, work, part, words, minutes) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)");
    defer st.finalize();
    const pa = try db.prepare("INSERT INTO paragraph (story_id, pos, it, pt, words, it_words, it_sents, pt_sents) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)");
    defer pa.finalize();
    for (list) |s| {
        st.text(1, s.id);
        st.text(2, s.title);
        st.text(3, s.subtitle);
        st.int(4, s.level);
        st.text(5, s.genre);
        st.text(6, s.work);
        st.int(7, s.part);
        st.int(8, s.words);
        st.int(9, s.minutes);
        try st.run();
        for (s.paragraphs, 0..) |p, i| {
            const w = try spansBlob(arena, p.it_words);
            const is = try spansBlob(arena, p.it_sents);
            const ps = try spansBlob(arena, p.pt_sents);
            pa.text(1, s.id);
            pa.int(2, @intCast(i));
            pa.text(3, p.it);
            pa.text(4, p.pt);
            pa.int(5, p.words);
            pa.blob(6, w);
            pa.blob(7, is);
            pa.blob(8, ps);
            try pa.run();
        }
    }
    try db.exec("COMMIT");
    try db.exec("VACUUM");
}

/// Pares (início, fim) em u16 little-endian.
fn spansBlob(arena: Allocator, spans: []const Span) ![]const u8 {
    const out = try arena.alloc(u8, spans.len * 4);
    for (spans, 0..) |sp, i| {
        std.mem.writeInt(u16, out[i * 4 ..][0..2], sp.start, .little);
        std.mem.writeInt(u16, out[i * 4 + 2 ..][0..2], sp.end, .little);
    }
    return out;
}

// ---------------------------------------------------------------- testes

fn wordTexts(arena: Allocator, text: Str) ![]const Str {
    // Converte os spans de volta em texto para comparar (o texto do teste é ASCII + BMP).
    const units = try std.unicode.utf8ToUtf16LeAlloc(arena, text);
    var out: std.ArrayList(Str) = .empty;
    for (try tokenize(arena, text)) |sp| {
        try out.append(arena, try std.unicode.utf16LeToUtf8Alloc(arena, units[sp.start..sp.end]));
    }
    return out.items;
}

test "palavras, elisões e pontuação" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = try wordTexts(a, "Accanto a lei c'è un uomo. «Va anche lei?» L’aria, dell'acqua e un po' di porta-finestra; 1883!");
    const want = [_]Str{ "Accanto", "a", "lei", "c'è", "un", "uomo", "Va", "anche", "lei", "L’aria", "dell'acqua", "e", "un", "po'", "di", "porta-finestra", "1883" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "aspas no fim não entram na palavra" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = try wordTexts(a, "dice 'ciao' e va' via");
    const want = [_]Str{ "dice", "ciao", "e", "va'", "via" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "formato-fonte: frases desalinhadas falham" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const genres = [_]Genre{.{ .id = "viaggio", .pt = "Viagem", .it = "Viaggio" }};
    const head =
        \\uuid: d0159518-99cc-46f0-bef2-b5b6f6f9a76d
        \\title: Il treno
        \\subtitle: Marta parte.
        \\level: A2
        \\genre: viaggio
        \\
        \\
    ;
    var err: ParseError = .{};
    const ok = try parseStory(a, head ++ "Marta arriva.\nIl treno parte.\n--\nMarta chega.\nO trem sai.\n", &genres, &err);
    try std.testing.expectEqual(1, ok.paragraphs.len);
    try std.testing.expectEqual(5, ok.words);
    try std.testing.expectEqual(1, ok.minutes);
    try std.testing.expectEqual(Span{ .start = 14, .end = 29 }, ok.paragraphs[0].it_sents[1]);
    try std.testing.expectError(error.BadStory, parseStory(a, head ++ "Marta arriva.\nIl treno parte.\n--\nMarta chega.\n", &genres, &err));
    try std.testing.expectEqual(7, err.line);
}
