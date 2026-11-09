# Deploying with GitHub Actions and AWS OIDC

The deployment workflow uses GitHub's OIDC token to assume an AWS role. It does not store AWS access keys in GitHub. It validates pull requests targeting `main`, and deploys after a successful push to `main`. You can also start a deployment manually from the workflow page, using the `main` branch.

## 1. Bootstrap the AWS pipeline roles

Use an AWS CLI profile with permission to create IAM roles, an OIDC identity provider, and an S3 bucket. The bootstrap is a one-time AWS setup; it does not deploy the application stack.

```sh
aws sts get-caller-identity
sam pipeline bootstrap --stage production --region YOUR_AWS_REGION
```

If you use a named profile, add `--profile YOUR_ADMIN_PROFILE`. In the prompts:

1. Choose **OpenID Connect** as the permissions provider and **GitHub Actions** as the OIDC provider.
2. Use `https://token.actions.githubusercontent.com` and audience `sts.amazonaws.com`.
3. Enter owner `furg0998`, repository `pr-goblin`, and deployment branch `main`.
4. Let SAM create the pipeline execution role, CloudFormation execution role, and artifact bucket, unless your AWS administrator has supplied existing resources.
5. Review the summary carefully before confirming. The command creates IAM and S3 resources in the selected AWS account and region.

Record the pipeline execution role ARN, CloudFormation execution role ARN, artifact bucket name, and region from the output. Keep the OIDC role trust restricted to this repository and `main`.

## 2. Create the application secrets in AWS

In the same AWS account and region, create these Secrets Manager secrets before deploying:

- **GitHub App secret:** JSON with `app_id`, `installation_id`, and `private_key_pem`.
- **Webhook secret:** the raw webhook secret configured on the GitHub App.

From the repository root, you can create both with the helper script:

```powershell
.\scripts\create-github-secrets.ps1 -Profile default -Region ap-southeast-2
```

It checks the AWS account, refuses to overwrite existing secrets, stores the downloaded PEM key without printing it, and generates the webhook secret for you to copy into the GitHub App settings. The profile needs `sts:GetCallerIdentity`, `secretsmanager:DescribeSecret`, and `secretsmanager:CreateSecret` permissions. Record the returned ARNs. The secret values stay in Secrets Manager and GitHub App settings; only the ARNs go into GitHub Actions variables.

## 3. Add repository Actions variables

In the GitHub repository, open **Settings → Secrets and variables → Actions → Variables** and add:

| Variable | Value |
| --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | Pipeline execution role ARN from SAM bootstrap |
| `AWS_REGION` | Region used for the bootstrap and application stack |
| `AWS_STACK_NAME` | `pr-goblin` |
| `SAM_ARTIFACT_BUCKET` | S3 artifact bucket **name** from SAM bootstrap |
| `CFN_EXECUTION_ROLE_ARN` | CloudFormation execution role ARN from SAM bootstrap |
| `APP_CREDENTIALS_SECRET_ARN` | ARN of the GitHub App secret in Secrets Manager |
| `WEBHOOK_SECRET_ARN` | ARN of the webhook secret in Secrets Manager |
| `ALLOWED_REPOSITORIES` | Comma-separated `owner/repo` allowlist |
| `OPT_IN_LABEL` | Optional; defaults to `ai-ready` |

These values are configuration, not credentials. Do not add AWS access keys or the GitHub App private key to GitHub Actions.

## 4. Run and protect deployments

After adding the variables, open **Actions → Validate CloudFormation → Run workflow** and select `main`. The deploy job assumes the OIDC role, builds with SAM, and deploys using the CloudFormation execution role. Subsequent pushes to `main` deploy automatically after validation succeeds.

Protect `main` with a rule that requires the **Validate CloudFormation template** status check before merging. Also require changes to go through pull requests so an unreviewed commit cannot trigger deployment. The deploy job itself does not run for pull request events.

The current worker is still a safe placeholder; deploying the stack does not yet make it generate code or open PRs.

