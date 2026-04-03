# Load MEXT Education Data into Fabric

This document provides context for AI coding agents (GitHub Copilot CLI, Claude Code) on how to load MEXT education content data into a Microsoft Fabric Lakehouse Delta table.

## Overview

The data comes from the **Children's Learning Support Site** (子供の学び応援サイト) published by the Japanese Ministry of Education (MEXT). It contains metadata for ~890 educational content items including titles, subjects, grade levels, URLs, licenses, and publishers.

## Workflow

### 1. Download CSV

The CSV is publicly available and small (~179 KB). The deployment script downloads it automatically:

```bash
curl -sL "$CSV_URL" -o "$DATA_DIR/$CSV_FILENAME"
```

### 2. Upload to OneLake

Upload the raw CSV to the Lakehouse Files area using the OneLake blob endpoint:

```bash
curl -X PUT \
  -H "Authorization: Bearer $STORAGE_TOKEN" \
  -H "x-ms-version: 2023-01-03" \
  -H "x-ms-blob-type: BlockBlob" \
  --data-binary @"$LOCAL_CSV_PATH" \
  "https://onelake.blob.fabric.microsoft.com/$WS_ID/$LH_ID/Files/mext/$CSV_FILENAME"
```

### 3. Load into Delta Table

The notebook uses **Python's csv module** (not `spark.read.csv`) to read the CSV, then creates a Spark DataFrame and writes to a Delta table.

**Important notes:**
- The CSV is encoded in **Shift-JIS** (cp932), not UTF-8
- **Do NOT use `spark.read.csv()`** — it fails to write the resulting DataFrame to Delta tables in Fabric. Use Python's `csv.reader` with `encoding='shift_jis'` instead, then `spark.createDataFrame()`.
- The CSV has 26 columns but only the first 15 contain data; the rest are empty padding
- Some rows have embedded newlines in the `教材_名称` field — Python's csv.reader handles these correctly
- There are ~140 empty rows at the end of the file — filter by checking the first column

### 4. Notebook Lakehouse Binding

The notebook must be bound to the lakehouse via notebook metadata dependencies, not via a PATCH body. Use the `updateDefinition` endpoint:

```
POST /v1/workspaces/{WS_ID}/notebooks/{NB_ID}/updateDefinition
```

The notebook metadata must include:
```json
{
  "dependencies": {
    "lakehouse": {
      "default_lakehouse": "<LH_ID>",
      "default_lakehouse_name": "<LH_NAME>",
      "default_lakehouse_workspace_id": "<WS_ID>",
      "known_lakehouses": [{"id": "<LH_ID>"}]
    }
  }
}
```

### 5. Verify

After the notebook runs, verify the Delta table exists:

```sql
SELECT 教材_教科等 AS subject, COUNT(*) AS count
FROM [LakehouseName].[mext].[education_content]
GROUP BY 教材_教科等
ORDER BY count DESC
```

Expected subjects and approximate counts:
| Subject | Japanese | Count |
|---|---|---|
| 国語 | Japanese Language | ~250+ |
| 算数 | Arithmetic | ~200+ |
| 理科 | Science | ~150+ |
| 社会 | Social Studies | ~100+ |
| 外国語 | Foreign Language | ~100+ |
| 数学 | Mathematics | ~50+ |
