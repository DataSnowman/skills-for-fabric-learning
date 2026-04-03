# Load MEXT Education Data — End-to-End Guide

This guide documents the full process of provisioning Microsoft Fabric infrastructure and loading [Children's Learning Support Site Content Information](https://data.e-gov.go.jp/data/en/dataset/mext_20210222_0025) (子供の学び応援サイト掲載コンテンツ情報) data (~887 rows) into a Delta table using the Azure CLI and Fabric REST APIs.

> This is a simplified learning version of [skills-for-fabric-load-medicare-data](https://github.com/DataSnowman/skills-for-fabric-load-medicare-data). Instead of 275M rows of Medicare data with zip files and multiple notebooks, this repo uses a single small CSV and one notebook — perfect for learning the Fabric deployment workflow.

> This project was built using [GitHub Copilot CLI](https://docs.github.com/en/copilot) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with skills and context from [microsoft/skills-for-fabric](https://github.com/microsoft/skills-for-fabric).

> **🇯🇵 日本語版 README はこちら: [README.md](README.md)**

## About the Dataset

The data comes from the **Ministry of Education, Culture, Sports, Science and Technology (MEXT / 文部科学省)** of Japan. It contains metadata for ~998 educational video content items published on the Children's Learning Support Site.

| Field | Description |
|---|---|
| **Source** | [e-Gov Data Portal](https://data.e-gov.go.jp/data/en/dataset/mext_20210222_0025) |
| **Publisher** | MEXT (文部科学省) |
| **License** | CC BY 4.0 |
| **Rows** | ~998 |
| **Encoding** | Shift-JIS |
| **Subjects** | Japanese, Arithmetic, Math, Science, Social Studies, Foreign Language |
| **Grade Levels** | Elementary 1–6, Middle School 1–3 |

## Prerequisites

- **GitHub Copilot CLI** ([Install](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)) or **Claude Code** ([Quickstart](https://code.claude.com/docs/en/quickstart))
- **Azure CLI** installed (`az --version`)
- **Logged in** to Azure (`az login`)
- **Python 3.9+** available (`python3 --version`)
- **Bash shell** — macOS Terminal, Linux shell, or Windows WSL/Git Bash
- **Microsoft Fabric** — An Azure subscription with permissions to create Resource Groups and [Fabric capacities](https://learn.microsoft.com/en-us/fabric/enterprise/licenses) (F4 or higher)
- **curl** available for downloading the CSV

> **Windows users:** Run the script in [WSL](https://learn.microsoft.com/en-us/windows/wsl/install) or Git Bash. Native PowerShell is not supported.

## Configuration

All configuration is managed in [`config/variables.md`](config/variables.md). **Edit this file before running the script.**

| Variable | Description |
|---|---|
| `RESOURCE_GROUP` | Azure Resource Group name |
| `LOCATION` | Azure region (e.g., `westus3`) |
| `SKU` | Fabric capacity SKU (`F4` minimum) |
| `CAPACITY_NAME` | Globally unique, lowercase alphanumeric |
| `WORKSPACE_NAME` | Fabric workspace display name |
| `LAKEHOUSE_NAME` | Lakehouse to create |

```bash
# Azure
RESOURCE_GROUP="FabricCapacityWestUS3"
LOCATION="westus3"
SKU="F4"

# Fabric
CAPACITY_NAME="westus3f4skillsflearning"
WORKSPACE_NAME="MextSkillsF4Learning"
LAKEHOUSE_NAME="MextLearningLH"
```

## Quick Start

### Step 1 — Clone the Repo

```bash
git clone https://github.com/DataSnowman/skills-for-fabric-learning.git
```

### Step 2 — Change into the Repo Directory

```bash
cd skills-for-fabric-learning
```

### Step 3 — Edit Configuration

Edit `config/variables.md` and set your preferred names for the capacity, workspace, and lakehouse. The CSV will be downloaded automatically.

### Step 4 — Run the Deployment

#### Option A: Shell Script (one command)

```bash
chmod +x deploy-mext-e2e.sh
./deploy-mext-e2e.sh
```

#### Option B: AI Agent

Open GitHub Copilot CLI or Claude Code and point it at the context files:

```
Load the MEXT education CSV data into a Fabric lakehouse using the instructions
in context/loadMextData.md and the configuration in config/variables.md.
Deploy the notebook in notebooks/LoadMextEducationData.ipynb.
```

## What the Script Does

| Step | Description |
|---|---|
| 0 | Preflight checks (Azure login, notebook exists) |
| 1 | Download CSV from MEXT website |
| 2 | Create Azure Resource Group |
| 3 | Create Fabric Capacity (F4) |
| 4 | Create Fabric Workspace |
| 5 | Create Lakehouse |
| 6 | Upload CSV to OneLake |
| 7 | Deploy notebook with lakehouse binding |
| 8 | Run notebook (loads CSV → Delta table) |
| 9 | Verify Delta table exists |

## Repo Structure

```
skills-for-fabric-learning/
├── README.md                          ← Japanese README (shown on GitHub homepage)
├── README.en.md                       ← English README
├── config/
│   └── variables.md                   ← Deployment configuration
├── context/
│   └── loadMextData.md                ← AI agent context file
├── data/
│   └── putfileshere.txt               ← (CSV downloaded automatically)
├── notebooks/
│   └── LoadMextEducationData.ipynb    ← Spark notebook
├── deploy-mext-e2e.sh                 ← End-to-end deployment script
├── pyproject.toml
└── .gitignore
```

## Verifying the Results

After deployment, query the Delta table in Fabric SQL:

```sql
SELECT 教材_教科等 AS subject, COUNT(*) AS count
FROM [MextLearningLH].[mext].[education_content]
GROUP BY 教材_教科等
ORDER BY count DESC
```

## Troubleshooting

| Issue | Solution |
|---|---|
| `az login` fails | Run `az login` and follow the browser prompt |
| Capacity creation fails | Ensure your subscription has Fabric capacity permissions |
| CSV download fails | Check internet connectivity; try downloading manually to `data/` |
| Notebook job fails | Check Fabric capacity is F4 or higher (F2 lacks Spark resources) |
| Delta table not found | Wait a few minutes and re-run the verify step |
| Shift-JIS encoding errors | The notebook handles encoding automatically; ensure the CSV is unmodified |

## Related Projects

- **[skills-for-fabric-load-medicare-data](https://github.com/DataSnowman/skills-for-fabric-load-medicare-data)** — Full-scale version with 275M rows of Medicare data
- **[microsoft/skills-for-fabric](https://github.com/microsoft/skills-for-fabric)** — Reusable AI skills for Microsoft Fabric
- **[DataSnowman/fabriclakehouse](https://github.com/DataSnowman/fabriclakehouse)** — Original GUI-based Fabric walkthrough
