//! Etapas 2–6 do pipeline do dicionário: lê o JSONL do kaikki (it.wiktionary), o wikitext,
//! as fontes da glosa PT e o NVdB, e grava `out/dict.db`. Campos em dictionary.md.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const base = @import("main.zig");
const Db = base.Db;

pub const version = "1.0.0";
const out_path = "out/dict.db";

pub fn build(io: Io, gpa: Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    std.debug.print("wikitext…\n", .{});
    const wiki = try readWikitext(io, arena);
    std.debug.print("  {d} páginas com rel/alter/noconf\n", .{wiki.count()});

    std.debug.print("en.wiktionary (pivô)…\n", .{});
    const en = try readEnglishGlosses(io, gpa, arena);
    std.debug.print("  {d} lemas com glosa em inglês\n", .{en.count()});

    std.debug.print("NVdB…\n", .{});
    const nvdb = try readNvdb(io, arena);

    const corrections = try readCorrections(io, arena);

    try Io.Dir.cwd().createDirPath(io, "out");
    Io.Dir.cwd().deleteFile(io, out_path) catch {};
    const db = try Db.open(out_path);
    defer db.close();
    try db.exec(schema);

    const glosses: Glosses = try .open(en);
    defer glosses.close();

    std.debug.print("kaikki it…\n", .{});
    try readEntries(io, gpa, db, wiki, glosses, nvdb, corrections);

    try writeMeta(io, db, arena);
    std.debug.print("índices e VACUUM…\n", .{});
    try db.exec(indexes);
    try db.exec("VACUUM");
}

