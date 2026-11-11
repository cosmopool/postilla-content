# Contrato dos pacotes

O que o app Postilla lê dos bancos gerados aqui (ARQ-07). Mudança incompatível neste arquivo sobe o major do pacote (ARQ-12).

```
zig build run -- fetch     baixa as fontes em data/
zig build run -- dict      out/dict.db
zig build run -- stories   out/stories.db
zig build run -- pack [p]  out/<pacote>-<versão>.db.gz e out/SHA256SUMS (só o pacote p, se dado)
zig build test
```

## Pacotes

| Arquivo | O que é |
|---|---|
| `dict-1.0.0.db.gz` | Dicionário, gzip -9 (v1; zstd volta com as Releases) |
| `stories-1.0.0.db.gz` | Histórias e traduções, gzip -9 |
| `SHA256SUMS` | sha256 do `.db` e do `.db.gz` de cada pacote |

A versão de cada pacote está em `meta.version` e no nome do arquivo.

## Releases e manifesto

Uma tag por pacote e versão: `dict-v1.1.0`, `stories-v1.2.0`. A versão da tag é a de `version` em `src/<pacote>.zig`, senão o workflow `release` falha. Cada Release leva `<pacote>-<versão>.db.gz`, `SHA256SUMS` e `<pacote>-<versão>.json` (a entrada do manifesto).

O manifesto (ARQ-06, ARQ-20) fica em `https://postilla.kaiodelphino.com/content/manifest.json`, no Pages deste repositório. A cada Release ele é refeito com a maior versão publicada de cada pacote. Pacote sem Release não aparece.

```json
{
  "packages": {
    "dict": {
      "version": "1.0.0",
      "url": "https://github.com/cosmopool/postilla-content/releases/download/dict-v1.0.0/dict-1.0.0.db.gz",
      "size": 22829235,
      "gz_sha256": "…",
      "db_sha256": "…",
      "db_size": 88629248
    },
    "stories": { "…": "…" }
  }
}
```

`size` e `gz_sha256` são do `.db.gz` baixado; `db_sha256` e `db_size`, do `.db` descomprimido.

## `dict`

```sql
CREATE TABLE meta  (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE entry (id INTEGER PRIMARY KEY, word TEXT NOT NULL, word_norm TEXT NOT NULL,
                    pos TEXT NOT NULL, band INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE form  (form TEXT NOT NULL, form_norm TEXT NOT NULL, entry_id INTEGER NOT NULL);
-- índices: entry(word), entry(word_norm), form(form), form(form_norm)
```

- `entry`: uma linha por lema e classe. `word` com a grafia original; `word_norm` minúscula e sem acento (ARQ-63).
- `pos`: a classe em italiano (`sostantivo`, `verbo`, `aggettivo`, `avverbio`, `nome proprio`, `locuzione`…).
- `band`: faixa do NVdB (ARQ-64): 0 fora · 1 fondamentale · 2 alto uso · 3 alta disponibilità. Não há rank dentro da faixa: o NVdB só publica as faixas.
- `form`: forma → lema, inclusive as das tabelas de conjugação com clítico ("si siede" → *sedersi*), o particípio e o gerúndio. Uma forma pode levar a mais de um lema ("porta" → *portare*, *porgere*).
- `entry.id` muda a cada build: o app nunca o guarda (ARQ-35).
- `meta`: `version`, `wiktionary_dump` (data do dump, AAAA-MM-DD), `license`, `attribution` e uma linha `source.<arquivo>` por fonte, com URL e sha256.

`entry.data` é JSON. Campo sem dado não aparece.

