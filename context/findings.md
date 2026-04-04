# Translation Notebook Findings

## Summary

We are building a simplified Fabric learning repo that loads a Japanese education CSV
(MEXT data, ~890 rows, 15 columns) into a Delta table (`mext.教育コンテンツ`) and then
uses Fabric AI functions (`df.ai.translate`) to create an English version (`mext.education_content`).

The **Load notebook works** and has been tested end-to-end via the deploy script.
The **Translate notebook does NOT yet work** when submitted as a REST API batch job.

---

## The Core Problem: REST API vs Interactive Execution

The user has a **working notebook** (`TranslateToJapanese.ipynb`) in another project
that successfully chains **12 `ai.translate()` calls** followed by column renames,
`display()`, and `write.saveAsTable()`. That notebook was run **interactively in the
Fabric UI**.

All of our translation attempts submitted via the **Fabric REST API** (`RunNotebook`
job type) fail with "Job instance failed without detail error" in ~30–60 seconds.

### What the Working Notebook Does (TranslateToJapanese.ipynb)

```
Cell 0: (empty welcome cell)
Cell 1: df = spark.sql("SELECT * FROM ..."); display(df)
Cell 2: %pip install -q --force-reinstall openai==1.99.5 2>/dev/null
Cell 3: import synapse.ml.spark.aifunc as aifunc
Cell 4: single translate + display (test)
Cell 5: 3 chained translates + display (test)
Cell 6: 12 chained translates + display
Cell 7: rename numeric columns with .withColumn()
Cell 8: write to staging table
Cell 9: check staging table
Cell 10: SQL SELECT clean columns from staging
Cell 11: write final table (English name)
Cell 12: write final table (Japanese name)
```

Key pattern: **translate → display → rename → write to staging → SQL select clean cols → write final**

### What Fails via REST API

Every translate notebook submitted via REST API fails, including:
- 9 chained translates with `display()` + staging + SQL select + write
- Single translate + `.collect()` (even on 5 rows)
- Single translate + `.drop()` + write
- Single translate + `.select()` + write
- Multi-cell: translate+write in cell 1, read-back+select in cell 2

### What Works via REST API

- **≤5 chained `ai.translate()` → direct `.write.saveAsTable()`** (no select/drop/collect between)
- This has been tested and confirmed multiple times

### Hypothesis

The `RunNotebook` REST API job type may compile all cells into a single Spark plan,
which fails when the plan is too complex (many AI translate + reshaping operations).
Interactive execution runs cells independently with separate Spark plans per cell.

---

## Key Discoveries

### 1. pip install openai IS used in the working notebook

The working `TranslateToJapanese.ipynb` includes `%pip install -q --force-reinstall openai==1.99.5`.
The official docs say PySpark AI functions don't need it, but the working notebook has it.
Include it to match the proven pattern.

### 2. AI functions fail with Japanese column names

`df.ai.translate()` fails when the `input_col` references a column with Japanese characters.
**Alias all Japanese column names to ASCII before translating.**

### 3. After `ai.translate()`, ONLY direct `.write.saveAsTable()` works via REST API

These all fail after `ai.translate()` when run via REST API:
- `.select()` ❌
- `.drop()` ❌
- `.collect()` ❌
- `.show()` / `display()` ❌ (in batch mode)

Only `.write.mode('overwrite').format('delta').saveAsTable()` directly on the translated
DataFrame works.

### 4. ≤5 chained ai.translate calls work via REST API

Confirmed: 5 chained translates + direct write succeeds. We need 9 translates total.

### 5. Columns that do NOT need translation

Six columns can be renamed only (no AI translation):

- **Col 1** `教材_ID` → `material_id` — Alphanumeric code
- **Col 3** `教材_言語` → `material_language` — Already in English
- **Col 4** `教材_キーワード` → `material_keywords` — Empty/NULL values
- **Col 8** `教材_分野_科目` → `material_field` — Empty/NULL values
- **Col 11** `教材_ＵＲＬ` → `material_url` — URLs (English)
- **Col 13** `教材_ライセンス` → `material_license` — Already in English

Nine columns need translation:
- material_name, material_format, material_target_audience, material_subject,
  material_target_grade, material_content_type, material_price_category,
  material_status, material_publisher

