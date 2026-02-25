# API Center Custom Rulesets

Spectral rulesets for API governance in Azure API Center (`api-center-poc-my`).
Supports **REST / OpenAPI**, **GraphQL**, and **MCP** (Model Context Protocol) APIs with
type-specific rules selected automatically via `config.yaml` metadata.

> **Azure API Center analyzer config limits by service tier:**
>
> | Tier       | Max Analyzer Configs |
> |------------|----------------------|
> | **Free**   | 1                    |
> | **Standard** | 3                  |
>
> This repo targets the **Standard** tier and uses all 3 slots:
> `default` (REST), `graphql-ruleset`, `mcp-ruleset`.
> On the **Free** tier only one analyzer config can be deployed — choose the
> ruleset that matches your primary API type.

## Structure

```
├── .github/workflows/
│   └── deploy-ruleset.yml              # GitHub Actions workflow for auto-deployment
├── rulesets/
│   ├── rest-default/                   # REST – Spectral OAS + security controls
│   │   ├── config.yaml                 #   apiType: rest, analyzerConfigName: default
│   │   └── ruleset.yaml
│   ├── graphql-ruleset/                # GraphQL – schema hygiene + security
│   │   ├── config.yaml                 #   apiType: graphql
│   │   └── ruleset.yaml
│   └── mcp-ruleset/                    # MCP – tool/resource/prompt governance
│       ├── config.yaml                 #   apiType: mcp
│       └── ruleset.yaml
├── scripts/
│   ├── deploy-all-rulesets.ps1         # Deploys all (or filtered) rulesets
│   ├── deploy-ruleset.ps1             # Deploys a single ruleset
│   └── cleanup-old-configs.ps1        # One-time: deletes orphaned configs
└── README.md
```

## API Type Routing

Each ruleset directory contains a **`config.yaml`** that declares its API type,
analyzer engine, and target config name:

```yaml
apiType: rest                       # rest | graphql | mcp
analyzerType: spectral              # analyzer engine used by API Center
analyzerConfigName: default         # Azure API Center config to deploy into
```

The deploy scripts read this file to:
- **Filter** – deploy only rulesets matching a given API type (`-ApiType` parameter)
- **Route** – deploy the ruleset to the correct Azure analyzer config name
- **Configure** – create the analyzer config with the correct engine type

## How It Works

When you push changes to `rulesets/**` on the `main` branch, the GitHub Actions workflow automatically:

1. Discovers all ruleset subdirectories under `rulesets/` (each subfolder containing a `ruleset.yaml` or `ruleset.yml`)
2. Reads **`config.yaml`** in each directory to determine `apiType` and `analyzerType`
3. Optionally filters rulesets by API type (when triggered manually with an `api_type` input)
4. For each matching ruleset, packages it (and any `functions/` folder) into a zip
5. Base64-encodes the zip
6. Ensures the analyzer config exists with the correct analyzer type
7. Calls the API Center `importRuleset` REST API to deploy it

The `analyzerConfigName` in config.yaml maps each directory to its Azure API Center
target (e.g., `rest-default/` deploys to the `default` config, `graphql-ruleset/`
deploys to `graphql-ruleset`).

## Setup

### 1. Create an Azure AD App Registration with Federated Credentials

```bash
# Create app registration
az ad app create --display-name "api-center-ruleset-deploy"

# Note the appId, then create a service principal
az ad sp create --id <APP_ID>

# Add federated credential for GitHub Actions OIDC
az ad app federated-credential create --id <APP_OBJECT_ID> --parameters '{
  "name": "github-actions-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<GITHUB_ORG>/<REPO_NAME>:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

### 2. Assign RBAC Role

Grant the service principal `Contributor` (or a custom role with `Microsoft.ApiCenter/services/workspaces/analyzerConfigs/*` permissions) on the API Center resource:

```bash
az role assignment create \
  --assignee <APP_ID> \
  --role "Contributor" \
  --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.ApiCenter/services/<SERVICE>"
```

### 3. Configure GitHub Repository Secrets

| Secret                    | Value                                            |
|---------------------------|--------------------------------------------------|
| `AZURE_CLIENT_ID`        | App registration Application (client) ID         |
| `AZURE_TENANT_ID`        | Azure AD tenant ID                               |
| `AZURE_SUBSCRIPTION_ID`  | `86b37969-9445-49cf-b03f-d8866235171c`           |
| `AZURE_RESOURCE_GROUP`   | `ai-myaacoub`                                    |
| `API_CENTER_SERVICE_NAME`| `api-center-poc-my`                              |

### 4. Push and Deploy

```bash
git add .
git commit -m "Update custom Spectral ruleset"
git push origin main
```

The workflow triggers automatically on changes to the ruleset files.

## Manual Deployment

### One-time migration: clean up old configs

If you previously had `custom-ruleset` and `custom-ruleset-no-spectral` configs,
run the cleanup script first to free slots:

```powershell
./scripts/cleanup-old-configs.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my"
```

### Deploy all rulesets

```powershell
./scripts/deploy-all-rulesets.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my" `
  -RulesetsRoot "./rulesets"
```

### Deploy by API type

```powershell
# Deploy REST rulesets only (→ default config)
./scripts/deploy-all-rulesets.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my" `
  -ApiType "rest"

# Deploy GraphQL rulesets only (→ graphql-ruleset config)
./scripts/deploy-all-rulesets.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my" `
  -ApiType "graphql"

# Deploy MCP rulesets only (→ mcp-ruleset config)
./scripts/deploy-all-rulesets.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my" `
  -ApiType "mcp"
```

### Deploy a single ruleset

```powershell
./scripts/deploy-ruleset.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my" `
  -AnalyzerConfigName "default" `
  -RulesetPath "./rulesets/rest-default"
```

## Manual Trigger

You can also trigger the workflow manually from the GitHub Actions tab using the **Run workflow** button.
Select an **API type** (`rest`, `graphql`, or `mcp`) to deploy only matching rulesets, or leave it
empty to deploy all rulesets. Check **cleanup_old_configs** to delete orphaned configs first (one-time migration).

## Rulesets by API Type

| API Type  | Source Directory   | Analyzer Config    | Key Rules                                                       |
|-----------|--------------------|--------------------|-----------------------------------------------------------------|
| REST      | `rest-default`     | `default`          | Spectral OAS linting + `x-security-controls` enforcement        |
| GraphQL   | `graphql-ruleset`  | `graphql-ruleset`  | Schema hygiene, depth/complexity limits, `x-security-controls`  |
| MCP       | `mcp-ruleset`      | `mcp-ruleset`      | Tool/resource/prompt governance, transport security, prompt injection protection |
