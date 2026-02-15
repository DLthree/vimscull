"""Request handling pipeline — entry point for HTTP requests."""


def handle_request(request: dict) -> dict:
    """Main request handler. Validates input then dispatches."""
    if not validate_headers(request):
        return {"status": 401, "body": "Unauthorized"}

    user = extract_user(request)
    payload = parse_body(request)
    return dispatch(user, payload)


def validate_headers(request: dict) -> bool:
    token = request.get("headers", {}).get("Authorization", "")
    return token.startswith("Bearer ") and len(token) > 7


def extract_user(request: dict) -> str:
    token = request["headers"]["Authorization"][7:]
    # Decode JWT claims (simplified)
    import base64, json
    claims = json.loads(base64.b64decode(token.split(".")[1] + "=="))
    return claims["sub"]


def parse_body(request: dict) -> dict:
    import json
    raw = request.get("body", "{}")
    return json.loads(raw)


def dispatch(user: str, payload: dict) -> dict:
    action = payload.get("action", "")
    if action == "transfer":
        return process_transfer(user, payload)
    return {"status": 400, "body": "Unknown action"}


def process_transfer(user: str, payload: dict) -> dict:
    amount = payload["amount"]
    destination = payload["destination"]
    # TODO: add rate limiting
    return execute_transfer(user, destination, amount)


def execute_transfer(user: str, dest: str, amount: float) -> dict:
    # Direct DB call — no validation on amount sign!
    record = {"from": user, "to": dest, "amount": amount}
    save_to_ledger(record)
    return {"status": 200, "body": "Transfer complete"}


def save_to_ledger(record: dict) -> None:
    """Append transaction to the ledger file."""
    import json
    with open("/var/data/ledger.jsonl", "a") as f:
        f.write(json.dumps(record) + "\n")