const schema =
    \\PRAGMA journal_mode = OFF;
    \\PRAGMA synchronous = OFF;
    \\CREATE TABLE meta  (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE TABLE entry (id INTEGER PRIMARY KEY, word TEXT NOT NULL, word_norm TEXT NOT NULL,
    \\                    pos TEXT NOT NULL, band INTEGER NOT NULL, data TEXT NOT NULL);
    \\CREATE TABLE form  (form TEXT NOT NULL, form_norm TEXT NOT NULL, entry_id INTEGER NOT NULL);
;

const indexes =
    \\CREATE INDEX entry_word ON entry(word);
    \\CREATE INDEX entry_word_norm ON entry(word_norm);
    \\CREATE INDEX form_form ON form(form);
    \\CREATE INDEX form_form_norm ON form(form_norm);
;

// ---------------------------------------------------------------- JSONL do kaikki (entrada)

const Str = []const u8;
const KForm = struct { form: Str = "", tags: []const Str = &.{}, raw_tags: []const Str = &.{}, source: Str = "" };
const KLink = struct { word: Str = "", tags: []const Str = &.{}, raw_tags: []const Str = &.{} };
const KWord = struct { word: Str = "" };
const KText = struct { text: Str = "" };
const KName = struct { name: Str = "" };
const KSense = struct {
    glosses: []const Str = &.{},
    tags: []const Str = &.{},
    raw_tags: []const Str = &.{},
    topics: []const Str = &.{},
    examples: []const KText = &.{},
    form_of: []const KWord = &.{},
    alt_of: []const KWord = &.{},
    categories: []const KName = &.{},
};
const KEntry = struct {
    word: Str = "",
    pos: Str = "",
    tags: []const Str = &.{},
    forms: []const KForm = &.{},
    senses: []const KSense = &.{},
    hyphenations: []const struct { parts: []const Str = &.{} } = &.{},
    sounds: []const struct { ipa: Str = "" } = &.{},
    etymology_texts: []const Str = &.{},
    synonyms: []const KLink = &.{},
    antonyms: []const KLink = &.{},
    derived: []const KLink = &.{},
    categories: []const KName = &.{},
    translations: []const struct { lang_code: Str = "", word: Str = "" } = &.{},
};

// ---------------------------------------------------------------- verbete (saída, entry.data)

const Link = struct { word: Str, note: ?Str = null };
const Altered = struct { word: Str, kind: Str };
const Flex = struct { form: Str, tags: Str };
const Sense = struct { gloss: Str, labels: ?[]const Str = null, examples: ?[]const Str = null };
const Conj = struct { tense: u8, person: u8, forms: []const Str };

/// Uma linha de `entry.data`. Campo vazio é null e não é gravado.
const Data = struct {
    word: Str,
    pos: Str,
    tags: ?[]const Str = null,
    valency: ?Str = null,
    aux: ?Str = null,
    flex: ?[]const Flex = null,
    syll: ?[]const Str = null,
    ipa: ?Str = null,
    gloss: ?[]const Str = null,
    gloss_src: ?Str = null,
    senses: []const Sense,
    conj: ?[]const Conj = null,
    participle: ?Str = null,
    gerund: ?Str = null,
    etym: ?Str = null,
    syn: ?[]const Link = null,
    ant: ?[]const Link = null,
    derived: ?[]const Link = null,
    related: ?[]const Str = null,
    altered: ?[]const Altered = null,
    confusables: ?[]const Str = null,
};

fn orNull(comptime T: type, s: []const T) ?[]const T {
    return if (s.len == 0) null else s;
}

// ---------------------------------------------------------------- tabelas fixas

const Pair = struct { Str, Str };

/// `pos` do kaikki → classe em italiano. Fora da tabela, a entrada não vira verbete.
const pos_names = std.StaticStringMap(Str).initComptime(.{
    .{ "noun", "sostantivo" },                 .{ "verb", "verbo" },
    .{ "adj", "aggettivo" },                   .{ "adv", "avverbio" },
    .{ "name", "nome proprio" },               .{ "phrase", "locuzione" },
    .{ "adv_phrase", "locuzione avverbiale" }, .{ "prep_phrase", "locuzione prepositiva" },
    .{ "abbrev", "abbreviazione" },            .{ "prefix", "prefisso" },
    .{ "suffix", "suffisso" },                 .{ "affix", "affisso" },
    .{ "intj", "interiezione" },               .{ "pron", "pronome" },
    .{ "conj", "congiunzione" },               .{ "prep", "preposizione" },
    .{ "article", "articolo" },                .{ "num", "numerale" },
    .{ "symbol", "simbolo" },                  .{ "character", "carattere" },
    .{ "particle", "particella" },
});

/// Tags da entrada que aparecem na linha da classe.
const entry_tags = std.StaticStringMap(Str).initComptime(.{
    .{ "masculine", "maschile" }, .{ "feminine", "femminile" }, .{ "invariable", "invariabile" },
});

/// Valência do verbo, pelas categorias da entrada.
const valency_cats = [_]Pair{
    .{ "Verbi intransitivi pronominali_in_italiano", "intransitivo pronominale" },
    .{ "Verbi riflessivi_in_italiano", "riflessivo" },
    .{ "Verbi transitivi_in_italiano", "transitivo" },
    .{ "Verbi intransitivi_in_italiano", "intransitivo" },
};

/// Rótulos de registro e área → abreviação italiana (dictionary.md, Significati).
/// Valor sem mapeamento conta no relatório e não aparece.
const labels = std.StaticStringMap(Str).initComptime(.{
    // senses[].tags
    .{ "figuratively", "fig." },     .{ "broadly", "estens." },       .{ "rare", "raro" },
    .{ "archaic", "ant." },          .{ "obsolete", "obsol." },       .{ "slang", "gerg." },
    .{ "literary", "letter." },      .{ "pejorative", "spreg." },     .{ "regional", "region." },
    .{ "vulgar", "volg." },          .{ "neologism", "neol." },       .{ "literally", "lett." },
    .{ "colloquial", "colloq." },    .{ "offensive", "offens." },     .{ "informal", "inform." },
    .{ "formal", "form." },          .{ "diminutive", "dim." },       .{ "augmentative", "accr." },
    .{ "toponymic", "topon." },
    // senses[].raw_tags
    .{ "familiare", "fam." },        .{ "forestierismo", "forest." }, .{ "scherzoso", "scherz." },
    .{ "popolare", "pop." },         .{ "toscano", "tosc." },         .{ "diritto", "dir." },
    .{ "gastronomia", "gastr." },    .{ "professione", "profess." },  .{ "scuola", "scuola" },
    .{ "pittura", "pitt." },         .{ "enologia", "enol." },        .{ "burocrazia", "burocr." },
    .{ "metrica", "metr." },         .{ "giochi", "giochi" },         .{ "uso letterario", "letter." },
    .{ "ironico", "iron." },         .{ "arcaico", "ant." },          .{ "settentrionale", "sett." },
    .{ "cinema", "cine." },          .{ "dialettale", "dial." },      .{ "televisione", "tv" },
    .{ "poetico", "poet." },         .{ "nautica", "naut." },         .{ "estensione", "estens." },
    .{ "figurato", "fig." },         .{ "giornalismo", "giorn." },    .{ "romanesco", "roman." },
    .{ "cucina", "cucina" },         .{ "inglesismo", "ingl." },      .{ "eufemismo", "eufem." },
    .{ "disusato", "disus." },       .{ "dispregiativo", "spreg." },  .{ "meridionale", "merid." },
    .{ "estensivo", "estens." },     .{ "figurativo", "fig." },       .{ "letterale", "lett." },
    .{ "non comune", "raro" },
    // senses[].topics
    .{ "medicine", "med." },         .{ "chemistry", "chim." },       .{ "biology", "biol." },
    .{ "physics", "fis." },          .{ "economics", "econ." },       .{ "technology", "tecn." },
    .{ "zoology", "zool." },         .{ "engineering", "ingegn." },   .{ "history", "stor." },
    .{ "botany", "bot." },           .{ "geography", "geogr." },      .{ "mathematics", "mat." },
    .{ "heraldry", "arald." },       .{ "politics", "polit." },       .{ "architecture", "archit." },
    .{ "informatics", "inform." },   .{ "religion", "relig." },       .{ "philosophy", "filos." },
    .{ "mechanics", "mecc." },       .{ "electronics", "elettron." }, .{ "commerce", "comm." },
    .{ "linguistics", "ling." },     .{ "pharmacology", "farm." },    .{ "sports", "sport" },
    .{ "anatomy", "anat." },         .{ "music", "mus." },            .{ "biochemistry", "biochim." },
    .{ "finance", "fin." },          .{ "psychology", "psicol." },    .{ "sociology", "sociol." },
    .{ "ornithology", "ornit." },    .{ "physiology", "fisiol." },    .{ "arts", "arte" },
    .{ "military", "mil." },         .{ "Christianity", "crist." },   .{ "electrical-engineering", "elettr." },
    .{ "geology", "geol." },         .{ "navy", "mar." },             .{ "geometry", "geom." },
    .{ "literature", "lett." },      .{ "statistics", "stat." },      .{ "mammalogy", "zool." },
    .{ "astronomy", "astron." },     .{ "clothing", "abbigl." },      .{ "aeronautics", "aeron." },
    .{ "agriculture", "agr." },      .{ "anthropology", "antrop." },  .{ "construction", "edil." },
    .{ "entomology", "entom." },     .{ "metallurgy", "metall." },    .{ "sexuality", "sess." },
    .{ "color", "colore" },          .{ "surgery", "chir." },         .{ "mineralogy", "miner." },
    .{ "psychiatry", "psich." },     .{ "cinematography", "cine." },  .{ "grammar", "gramm." },
    .{ "theater", "teatro" },        .{ "psychoanalysis", "psicoan." }, .{ "textiles", "tess." },
    .{ "soccer", "calcio" },         .{ "mythology", "mitol." },      .{ "ichthyology", "ittiol." },
    .{ "arithmetic", "aritm." },     .{ "archaeology", "archeol." },  .{ "ecology", "ecol." },
    .{ "weaponry", "armi" },         .{ "meteorology", "meteor." },   .{ "typography", "tipogr." },
    .{ "herpetology", "zool." },     .{ "paleontology", "paleont." }, .{ "ethnology", "etnol." },
    .{ "photography", "fot." },      .{ "carpentry", "falegn." },     .{ "numismatics", "numism." },
    .{ "poetry", "poes." },          .{ "hydraulics", "idraul." },    .{ "dance", "danza" },
    .{ "card-games", "giochi" },     .{ "biotechnology", "biotecn." },
});

/// Pessoa do imperativo, pelo raw_tag (as tags dele não trazem pessoa).
const imper_person = std.StaticStringMap(u8).initComptime(.{
    .{ "tu", 2 }, .{ "lui/lei", 3 }, .{ "noi", 4 }, .{ "voi", 5 }, .{ "essi/esse", 6 },
});

const altered_kinds = [_]Pair{
    .{ "{{Dim", "diminutivo" },     .{ "{{Accr", "accrescitivo" },
    .{ "{{Vezz", "vezzeggiativo" }, .{ "{{Pegg", "peggiorativo" },
};

fn has(list: []const Str, s: Str) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

// ---------------------------------------------------------------- etapa 3: wikitext

const Wiki = struct { related: []const Str, altered: []const Altered, confusables: []const Str };
const WikiMap = std.StringHashMapUnmanaged(Wiki);

/// Lê `{{-rel-}}`, `{{-alter-}}` e `{{-noconf-}}` da seção `{{-it-}}` de cada página.
fn readWikitext(io: Io, arena: Allocator) !WikiMap {
    var map: WikiMap = .empty;
    const file = try Io.Dir.cwd().openFile(io, "data/itwiktionary-pages-articles.xml.bz2", .{});
    defer file.close(io);
    var fbuf: [1 << 16]u8 = undefined;
    var fr = file.reader(io, &fbuf);
    const bz = try arena.create(Bz2Reader);
    try bz.init(&fr.interface);
    defer bz.deinit();

    var page: std.ArrayList(u8) = .empty;
    var line: Io.Writer.Allocating = .init(arena);
    var in_page = false;
    while (true) {
        line.clearRetainingCapacity();
        _ = bz.reader.streamDelimiter(&line.writer, '\n') catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        bz.reader.toss(1);
        const l = line.written();
        const t = std.mem.trim(u8, l, " ");
        if (std.mem.eql(u8, t, "<page>")) {
            in_page = true;
            page.clearRetainingCapacity();
        } else if (std.mem.eql(u8, t, "</page>")) {
            in_page = false;
            try parsePage(arena, &map, page.items);
        } else if (in_page) {
            try page.appendSlice(arena, l);
            try page.append(arena, '\n');
        }
    }
    return map;
}

fn between(s: Str, a: Str, b: Str) ?Str {
    const i = std.mem.indexOf(u8, s, a) orelse return null;
    const rest = s[i + a.len ..];
    const j = std.mem.indexOf(u8, rest, b) orelse return null;
    return rest[0..j];
}

fn parsePage(arena: Allocator, map: *WikiMap, page: Str) !void {
    if (!std.mem.eql(u8, between(page, "<ns>", "</ns>") orelse return, "0")) return;
    const title = between(page, "<title>", "</title>") orelse return;
    const text_start = std.mem.indexOf(u8, page, "<text") orelse return;
    const body = page[text_start..];
    const it_at = std.mem.indexOf(u8, body, "== {{-it-}} ==") orelse return;
    var section = body[it_at + 14 ..];
    // A seção do italiano acaba no próximo título de língua.
    if (std.mem.indexOf(u8, section, "\n== {{-")) |end| section = section[0..end];

    var related: std.ArrayList(Str) = .empty;
    var altered: std.ArrayList(Altered) = .empty;
    var confusables: std.ArrayList(Str) = .empty;
    const Kind = enum { none, rel, alter, noconf };
    var kind: Kind = .none;
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "{{-") and std.mem.indexOf(u8, l, "-}}") != null) {
            kind = if (std.mem.startsWith(u8, l, "{{-rel-}}")) .rel //
                else if (std.mem.startsWith(u8, l, "{{-alter-}}")) .alter //
                else if (std.mem.startsWith(u8, l, "{{-noconf-}}")) .noconf //
                else .none;
            continue;
        }
        if (kind == .none or !std.mem.startsWith(u8, l, "*")) continue;
        var alt_kind: Str = "";
        for (altered_kinds) |ak| if (std.mem.indexOf(u8, l, ak[0]) != null) {
            alt_kind = ak[1];
        };
        var rest = l;
        while (std.mem.indexOf(u8, rest, "[[")) |a| {
            rest = rest[a + 2 ..];
            const b = std.mem.indexOf(u8, rest, "]]") orelse break;
            var target = rest[0..b];
            rest = rest[b + 2 ..];
            if (std.mem.indexOfScalar(u8, target, '|')) |p| target = target[0..p];
            if (std.mem.indexOfScalar(u8, target, '#')) |p| target = target[0..p];
            if (target.len == 0 or std.mem.indexOfScalar(u8, target, ':') != null) continue;
            const w = try unescapeXml(arena, target);
            switch (kind) {
                .rel => try related.append(arena, w),
                .noconf => try confusables.append(arena, w),
                .alter => if (alt_kind.len > 0) try altered.append(arena, .{ .word = w, .kind = alt_kind }),
                .none => unreachable,
            }
        }
    }
    if (related.items.len + altered.items.len + confusables.items.len == 0) return;
    try map.put(arena, try unescapeXml(arena, title), .{
        .related = related.items,
        .altered = altered.items,
        .confusables = confusables.items,
    });
}

