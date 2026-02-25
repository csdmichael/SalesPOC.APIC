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
> On the **Free** tier only the built-in `default` config can be used — deploy
> the REST ruleset into it.

## Structure

```
├── .github/workflows/
│   └── deploy-ruleset.yml              # GitHub Actions workflow (2 jobs)
├── rulesets/
│   ├── rest-default/                   # REST – Spectral OAS + security controls
│   │   ├── config.yaml                 #   apiType: rest, analyzerConfigName: default
│   │   └── ruleset.yaml
│   ├── graphql-ruleset/                # GraphQL – schema hygiene + security
│   │   ├── config.yaml                 #   apiType: graphql, analyzerType: custom
│   │   └── ruleset.yaml
│   └── mcp-ruleset/                    # MCP – tool/resource/prompt governance
│       ├── config.yaml                 #   apiType: mcp, analyzerType: custom
│       └── ruleset.yaml
├── scripts/
│   ├── deploy-all-rulesets.ps1         # Deploys all (or filtered) rulesets
│   ├── deploy-ruleset.ps1             # Deploys a single ruleset
│   ├── ensure-apic-service.ps1        # Creates resource group & API Center service if missing
│   └── cleanup-old-configs.ps1        # One-time: deletes orphaned configs
└── README.md
```

## API Type Routing

Each ruleset directory contains a **`config.yaml`** that declares its API type,
analyzer engine, and target config name:

```yaml
apiType: rest                       # rest | graphql | mcp
analyzerType: spectral              # spectral (REST) or custom (GraphQL/MCP)
analyzerConfigName: default         # Azure API Center config to deploy into
```

The deploy scripts read this file to:
- **Filter** – deploy only rulesets matching a given API type (`-ApiType` parameter)
- **Route** – deploy the ruleset to the correct Azure analyzer config name
- **Configure** – create the analyzer config with the correct engine type

## How It Works

The GitHub Actions workflow runs **two jobs**:

### Job 1 – Ensure API Center Service

Creates the resource group and API Center service if they don't already exist
(via `ensure-apic-service.ps1`). Configurable `location` and `sku` inputs control
where and at what tier the service is provisioned.

### Job 2 – Deploy Rulesets

Runs after Job 1 completes:

1. Discovers ruleset subdirectories under `rulesets/`
2. Reads **`config.yaml`** in each directory to determine `apiType`, `analyzerType`, and `analyzerConfigName`
3. Optionally filters rulesets by API type (when triggered manually with an `api_type` input)
4. **Auto-prunes stale analyzer configs** – lists existing configs and deletes any not in the target set (the built-in `default` config is never deleted)
5. For each matching ruleset, packages it into a zip, base64-encodes it
6. Ensures the analyzer config exists with the correct analyzer type
7. Calls the API Center `importRuleset` REST API to deploy it

The `analyzerConfigName` in config.yaml maps each directory to its Azure API Center
target: `rest-default/` deploys to the built-in `default` config, `graphql-ruleset/`
deploys to `graphql-ruleset`, `mcp-ruleset/` deploys to `mcp-ruleset`.

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

### 2. Assign RBAC Roles

Grant the service principal **Contributor** on the **resource group** so it can
create / manage the API Center service and its analyzer configs:

```bash
# Resource-group-level Contributor – covers service creation, RG reads, and analyzer config management
az role assignment create \
  --assignee <APP_ID> \
  --role "Contributor" \
  --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG>"
```

> **Minimal alternative:** if the API Center service and resource group already
> exist and you only need to deploy rulesets, you can scope Contributor to the
> service resource instead:
>
> ```bash
> az role assignment create \
>   --assignee <APP_ID> \
>   --role "Contributor" \
>   --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.ApiCenter/services/<SERVICE>"
> ```
>
> With this narrower scope the workflow can still deploy rulesets, but it will
> **not** be able to create the resource group or the API Center service if they
> are missing.

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

### Ensure API Center service exists

```powershell
./scripts/ensure-apic-service.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my" `
  -Location "eastus" `
  -Sku "Standard"
```

### Deploy all rulesets

```powershell
./scripts/deploy-all-rulesets.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my"
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
empty to deploy all rulesets. Choose a **Location** and **SKU** for service creation (defaults: `eastus` / `Standard`).
Check **cleanup_old_configs** to delete orphaned configs first (one-time migration).

## Rulesets by API Type

| API Type  | Source Directory   | Analyzer Config    | Analyzer Type | Key Rules                                                       |
|-----------|--------------------|--------------------|---------------|-----------------------------------------------------------------|
| REST      | `rest-default`     | `default`          | `spectral`    | Spectral OAS linting + `x-security-controls` enforcement        |
| GraphQL   | `graphql-ruleset`  | `graphql-ruleset`  | `custom`      | Schema hygiene, depth/complexity limits, `x-security-controls`  |
| MCP       | `mcp-ruleset`      | `mcp-ruleset`      | `custom`      | Tool/resource/prompt governance, transport security, prompt injection protection |
