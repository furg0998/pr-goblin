# Issue to PR

An AWS-hosted, GitHub App based starter for turning explicitly opted-in GitHub issues into draft pull requests with an AI coding agent.

## Flow

1. GitHub sends an `issues` webhook to API Gateway.
2. The webhook Lambda validates the GitHub HMAC signature, event type, action, and opt-in label, then queues a minimal work item in SQS.
3. The worker consumes the item, obtains a short-lived GitHub App installation token, checks out the allowlisted repository in an isolated job, runs the coding agent, and opens a draft PR.
4. CI and a human review the PR. This service does not merge or deploy changes.

The first infrastructure iteration provisions API Gateway, two Lambda functions, SQS with a dead-letter queue, and encrypted Secrets Manager storage for the GitHub App private key and webhook secret. The worker is deliberately a scaffold: code execution should move into a disposable CodeBuild/container boundary before enabling real repositories.

## GitHub App setup

Create an App configured with:

- Webhook event: **Issues**
- Repository permissions: **Issues: read**, **Contents: read and write**, **Pull requests: read and write**, **Metadata: read**
- Install it only on pilot repositories
- Set the webhook URL to the deployed API Gateway endpoint and configure a webhook secret
- Store the App ID, installation ID (or resolve it at runtime), and private key in Secrets Manager

Do not commit credentials. Configure `GitHubAppSecretArn` and `WebhookSecretArn` during stack deployment. Grant the worker only `GetSecretValue` for the GitHub App secret and SQS consume permissions. The webhook secret is read by the webhook function only.

## Deploy

This repository uses AWS SAM syntax in a CloudFormation template. With AWS CLI and SAM CLI configured:

```powershell
sam build
sam deploy --guided
```

Supply secret ARNs at deploy time. Create the secret values out of band before deployment. Set `OptInLabel` to the label maintainers must add to an issue to permit processing.

## Current status

- Webhook signature and opt-in event validation are implemented.
- SQS queue and dead-letter queue are defined.
- Worker validates job shape and has an explicit safe placeholder response.
- Repository checkout, agent execution, tests, and PR creation are not yet implemented.

## Security boundaries

- Treat issue text and repository files as untrusted instructions.
- Restrict repository installations and enforce an AWS-side owner/repository allowlist before processing.
- Never expose AWS credentials or App credentials to agent-controlled shell commands.
- Use a disposable build/container with restricted network and scoped GitHub token for repository execution.
- Deduplicate GitHub deliveries and make the worker idempotent before enabling retries against real repositories.
- Keep generated PRs in draft state and require normal CI and human review.