fn unescapeXml(arena: Allocator, s: Str) !Str {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return arena.dupe(u8, s);
    const ents = [_]Pair{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#039;", "'" } };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        for (ents) |e| if (std.mem.startsWith(u8, s[i..], e[0])) {
            try out.appendSlice(arena, e[1]);
            i += e[0].len;
            continue :outer;
        };
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

/// Descompressão bzip2 como `std.Io.Reader`, sobre a libbz2. O dump tem um stream só.
const Bz2Reader = struct {
    const c = @import("c");
    in: *Io.Reader,
    strm: c.bz_stream,
    buf: [1 << 18]u8,
    done: bool,
    reader: Io.Reader,

    fn init(self: *Bz2Reader, in: *Io.Reader) !void {
        self.in = in;
        self.done = false;
        self.strm = std.mem.zeroes(c.bz_stream);
        if (c.BZ2_bzDecompressInit(&self.strm, 0, 0) != c.BZ_OK) return error.Bzip2;
        self.reader = .{ .vtable = &.{ .stream = stream }, .buffer = &self.buf, .seek = 0, .end = 0 };
    }

    fn deinit(self: *Bz2Reader) void {
        _ = c.BZ2_bzDecompressEnd(&self.strm);
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Bz2Reader = @alignCast(@fieldParentPtr("reader", r));
        if (self.done) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        while (true) {
            if (self.in.bufferedLen() == 0) {
                self.in.fillMore() catch |e| switch (e) {
                    error.EndOfStream => {},
                    else => return error.ReadFailed,
                };
            }
            const avail = self.in.buffered();
            self.strm.next_in = @constCast(avail.ptr);
            self.strm.avail_in = @intCast(avail.len);
            self.strm.next_out = dest.ptr;
            self.strm.avail_out = @intCast(dest.len);
            const rc = c.BZ2_bzDecompress(&self.strm);
            self.in.toss(avail.len - self.strm.avail_in);
            const n = dest.len - self.strm.avail_out;
            if (rc == c.BZ_STREAM_END) self.done = true else if (rc != c.BZ_OK) return error.ReadFailed;
            if (n > 0) {
                w.advance(n);
                return n;
            }
            if (self.done or avail.len == 0) return error.EndOfStream;
        }
    }
};

// ---------------------------------------------------------------- etapa 4: glosa PT

const EnMap = std.StringHashMapUnmanaged([]const Str);

/// en.wiktionary: "lema\x00classe" → primeira glosa das duas primeiras acepções (só sost., verbo, agg., avv.).
fn readEnglishGlosses(io: Io, gpa: Allocator, arena: Allocator) !EnMap {
    var map: EnMap = .empty;
    const lines = try arena.create(base.GzLines);
    try lines.open(io, gpa, "data/kaikki-en-it.jsonl.gz");
    defer lines.close(io);
    const E = struct {
        word: Str = "",
        pos: Str = "",
        senses: []const struct { glosses: []const Str = &.{}, tags: []const Str = &.{} } = &.{},
    };
    var line_arena: std.heap.ArenaAllocator = .init(gpa);
    defer line_arena.deinit();
    while (try lines.next()) |line| {
        _ = line_arena.reset(.retain_capacity);
        const la = line_arena.allocator();
        const e = std.json.parseFromSliceLeaky(E, la, line, .{ .ignore_unknown_fields = true }) catch continue;
        const pos = enPos(e.pos) orelse continue;
        var gl: std.ArrayList(Str) = .empty;
        var taken: usize = 0;
        for (e.senses) |s| {
            if (taken == 2) break;
            if (has(s.tags, "form-of") or s.glosses.len == 0) continue;
            taken += 1;
            try gl.append(arena, try arena.dupe(u8, s.glosses[0]));
        }
        if (gl.items.len == 0) continue;
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ e.word, pos });
        const got = try map.getOrPut(arena, key);
        if (!got.found_existing) got.value_ptr.* = gl.items;
    }
    return map;
}