| Campo | Tipo | Seção do verbete |
|---|---|---|
| `word`, `pos` | texto | Lemma e Classe |
| `tags` | lista: `maschile`, `femminile`, `invariabile` | Classe |
| `valency` | `transitivo` · `intransitivo` · `intransitivo pronominale` · `riflessivo` | Classe (verbo) |
| `aux` | `avere` · `essere` | Classe (verbo) |
| `flex` | lista de `{form, tags}`; `tags` como "plurale", "femminile singolare" | Flessione |
| `syll` | lista de sílabas, com o acento tônico | Sillabazione |
| `ipa` | texto | Pronuncia |
| `gloss` | até 3 traduções em português | Glosa PT |
| `gloss_src` | `wikt` · `wikdict` · `pivo-en` · `correzione` | (crédito) |
| `senses` | lista de `{gloss, labels?, examples?}`; `labels` são abreviações (`fig.`, `med.`) | Significati |
| `conj` | lista de `{tense, person, forms}`; `tense` 1 presente · 2 passato prossimo · 3 imperfetto · 4 futuro · 5 imperativo; `person` 1 io … 6 loro; no imperativo, `forms` de `person` 2 inclui o negativo ("non parlare") | Coniugazione |
| `participle`, `gerund` | texto | Coniugazione |
| `etym` | texto | Etimologia |
| `syn`, `ant`, `derived` | lista de `{word, note?}` | Sinonimi, Contrari, Parole derivate |
| `related`, `confusables` | lista de palavras | Termini correlati, Da non confondere con |
| `altered` | lista de `{word, kind}`; `kind` `diminutivo` · `accrescitivo` · `vezzeggiativo` · `peggiorativo` | Alterati |

## `stories`

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE genre (id TEXT PRIMARY KEY, name_pt TEXT NOT NULL, name_it TEXT NOT NULL);
CREATE TABLE story (id TEXT PRIMARY KEY, title TEXT NOT NULL, subtitle TEXT NOT NULL,
  level INTEGER NOT NULL, genre TEXT NOT NULL, work TEXT NOT NULL, part INTEGER NOT NULL,
  words INTEGER NOT NULL, minutes INTEGER NOT NULL);
CREATE TABLE paragraph (story_id TEXT NOT NULL, pos INTEGER NOT NULL,
  it TEXT NOT NULL, pt TEXT NOT NULL, words INTEGER NOT NULL,
  it_words BLOB NOT NULL, it_sents BLOB NOT NULL, pt_sents BLOB NOT NULL,
  PRIMARY KEY (story_id, pos)) WITHOUT ROWID;
```

- `story.id`: UUID fixo, escrito na fonte (ARQ-36). `level`: 1 A1 · 2 A2 · 3 B1 · 4 B2.
- `work` e `part`: obra dividida ("Pinocchio", 1). Fora de obra: `''` e 0 (LEI-10).
- `minutes`: palavras ÷ velocidade do nível (A1 60, A2 80, B1 100, B2 120 palavras/min), para cima.
- `paragraph.pos`: posição do parágrafo, a partir de 0.
- Spans (ARQ-50): pares `(início, fim)` em u16 little-endian, 4 bytes por par, em **unidades UTF-16** do texto do parágrafo (como o Dart indexa uma `String`). `it_words`: palavras em italiano; `it_sents` e `pt_sents`: frases, alinhadas 1:1 (TRA-08). Não há spans de palavra em português: nada no app toca palavra em português (TRA-04).
- Palavra: letras e dígitos; o apóstrofo e o hífen entre letras unem (*l'aria*, *c'è*, *porta-finestra*); o apóstrofo final fica nos truncamentos (*po'*, *va'*). Pontuação nunca é palavra. `words` conta essas palavras.

## Formato-fonte das histórias

`stories/<slug>.txt`:

```
uuid: d0159518-99cc-46f0-bef2-b5b6f6f9a76d
title: Il treno per Bologna
subtitle: Marta va a trovare la nonna dopo due anni.
level: A2
genre: viaggio
work: Pinocchio        (opcional, junto com part)
part: 1

Frase em italiano.
Outra frase.
--
Frase em português.
Outra frase.

(próximo parágrafo)
```

Uma frase por linha; o número de linhas em italiano e em português de cada parágrafo é igual, senão o build falha. `stories/genres.txt`: `id | nome PT | nome IT`.

## Arquivos-fonte escritos à mão

| Arquivo | O que é |
|---|---|
| `nvdb.tsv` | NVdB (De Mauro, 2016): lema, homógrafo, classes, faixa. Extraído uma vez do PDF da Internazionale por `tools/nvdb_extract.py` (faixa pela fonte: negrito, normal, itálico) |
| `corrections.tsv` | lema, classe, campo, valor. Campo `gloss`: traduções separadas por ` \| ` |
