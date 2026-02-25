# API Center Custom Ruleset

Spectral ruleset for API governance in Azure API Center (`api-center-poc-my`).

## Structure

```
├── .github/workflows/
│   └── deploy-ruleset.yml      # GitHub Actions workflow for auto-deployment
├── rulesets/custom-ruleset/
│   └── ruleset.yaml            # Spectral ruleset (edit this)
├── scripts/
│   └── deploy-ruleset.ps1      # Deployment script
└── README.md
```

## How It Works

When you push changes to `rulesets/custom-ruleset/**` on the `main` branch, the GitHub Actions workflow automatically:

1. Packages `ruleset.yaml` (and any `functions/` folder) into a zip
2. Base64-encodes the zip
3. Calls the API Center `importRuleset` REST API to deploy it

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

You can also run the deployment script locally:

```powershell
./scripts/deploy-ruleset.ps1 `
  -SubscriptionId "86b37969-9445-49cf-b03f-d8866235171c" `
  -ResourceGroup "ai-myaacoub" `
  -ServiceName "api-center-poc-my" `
  -AnalyzerConfigName "custom-ruleset" `
  -RulesetPath "./rulesets/custom-ruleset"
```

## Manual Trigger

You can also trigger the workflow manually from the GitHub Actions tab using the **Run workflow** button.