fn enPos(p: Str) ?Str {
    const m = std.StaticStringMap(Str).initComptime(.{
        .{ "noun", "sostantivo" }, .{ "verb", "verbo" }, .{ "adj", "aggettivo" }, .{ "adv", "avverbio" },
    });
    return m.get(p);
}

const Glosses = struct {
    itpt: Db,
    enpt: Db,
    q_itpt: base.Stmt,
    q_enpt: base.Stmt,
    en: EnMap,

    fn open(en: EnMap) !Glosses {
        // O WikDict não tem índice: copia para a memória e indexa por `written_rep`.
        const itpt = try Db.open(":memory:");
        try itpt.exec(
            \\ATTACH 'file:data/wikdict-it-pt.sqlite3?mode=ro' AS src;
            \\CREATE TABLE translation AS SELECT lexentry, trans_list, score, importance, written_rep FROM src.translation;
            \\CREATE INDEX t_rep ON translation(written_rep);
            \\DETACH src;
        );
        const enpt = try Db.open(":memory:");
        try enpt.exec(
            \\ATTACH 'file:data/wikdict-en-pt.sqlite3?mode=ro' AS src;
            \\CREATE TABLE translation AS SELECT lexentry, trans_list, score, importance, written_rep, is_good FROM src.translation;
            \\CREATE INDEX t_rep ON translation(written_rep);
            \\DETACH src;
        );
        return .{
            .itpt = itpt,
            .enpt = enpt,
            .q_itpt = try itpt.prepare(
                \\SELECT lexentry, trans_list FROM translation
                \\WHERE written_rep = ?1 AND (score >= 10 OR lexentry IS NULL OR lexentry = '')
                \\ORDER BY score DESC, importance DESC
            ),
            .q_enpt = try enpt.prepare(
                \\SELECT trans_list FROM translation
                \\WHERE written_rep = ?1 AND is_good = 1 AND lexentry LIKE ?2
                \\ORDER BY score DESC, importance DESC LIMIT 1
            ),
            .en = en,
        };
    }

    fn close(g: Glosses) void {
        g.q_itpt.finalize();
        g.q_enpt.finalize();
        g.itpt.close();
        g.enpt.close();
    }

    /// Até 3 traduções em `out` e a origem. `classes`: quantas classes o lema tem no dicionário.
    fn find(g: Glosses, a: Allocator, e: KEntry, pos: Str, classes: usize, out: *std.ArrayList(Str)) !Str {
        // 1. translations[] do próprio verbete
        for (e.translations) |t| if (std.mem.eql(u8, t.lang_code, "pt")) try addGloss(a, out, t.word);
        if (out.items.len > 0) return "wikt";

        // 2. WikDict it-pt. Linha sem classe (só a reversa do pt.wiktionary) só para lema de uma classe.
        const wd = wikdictPos(pos);
        g.q_itpt.text(1, e.word);
        while (try g.q_itpt.step()) {
            const lex = g.q_itpt.colText(0);
            if (lex.len == 0) {
                if (classes != 1) continue;
            } else if (wd.len == 0 or std.mem.indexOf(u8, lex, wd) == null) continue;
            var parts = std.mem.splitSequence(u8, g.q_itpt.colText(1), " | ");
            while (parts.next()) |p| try addGloss(a, out, p);
        }
        g.q_itpt.reset();
        if (out.items.len > 0) return "wikdict";

        // 3. pivô en.wiktionary → WikDict en-pt
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ e.word, pos }) catch return "";
        const en = g.en.get(key) orelse return "";
        const like = enLexLike(pos);
        for (en) |gloss| {
            var cut = gloss;
            if (std.mem.indexOfScalar(u8, cut, '(')) |p| cut = cut[0..p];
            // A glosa inteira e depois cada parte por vírgula ou ponto e vírgula.
            if (try pivot(g, a, cut, pos, like, out)) return "pivo-en";
            var parts = std.mem.tokenizeAny(u8, cut, ",;");
            while (parts.next()) |p| if (try pivot(g, a, p, pos, like, out)) return "pivo-en";
        }
        return "";
    }

    fn pivot(g: Glosses, a: Allocator, raw: Str, pos: Str, like: Str, out: *std.ArrayList(Str)) !bool {
        var w = std.mem.trim(u8, raw, " .");
        if (std.mem.eql(u8, pos, "verbo") and std.mem.startsWith(u8, w, "to ")) w = w[3..];
        if (std.mem.eql(u8, pos, "sostantivo")) {
            for ([_]Str{ "a ", "an ", "the " }) |art| if (std.mem.startsWith(u8, w, art)) {
                w = w[art.len..];
            };
        }
        if (w.len == 0) return false;
        g.q_enpt.text(1, w);
        g.q_enpt.text(2, like);
        defer g.q_enpt.reset();
        if (!try g.q_enpt.step()) return false;
        var parts = std.mem.splitSequence(u8, g.q_enpt.colText(0), " | ");
        if (parts.next()) |p| try addGloss(a, out, p);
        return out.items.len > 0;
    }
};

