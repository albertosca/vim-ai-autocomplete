import math


def normalize_name(raw):
    """Strip and lowercase a user-supplied name."""
    return raw.strip().lower()


def slug_separator():
    return "-"


class UserRegistry:
    def __init__(self):
        self.users = {}

    def slugify(self, raw):
        cleaned = 