---

## Column Mapping (15 columns)

| # | Japanese Column | English Name | Action |
|---|---|---|---|
| 1 | 教材_ID | material_id | Rename only (alphanumeric code) |
| 2 | 教材_名称 | material_name | **Translate** |
| 3 | 教材_言語 | material_language | Rename only (already English) |
| 4 | 教材_キーワード | material_keywords | Rename only (empty/null) |
| 5 | 教材_形式 | material_format | **Translate** |
| 6 | 教材_対象者 | material_target_audience | **Translate** |
| 7 | 教材_教科等 | material_subject | **Translate** |
| 8 | 教材_分野_科目 | material_field | Rename only (empty/null) |
| 9 | 教材_対象学年 | material_target_grade | **Translate** |
| 10 | 教材_コンテンツ形式 | material_content_type | **Translate** |
| 11 | 教材_ＵＲＬ | material_url | Rename only (URLs) |
| 12 | 教材_価格_区分 | material_price_category | **Translate** |
| 13 | 教材_ライセンス | material_license | Rename only (already English) |
| 14 | 教材_状態 | material_status | **Translate** |
| 15 | 教材_公開者 | material_publisher | **Translate** |

---

## Other Critical Findings (from Load Notebook work)

### CSV Reading in Fabric
- `spark.read.csv()` DataFrames **fail to write to Delta tables** in Fabric
- **Solution**: Use Python `csv.reader` + `spark.createDataFrame()` instead
- Original CSV is Shift-JIS (cp932), has trailing empty columns and embedded newlines

### Japanese Table Names in Fabric
- Japanese Delta table names require backtick quoting: `mext.\`教育コンテンツ\``
- `option('overwriteSchema', 'true')` needed when overwriting with a different schema

### Notebook Deployment via REST API
- Create: `POST /v1/workspaces/{WS_ID}/items` with `type: "Notebook"`
- Update: `POST /v1/workspaces/{WS_ID}/notebooks/{NB_ID}/updateDefinition`
- `.platform` part needs `"type": "SparkNotebook"` (not "Notebook")
- Lakehouse binding goes in notebook metadata `dependencies`

---

## Current TranslateMextToEnglish.ipynb (local, needs testing)

The notebook on disk follows the working `TranslateToJapanese.ipynb` pattern:

```
Cell 0: %pip install openai
Cell 1: import aifunc
Cell 2: SQL SELECT with all columns renamed to English + display
Cell 3: Chain 9 ai.translate calls + display
Cell 4: Write all columns (originals + _en translations) to staging table
Cell 5: SQL SELECT only the clean columns (using _en instead of originals) + display
Cell 6: Write final table + drop staging
```

This has NOT been tested yet. It may fail via REST API but should work interactively.

---

## Options to Complete the Translation

### Option A: Run translate notebook interactively (recommended)
The deploy script provisions everything and runs the Load notebook via API.
The user then opens TranslateMextToEnglish in the Fabric UI and runs it interactively.
This matches the proven pattern from the working `TranslateToJapanese.ipynb`.

### Option B: Two-notebook API approach
Split into 2 notebooks for API execution (5 translates each), writing to staging
tables, plus a 3rd cleanup notebook that SQL joins staging → final.
More complex, but fully automated.

### Option C: Test current notebook via API anyway
The current version with `%pip install openai` and `display()` calls hasn't been tested.
It's possible the pip install was the missing piece (though unlikely to be the cause).

---

## Current State (2026-04-03)

### Workspace: MextSkillsF4Learning
- **Capacity**: F8 (westus3f4learning)
- **Lakehouse**: MextLearningLH
- **Notebooks**: LoadMextEducationData ✅, TranslateMextToEnglish (not working via API)
- **Tables**: `mext.教育コンテンツ` (887 rows, working)
- **Test notebooks**: All cleaned up — only 2 notebooks remain
- **Test tables**: All cleaned up — only `教育コンテンツ` remains

### Local repo
- Both notebook .ipynb files saved locally in `notebooks/`
- Uncommitted changes: updated notebooks, findings.md, context files
- 2 commits previously pushed to `main` on GitHub