fn addGloss(a: Allocator, out: *std.ArrayList(Str), raw: Str) !void {
    const w = std.mem.trim(u8, raw, " ");
    if (w.len == 0 or out.items.len >= 3) return;
    for (out.items) |x| if (std.mem.eql(u8, x, w)) return;
    try out.append(a, try a.dupe(u8, w));
}

fn wikdictPos(pos: Str) Str {
    if (std.mem.eql(u8, pos, "sostantivo")) return "__sost__";
    if (std.mem.eql(u8, pos, "verbo")) return "__verb__";
    if (std.mem.eql(u8, pos, "aggettivo")) return "__agg__";
    if (std.mem.eql(u8, pos, "avverbio")) return "__avv__";
    return "";
}

fn enLexLike(pos: Str) Str {
    if (std.mem.eql(u8, pos, "sostantivo")) return "%__Noun__%";
    if (std.mem.eql(u8, pos, "verbo")) return "%__Verb__%";
    if (std.mem.eql(u8, pos, "aggettivo")) return "%__Adjective__%";
    return "%__Adverb__%";
}

// ---------------------------------------------------------------- NVdB e correções

/// "lema\x00classe" → faixa (1 fondamentale · 2 alto uso · 3 alta disponibilità).
/// A classe sai das abreviações da lista (`s.m.`, `v.tr.`, `agg.`…); "lema\x00" vale para
/// qualquer classe quando nenhuma bate.
const Nvdb = std.StringHashMapUnmanaged(u8);

fn readNvdb(io: Io, arena: Allocator) !Nvdb {
    var map: Nvdb = .empty;
    const text = try Io.Dir.cwd().readFileAlloc(io, "nvdb.tsv", arena, .unlimited);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var cols = std.mem.splitScalar(u8, l, '\t');
        const word = cols.next() orelse continue;
        _ = cols.next(); // homógrafo
        const labels_col = cols.next() orelse continue;
        const band = std.fmt.parseInt(u8, cols.next() orelse continue, 10) catch continue;
        try putBand(arena, &map, word, "", band);
        var it = std.mem.tokenizeScalar(u8, labels_col, ' ');
        while (it.next()) |lab| if (nvdbPos(lab)) |pos| try putBand(arena, &map, word, pos, band);
    }
    return map;
}

fn putBand(arena: Allocator, map: *Nvdb, word: Str, pos: Str, band: u8) !void {
    const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ word, pos });
    const got = try map.getOrPut(arena, key);
    if (!got.found_existing or band < got.value_ptr.*) got.value_ptr.* = band;
}

fn nvdbPos(lab: Str) ?Str {
    const pre = [_]Pair{
        .{ "s.", "sostantivo" },    .{ "v.", "verbo" },           .{ "agg", "aggettivo" },
        .{ "avv", "avverbio" },     .{ "prep", "preposizione" },  .{ "cong", "congiunzione" },
        .{ "pron", "pronome" },     .{ "inter", "interiezione" }, .{ "art", "articolo" },
        .{ "p.pass", "aggettivo" }, .{ "p.pres", "aggettivo" },
    };
    for (pre) |p| if (std.mem.startsWith(u8, lab, p[0])) return p[1];
    return null;
}

fn bandOf(nvdb: Nvdb, buf: []u8, word: Str, pos: Str) u8 {
    const k1 = std.fmt.bufPrint(buf, "{s}\x00{s}", .{ word, pos }) catch return 0;
    if (nvdb.get(k1)) |b| return b;
    const k2 = std.fmt.bufPrint(buf, "{s}\x00", .{word}) catch return 0;
    return nvdb.get(k2) orelse 0;
}

