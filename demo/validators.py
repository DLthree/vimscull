"""Validation helpers used by the request pipeline."""


def validate_amount(amount) -> bool:
    """Check that transfer amount is a positive number."""
    return isinstance(amount, (int, float)) and amount > 0


def validate_destination(dest: str) -> bool:
    """Check destination account format."""
    return isinstance(dest, str) and len(dest) == 12 and dest.isalnum()


def sanitize_input(raw: str) -> str:
    """Strip dangerous characters from user input."""
    return raw.replace("<", "").replace(">", "").replace("&", "")


def check_rate_limit(user: str) -> bool:
    """Stub: check if user has exceeded rate limit."""
    # TODO: implement actual rate limiting with Redis
    return True
