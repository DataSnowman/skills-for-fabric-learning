# Shared Variables

Copy-paste these into your terminal before running any commands, or source this file directly.

```bash
# Azure Subscription
SUBSCRIPTION_ID=""                          # auto-populated via: az account show --query id --output tsv
ADMIN_EMAIL=""                              # auto-populated via: az account show --query user.name --output tsv

# Resource Group & Location
RESOURCE_GROUP="FabricCapacityWestUS3"      # Created automatically if it doesn't exist
LOCATION="westus3"
SKU="F4"

# Fabric Capacity
CAPACITY_NAME="westus3f4skillsflearning"

# Fabric Workspace
WORKSPACE_NAME="MextSkillsF4Learning"

# Lakehouse
LAKEHOUSE_NAME="MextLearningLH"

# Data Source (MEXT Education Content CSV)
CSV_URL="https://www.mext.go.jp/content/20201221-mxt_syogai03-000010378_2.csv"
CSV_FILENAME="mext_education_content.csv"

# OneLake Paths
ONELAKE_DATA_PATH="Files/mext"

# Delta Table
DELTA_SCHEMA="mext"
DELTA_TABLE="education_content"

# Notebook (Fabric)
NOTEBOOK_NAME="LoadMextEducationData"
```

## Auto-populate Subscription and Admin Email

Run this once after `az login` to set the auto-populated values:

```bash
SUBSCRIPTION_ID=$(az account show --query id --output tsv)
ADMIN_EMAIL=$(az account show --query user.name --output tsv)
```

## Data Source

**Children's Learning Support Site Content Information (Open Data)**
- Dataset page: https://data.e-gov.go.jp/data/en/dataset/mext_20210222_0025
- Publisher: Ministry of Education, Culture, Sports, Science and Technology (MEXT / 文部科学省)
- License: CC BY 4.0
- Rows: 998
- Encoding: Shift-JIS (converted to UTF-8 during load)

### CSV Columns

| Column (Japanese) | Column (English) | Description |
|---|---|---|
| 教材_ID | Material ID | Unique content identifier |
| 教材_名称 | Material Name | Title of the learning content |
| 教材_言語 | Language | Language code (ja) |
| 教材_キーワード | Keywords | Search keywords |
| 教材_形式 | Format | Content classification (教材=Teaching Material) |
| 教材_対象者 | Target Audience | Intended audience (学習者=Learner) |
| 教材_教科等 | Subject | Subject area (国語, 算数, 理科, etc.) |
| 教材_分野_科目 | Field/Course | Specific field or course |
| 教材_対象学年 | Target Grade | Grade level (小1-小6, 中1-中3) |
| 教材_コンテンツ形式 | Content Format | Media type (動画=Video) |
| 教材_ＵＲＬ | URL | Public URL of the content |
| 教材_価格_区分 | Price Category | Free/Paid (無償=Free) |
| 教材_ライセンス | License | Content license |
| 教材_状態 | Status | Publication status (公開=Published) |
| 教材_公開者 | Publisher | Publishing organization |