/// corrections.tsv: lema, classe, campo, valor. Campo `gloss`: traduções separadas por " | ".
const Corrections = std.StringHashMapUnmanaged(Str);

fn readCorrections(io: Io, arena: Allocator) !Corrections {
    var map: Corrections = .empty;
    const text = Io.Dir.cwd().readFileAlloc(io, "corrections.tsv", arena, .unlimited) catch return map;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len == 0 or l[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, l, '\t');
        const word = cols.next() orelse continue;
        const pos = cols.next() orelse continue;
        const field = cols.next() orelse continue;
        const value = cols.next() orelse continue;
        try map.put(arena, try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}", .{ word, pos, field }), value);
    }
    return map;
}

// ---------------------------------------------------------------- etapas 2, 5 e 6: verbetes e formas

const FormRow = struct { form: Str, lemma: Str, pos: Str };

fn readEntries(io: Io, gpa: Allocator, db: Db, wiki: WikiMap, glosses: Glosses, nvdb: Nvdb, corrections: Corrections) !void {
    var keep_state: std.heap.ArenaAllocator = .init(gpa);
    defer keep_state.deinit();
    const keep = keep_state.allocator();
    var la_state: std.heap.ArenaAllocator = .init(gpa);
    defer la_state.deinit();
    const lines = try keep.create(base.GzLines);

    // 1ª passada: quantas classes cada lema tem (filtro das linhas sem classe do WikDict).
    var classes: std.StringHashMapUnmanaged(u8) = .empty;
    try lines.open(io, gpa, "data/kaikki-it.jsonl.gz");
    while (try lines.next()) |line| {
        _ = la_state.reset(.retain_capacity);
        const e = std.json.parseFromSliceLeaky(KEntry, la_state.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
        if (!isLemma(e) or pos_names.get(e.pos) == null) continue;
        const got = try classes.getOrPut(keep, e.word);
        if (!got.found_existing) {
            got.key_ptr.* = try keep.dupe(u8, e.word);
            got.value_ptr.* = 0;
        }
        got.value_ptr.* += 1;
    }
    lines.close(io);

    const ins_entry = try db.prepare("INSERT INTO entry (id, word, word_norm, pos, band, data) VALUES (?1, ?2, ?3, ?4, ?5, ?6)");
    defer ins_entry.finalize();
    var forms: std.ArrayList(FormRow) = .empty;
    // "lema\x00classe" → id, e "lema" → primeiro id, para resolver as formas.
    var ids: std.StringHashMapUnmanaged(i64) = .empty;
    var json: Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    var report = Report{};
    var next_id: i64 = 1;
    var norm_buf: [1024]u8 = undefined;
    var key_buf: [1024]u8 = undefined;

    try lines.open(io, gpa, "data/kaikki-it.jsonl.gz");
    defer lines.close(io);
    try db.exec("BEGIN");
    while (try lines.next()) |line| {
        _ = la_state.reset(.retain_capacity);
        const a = la_state.allocator();
        const e = std.json.parseFromSliceLeaky(KEntry, a, line, .{ .ignore_unknown_fields = true }) catch {
            report.bad_json += 1;
            continue;
        };
        // Sentidos form_of alimentam `form`, mesmo numa entrada que também é lema.
        for (e.senses) |s| for (s.form_of) |f| {
            try forms.append(keep, .{ .form = try keep.dupe(u8, e.word), .lemma = try keep.dupe(u8, f.word), .pos = pos_names.get(e.pos) orelse "" });
        };
        if (!isLemma(e)) continue;
        const pos = pos_names.get(e.pos) orelse {
            report.skipped_pos += 1;
            continue;
        };

        var data = try toData(a, e, pos, wiki, &report);
        var gl: std.ArrayList(Str) = .empty;
        const corr_key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}\x00gloss", .{ e.word, pos }) catch "";
        if (corrections.get(corr_key)) |v| {
            var parts = std.mem.splitSequence(u8, v, " | ");
            while (parts.next()) |p| try addGloss(a, &gl, p);
            data.gloss_src = "correzione";
        } else {
            const src = try glosses.find(a, e, pos, classes.get(e.word) orelse 1, &gl);
            data.gloss_src = if (src.len > 0) src else null;
        }
        data.gloss = orNull(Str, gl.items);
        if (data.gloss != null) report.with_gloss += 1;

        // Formas da Flessione e da Coniugazione (inclusive com clítico) também levam ao lema.
        if (data.flex) |fl| for (fl) |f| try forms.append(keep, .{ .form = try keep.dupe(u8, f.form), .lemma = try keep.dupe(u8, e.word), .pos = pos });
        if (data.conj) |cj| for (cj) |cc| for (cc.forms) |f| {
            try forms.append(keep, .{ .form = try keep.dupe(u8, f), .lemma = try keep.dupe(u8, e.word), .pos = pos });
        };
        if (data.participle) |f| try forms.append(keep, .{ .form = try keep.dupe(u8, f), .lemma = try keep.dupe(u8, e.word), .pos = pos });
        if (data.gerund) |f| try forms.append(keep, .{ .form = try keep.dupe(u8, f), .lemma = try keep.dupe(u8, e.word), .pos = pos });

        json.clearRetainingCapacity();
        try std.json.Stringify.value(data, .{ .emit_null_optional_fields = false }, &json.writer);

        const id = next_id;
        next_id += 1;
        ins_entry.int(1, id);
        ins_entry.text(2, e.word);
        ins_entry.text(3, base.normalize(&norm_buf, e.word));
        ins_entry.text(4, pos);
        ins_entry.int(5, bandOf(nvdb, &key_buf, e.word, pos));
        ins_entry.text(6, json.written());
        try ins_entry.run();

        try ids.put(keep, try std.fmt.allocPrint(keep, "{s}\x00{s}", .{ e.word, pos }), id);
        const kw = try keep.dupe(u8, e.word);
        if (!ids.contains(kw)) try ids.put(keep, kw, id);
        report.entries += 1;
    }

    const ins_form = try db.prepare("INSERT INTO form (form, form_norm, entry_id) VALUES (?1, ?2, ?3)");
    defer ins_form.finalize();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (forms.items) |f| {
        const k = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ f.lemma, f.pos }) catch continue;
        const id = ids.get(k) orelse ids.get(f.lemma) orelse {
            report.forms_without_lemma += 1;
            continue;
        };
        const dedup = try std.fmt.allocPrint(keep, "{s}\x00{d}", .{ f.form, id });
        if ((try seen.getOrPut(keep, dedup)).found_existing) continue;
        ins_form.text(1, f.form);
        ins_form.text(2, base.normalize(&norm_buf, f.form));
        ins_form.int(3, id);
        try ins_form.run();
        report.forms += 1;
    }
    try db.exec("COMMIT");
    report.print();
}

