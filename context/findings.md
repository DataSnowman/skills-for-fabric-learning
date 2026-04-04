

# Translation Notebook Findings

## Summary

This repo loads a Japanese education CSV (MEXT data, ~890 rows, 15 columns) into a
Delta table (`mext.education_content_jp` with Japanese column headers) and then uses
Fabric AI functions (`df.ai.translate`) to create an English version (`mext.education_content_en`).

Both notebooks work end-to-end via the deploy script (`deploy-mext-e2e.sh`), including
the translation notebook running as a REST API batch job (~4.5 minutes for 10 columns).

---

## Working Pattern: Independent Translates + Pandas Collection

The key discovery is that **ai.translate() chaining is broken** — each chained call
drops all previously translated columns, keeping only the last one. The working pattern
translates each column **independently** from the source DataFrame, collects each result
to pandas, then joins them in memory.

### TranslateMextToEnglish.ipynb Structure

```
Cell 0: Import — import synapse.ml.spark.aifunc as aifunc
Cell 1: Read source table — spark.table('mext.education_content_jp') + display
Cell 2: Rename Japanese columns to ASCII (required for ai.translate input_col)
Cell 3: Loop — translate 10 columns independently, collect each to pandas,
         join in pandas DataFrame, convert back to Spark, write to mext.education_content_en
Cell 4: Verify — read back and display the English table
```

### Why This Works (and chaining doesn't)

```python
# BROKEN — each call drops previous output columns:
result = df.ai.translate(to_lang='en', input_col='col_a', output_col='a_en')
result = result.ai.translate(to_lang='en', input_col='col_b', output_col='b_en')
# result only has b_en, NOT a_en

# WORKING — independent translates collected to pandas:
for col_name, out_name in translate_cols:
    translated = df.ai.translate(to_lang='en', input_col=col_name, output_col=out_name)
    en_series = translated.select(out_name).toPandas()[out_name]
    pdf[out_name] = en_series
```

With only ~890 rows, the pandas collection is fast and memory-efficient.

---

## Key Discoveries

### 1. ai.translate() chaining is BROKEN (April 2026)

Each `ai.translate()` call on a previously translated DataFrame drops all prior
translated output columns. Only the LAST output_col survives. This was the documented
pattern but no longer works. Confirmed both interactively and via REST API.

### 2. AI functions fail with Japanese column names

`df.ai.translate()` fails when the `input_col` references a column with Japanese characters.
**Rename all Japanese column names to ASCII before translating** using `withColumnRenamed()`.

### 3. No pip install needed for AI functions

PySpark AI functions work with just `import synapse.ml.spark.aifunc as aifunc`.
No `%pip install openai` is required.

### 4. Independent translate + pandas works via REST API

Unlike the chaining pattern, the independent translate approach with `.select().toPandas()`
works both interactively in the Fabric UI AND as a REST API `RunNotebook` batch job.
Translation of 10 columns takes ~4.5 minutes via API.

### 5. Japanese table names → "Unidentified" in Lakehouse SQL endpoint

Using `saveAsTable('mext.教育コンテンツ')` creates tables the SQL endpoint can't sync
metadata for, especially with full-width characters like ＵＲＬ. **Use English table names**
(`education_content_jp`, `education_content_en`). Japanese column names display as
"Unidentified" in the SQL endpoint but the data is accessible via Spark.

### 6. Columns translated (10 of 15)

Five columns are renamed only (no AI translation needed):
- `教材_ID` → `material_id` — Alphanumeric code
- `教材_言語` → `material_language` — Already in English
- `教材_分野_科目` → `material_field` — Empty/NULL values
- `教材_ＵＲＬ` → `material_url` — URLs (English)
- `教材_ライセンス` → `material_license` — Already in English

Ten columns are translated via AI:
- material_name, material_keywords, material_format, material_target_audience,
  material_subject, material_target_grade, material_content_type,
  material_price_category, material_status, material_publisher

---

## Column Mapping (15 columns)

| # | Japanese Column | English Name | Action |
|---|---|---|---|
| 1 | 教材_ID | material_id | Rename only (alphanumeric code) |
| 2 | 教材_名称 | material_name | **Translate** |
| 3 | 教材_言語 | material_language | Rename only (already English) |
| 4 | 教材_キーワード | material_keywords | **Translate** |
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

### Notebook Deployment via REST API
- Create: `POST /v1/workspaces/{WS_ID}/items` with `type: "Notebook"`
- Update: `POST /v1/workspaces/{WS_ID}/notebooks/{NB_ID}/updateDefinition`
- `.platform` part needs `"type": "SparkNotebook"` (not "Notebook")
- Lakehouse binding goes in notebook metadata `dependencies`

---

## Architecture

```
CSV (Shift-JIS) → OneLake Files → LoadMextEducationData.ipynb
                                        ↓
                               mext.education_content_jp
                               (Japanese column headers, 887 rows)
                                        ↓
                               TranslateMextToEnglish.ipynb
                               (10 independent ai.translate → pandas → Spark)
                                        ↓
                               mext.education_content_en
                               (English column names + translated values)
```

## Current State (2026-04-04)

- **Deploy script**: Fully automated E2E — provisions capacity, workspace, lakehouse,
  uploads CSV, deploys notebooks, runs Load AND Translate via REST API
- **Load notebook**: ✅ Works via API (~30 seconds)
- **Translate notebook**: ✅ Works via API (~4.5 minutes) and interactively
- **Tables**: `mext.education_content_jp` (Japanese), `mext.education_content_en` (English)
- **Capacity**: F4, West US 3
- **Git**: All committed and pushed to `main` on GitHub
