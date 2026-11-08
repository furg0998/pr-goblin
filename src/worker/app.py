"""Queue worker scaffold. Repository execution is intentionally not enabled yet."""
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    failures = []
    for record in event.get("Records", []):
        try:
            job = json.loads(record["body"])
            required = ("delivery_id", "repository", "issue_number", "installation_id")
            if not all(job.get(field) for field in required):
                raise ValueError("Queue message is missing required fields")
            # Next step: obtain a short-lived installation token, then launch a
            # disposable CodeBuild/container job with narrowly scoped access.
            # Never execute issue-provided text or repo code with Lambda IAM creds.
            logger.info("Validated opted-in issue job", extra={
                "repository": job["repository"],
                "issue_number": job["issue_number"],
                "delivery_id": job["delivery_id"],
            })
        except Exception:
            logger.exception("Issue job failed")
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}