const Report = struct {
    entries: usize = 0,
    forms: usize = 0,
    with_gloss: usize = 0,
    bad_json: usize = 0,
    skipped_pos: usize = 0,
    forms_without_lemma: usize = 0,
    unmapped_labels: usize = 0,

    fn print(r: Report) void {
        std.debug.print(
            \\  verbetes {d} (com glosa PT {d})
            \\  formas {d} (sem lema {d})
            \\  JSON inválido {d} · classe fora da tabela {d} · rótulos sem mapeamento {d}
            \\
        , .{ r.entries, r.with_gloss, r.forms, r.forms_without_lemma, r.bad_json, r.skipped_pos, r.unmapped_labels });
    }
};

/// Lema: tem ao menos um sentido que não é só forma de outro.
fn isLemma(e: KEntry) bool {
    for (e.senses) |s| if (s.form_of.len == 0 and s.alt_of.len == 0 and !has(s.tags, "form-of")) return true;
    return false;
}

fn toData(a: Allocator, e: KEntry, pos: Str, wiki: WikiMap, report: *Report) !Data {
    var tags: std.ArrayList(Str) = .empty;
    for (e.tags) |t| if (entry_tags.get(t)) |v| try tags.append(a, v);

    var valency: ?Str = null;
    if (std.mem.eql(u8, pos, "verbo")) {
        outer: for (valency_cats) |vc| for (e.categories) |cat| if (std.mem.eql(u8, cat.name, vc[0])) {
            valency = vc[1];
            break :outer;
        };
    }

    var flex: std.ArrayList(Flex) = .empty;
    var conj: std.ArrayList(Conj) = .empty;
    var aux: ?Str = null;
    var participle: ?Str = null;
    var gerund: ?Str = null;
    for (e.forms) |f| {
        if (f.source.len == 0) {
            // Flessione: plurale, femminile…
            var ft: std.ArrayList(u8) = .empty;
            for ([_]Pair{ .{ "feminine", "femminile" }, .{ "masculine", "maschile" }, .{ "plural", "plurale" }, .{ "singular", "singolare" } }) |p|
                if (has(f.tags, p[0])) {
                    if (ft.items.len > 0) try ft.append(a, ' ');
                    try ft.appendSlice(a, p[1]);
                };
            if (ft.items.len > 0 and !std.mem.eql(u8, f.form, e.word)) try flex.append(a, .{ .form = f.form, .tags = ft.items });
            continue;
        }
        if (!std.mem.startsWith(u8, f.source, "Appendice:Coniugazioni")) continue;
        if (has(f.tags, "auxiliary")) {
            aux = f.form;
            continue;
        }
        if (has(f.tags, "gerund")) {
            gerund = gerund orelse f.form;
            continue;
        }
        if (has(f.tags, "participle")) {
            if (has(f.tags, "past")) participle = participle orelse f.form;
            continue;
        }
        const tense = tenseOf(f.tags) orelse continue;
        const person: u8 = if (tense == 5)
            (if (f.raw_tags.len > 0) imper_person.get(f.raw_tags[0]) orelse 0 else 0)
        else
            personOf(f.tags);
        if (person == 0) continue;
        try addConj(a, &conj, tense, person, f.form);
    }

    var senses: std.ArrayList(Sense) = .empty;
    for (e.senses) |s| {
        if (s.form_of.len > 0 or s.alt_of.len > 0 or has(s.tags, "no-gloss") or has(s.tags, "form-of") or s.glosses.len == 0) continue;
        var empty = false;
        for (s.categories) |cat| if (std.mem.startsWith(u8, cat.name, "Pagine senza definizione")) {
            empty = true;
        };
        if (empty) continue;
        var labs: std.ArrayList(Str) = .empty;
        for ([_][]const Str{ s.tags, s.raw_tags, s.topics }) |list| for (list) |t| {
            if (labels.get(std.mem.trim(u8, t, " "))) |abbr| {
                if (!has(labs.items, abbr)) try labs.append(a, abbr);
            } else report.unmapped_labels += 1;
        };
        var ex: std.ArrayList(Str) = .empty;
        for (s.examples) |x| if (x.text.len > 0) try ex.append(a, x.text);
        try senses.append(a, .{
            .gloss = s.glosses[s.glosses.len - 1],
            .labels = orNull(Str, labs.items),
            .examples = orNull(Str, ex.items),
        });
    }

    var syll: []const Str = &.{};
    if (e.hyphenations.len > 0) syll = e.hyphenations[0].parts;
    var ipa: ?Str = null;
    for (e.sounds) |s| if (s.ipa.len > 0) {
        ipa = s.ipa;
        break;
    };

    const w = wiki.get(e.word);
    return .{
        .word = e.word,
        .pos = pos,
        .tags = orNull(Str, tags.items),
        .valency = valency,
        .aux = aux,
        .flex = orNull(Flex, flex.items),
        .syll = orNull(Str, syll),
        .ipa = ipa,
        .senses = senses.items,
        .conj = orNull(Conj, conj.items),
        .participle = participle,
        .gerund = gerund,
        .etym = if (e.etymology_texts.len > 0) e.etymology_texts[0] else null,
        .syn = orNull(Link, try links(a, e.synonyms)),
        .ant = orNull(Link, try links(a, e.antonyms)),
        .derived = orNull(Link, try links(a, e.derived)),
        .related = if (w) |x| orNull(Str, x.related) else null,
        .altered = if (w) |x| orNull(Altered, x.altered) else null,
        .confusables = if (w) |x| orNull(Str, x.confusables) else null,
    };
}

