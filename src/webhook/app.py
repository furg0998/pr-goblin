"""Validate GitHub issue webhooks and enqueue opted-in issues."""
import hashlib
import hmac
import json
import os

import boto3

sqs = boto3.client("sqs")
secrets = boto3.client("secretsmanager")


def _response(status, message):
    return {"statusCode": status, "headers": {"content-type": "application/json"},
            "body": json.dumps({"message": message})}


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64
        raw = base64.b64decode(raw).decode("utf-8")

    secret = secrets.get_secret_value(SecretId=os.environ["WEBHOOK_SECRET_ARN"])["SecretString"]
    expected = "sha256=" + hmac.new(secret.encode(), raw.encode(), hashlib.sha256).hexdigest()
    supplied = headers.get("x-hub-signature-256", "")
    if not hmac.compare_digest(expected, supplied):
        return _response(401, "Invalid signature")

    if headers.get("x-github-event") != "issues":
        return _response(202, "Event ignored")

    try:
        payload = json.loads(raw)
        issue = payload["issue"]
        repo = payload["repository"]["full_name"].lower()
    except (ValueError, KeyError, TypeError):
        return _response(400, "Malformed issue event")

    if payload.get("action") != "opened" and payload.get("action") != "labeled":
        return _response(202, "Action ignored")
    labels = {label.get("name", "").lower() for label in issue.get("labels", [])}
    opt_in = os.environ["OPT_IN_LABEL"].lower()
    if opt_in not in labels:
        return _response(202, "Issue is not opted in")

    allowed = {name.strip().lower() for name in os.environ["ALLOWED_REPOSITORIES"].split(",")}
    if repo not in allowed or issue.get("pull_request"):
        return _response(202, "Repository or issue is not eligible")

    delivery = headers.get("x-github-delivery", "")
    job = {"delivery_id": delivery, "repository": repo,
           "installation_id": payload.get("installation", {}).get("id"),
           "issue_number": issue["number"], "issue_title": issue.get("title", ""),
           "issue_body": issue.get("body") or ""}
    sqs.send_message(QueueUrl=os.environ["QUEUE_URL"],
                     MessageBody=json.dumps(job),
                     MessageDeduplicationId=delivery or hashlib.sha256(raw.encode()).hexdigest(),
                     MessageGroupId=repo)
    return _response(202, "Issue queued")