/// tense: 1 presente · 2 passato prossimo · 3 imperfetto · 4 futuro · 5 imperativo.
/// Condizionale e congiuntivo vêm sem pessoa nas tags e ficam de fora (DIC-05).
fn tenseOf(tags: []const Str) ?u8 {
    if (has(tags, "imperative")) return 5;
    if (personOf(tags) == 0) return null;
    if (has(tags, "pluperfect") or has(tags, "historic") or has(tags, "past-remote")) return null;
    if (has(tags, "future")) return if (has(tags, "perfect")) null else 4;
    if (has(tags, "past") and has(tags, "perfect")) return 2;
    if (has(tags, "imperfect")) return 3;
    if (has(tags, "present")) return 1;
    return null;
}

fn personOf(tags: []const Str) u8 {
    const n: u8 = if (has(tags, "first-person")) 1 else if (has(tags, "second-person")) 2 else if (has(tags, "third-person")) 3 else return 0;
    if (has(tags, "plural")) return n + 3;
    if (has(tags, "singular")) return n;
    return 0;
}

fn addConj(a: Allocator, conj: *std.ArrayList(Conj), tense: u8, person: u8, form: Str) !void {
    for (conj.items) |*cc| if (cc.tense == tense and cc.person == person) {
        if (has(cc.forms, form)) return;
        const more = try a.alloc(Str, cc.forms.len + 1);
        @memcpy(more[0..cc.forms.len], cc.forms);
        more[cc.forms.len] = form;
        cc.forms = more;
        return;
    };
    const one = try a.alloc(Str, 1);
    one[0] = form;
    try conj.append(a, .{ .tense = tense, .person = person, .forms = one });
}

/// Sinonimi, Contrari, Parole derivate: a palavra e a nota entre parênteses ("oblò (fig.)").
fn links(a: Allocator, in: []const KLink) ![]const Link {
    var out: std.ArrayList(Link) = .empty;
    for (in) |l| {
        if (l.word.len == 0) continue;
        var note: ?Str = null;
        for ([_][]const Str{ l.tags, l.raw_tags }) |list| for (list) |t| {
            if (note == null) note = labels.get(t) orelse t;
        };
        try out.append(a, .{ .word = l.word, .note = note });
    }
    return out.items;
}

// ---------------------------------------------------------------- meta

fn writeMeta(io: Io, db: Db, arena: Allocator) !void {
    const ins = try db.prepare("INSERT INTO meta (key, value) VALUES (?1, ?2)");
    defer ins.finalize();
    const rows = [_]Pair{
        .{ "version", version },
        .{ "wiktionary_dump", "2026-10-01" },
        .{ "license", "CC BY-SA 4.0" },
        .{ "attribution", "Wikizionario (it.wiktionary), Wiktionary (en), WikDict/DBnary, wiktextract (kaikki.org), NVdB (De Mauro, 2016)" },
    };
    for (rows) |r| {
        ins.text(1, r[0]);
        ins.text(2, r[1]);
        try ins.run();
    }
    // URL e sha256 de cada fonte (etapa 1).
    for (base.sources) |s| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "data/{s}", .{s.file});
        const sum = try base.sha256File(io, path);
        ins.text(1, try std.fmt.allocPrint(arena, "source.{s}", .{s.file}));
        ins.text(2, try std.fmt.allocPrint(arena, "{s} sha256:{s}", .{ s.url, &sum }));
        try ins.run();
    }
    const nvdb_sum = try base.sha256File(io, "nvdb.tsv");
    ins.text(1, "source.nvdb.tsv");
    ins.text(2, try std.fmt.allocPrint(arena, "Internazionale 2016-12-23, PDF sha256:eef743fbc8a71d5588f6aa746501e7b5bfba624c5ce4c0c01a6f6bdd83ed5d44, tsv sha256:{s}", .{&nvdb_sum}));
    try ins.run();
}

test "tempos e pessoas da conjugação" {
    try std.testing.expectEqual(@as(?u8, 1), tenseOf(&.{ "first-person", "present", "singular" }));
    try std.testing.expectEqual(@as(?u8, 2), tenseOf(&.{ "past", "perfect", "plural", "third-person" }));
    try std.testing.expectEqual(@as(?u8, null), tenseOf(&.{ "past", "perfect", "pluperfect", "plural", "third-person" }));
    try std.testing.expectEqual(@as(?u8, 4), tenseOf(&.{ "future", "second-person", "singular" }));
    try std.testing.expectEqual(@as(?u8, null), tenseOf(&.{"present"})); // condizionale
    try std.testing.expectEqual(@as(?u8, 5), tenseOf(&.{"imperative"}));
}

test "seção italiana do wikitext" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var map: WikiMap = .empty;
    try parsePage(a, &map,
        \\<title>casa</title>
        \\<ns>0</ns>
        \\<text bytes="1">== {{-it-}} ==
        \\{{-alter-}}
        \\* {{Dim}} [[casina]]
        \\* {{Vezz}} [[casetta]]
        \\{{-rel-}}
        \\* ''(sostantivo)'' [[soglia]], [[w:Soglia|x]], [[stipite]]
        \\{{-noconf-}}
        \\* [[cassa]]
        \\== {{-es-}} ==
        \\{{-rel-}}
        \\* [[hogar]]
    );
    const w = map.get("casa").?;
    try std.testing.expectEqual(2, w.altered.len);
    try std.testing.expectEqualStrings("vezzeggiativo", w.altered[1].kind);
    try std.testing.expectEqual(2, w.related.len);
    try std.testing.expectEqualStrings("cassa", w.confusables[0]);
}
