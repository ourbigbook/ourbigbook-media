#!/usr/bin/env python3
"""Merge a user dump and extract identifiers from user-authored text."""

import argparse
import ipaddress
import json
import re
import sys


COMMON_TLDS = (
    "academy", "agency", "ai", "app", "biz", "blog", "ca", "cc", "cloud",
    "club", "co", "com", "de", "dev", "digital", "email", "expert",
    "finance", "fr", "global", "guru", "help", "in", "info", "io", "life",
    "link", "live", "me", "mobi", "net", "network", "news", "one",
    "online", "org", "pro", "ru", "services", "shop", "site", "solutions",
    "store", "support", "tech", "tk", "top", "uk", "us", "vip", "website",
    "work", "world", "xyz", "zone",
)
TLD_PATTERN = r"(?:[A-Z]{2}|" + "|".join(COMMON_TLDS) + r")"


def _spaced_word(word):
    return r"\s*".join(re.escape(char) for char in word)


OBFUSCATED_TLD_RE = re.compile(
    r"\s*\.\s*(?:" + "|".join(_spaced_word(tld) for tld in COMMON_TLDS) + r")(?![A-Za-z])",
    re.IGNORECASE,
)
WORD_DOT_RE = re.compile(
    r"(?<=\w)\s*(?:\[\s*dot\s*\]|\(\s*dot\s*\)|\{\s*dot\s*\}|\bdot\b)\s*(?=\w)",
    re.IGNORECASE,
)
WORD_AT_RE = re.compile(
    r"(?<=\w)\s*(?:\[\s*at\s*\]|\(\s*at\s*\)|\{\s*at\s*\}|\bat\b)\s*(?=\w)",
    re.IGNORECASE,
)
EMAIL_RE = re.compile(r"(?<![\w.+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,63}\b", re.IGNORECASE)
LINK_RE = re.compile(
    r"\b(?:https?|ftp)://[^\s<>\"']+"
    r"|\bwww\.[^\s<>\"']+"
    r"|(?<![@\w./:-])(?:[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?\.)+"
    + TLD_PATTERN + r"\b(?:/[^\s<>\"']*)?",
    re.IGNORECASE,
)
PHONE_RE = re.compile(r"(?<!\w)(?:\+|00)?\d(?:[\s().-]*\d){6,14}(?!\w)")
IPV4_RE = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\d)(?!\.\d)")
TELEGRAM_LINK_RE = re.compile(
    r"\b(?:https?://)?(?:t\.me|telegram\.me|telegram\.dog)/([A-Z][A-Z0-9_]{4,31})\b",
    re.IGNORECASE,
)
TELEGRAM_LABEL_RE = re.compile(
    r"\b(?:telegram|telegram\s+id|tg)\s*[:=\-]?\s*@?([A-Z][A-Z0-9_]{4,31})\b",
    re.IGNORECASE,
)
TELEGRAM_HANDLE_RE = re.compile(r"(?<![A-Z0-9._%+\-])@([A-Z][A-Z0-9_]{4,31})\b", re.IGNORECASE)
CRYPTO_RE = re.compile(
    r"\b(?:"
    r"0x[0-9A-Fa-f]{40}"
    r"|bc1[ac-hj-np-zAC-HJ-NP-Z02-9]{11,71}"
    r"|[13][a-km-zA-HJ-NP-Z1-9]{25,34}"
    r"|T[1-9A-HJ-NP-Za-km-z]{33}"
    r")\b"
)


def normalize_obfuscation(text):
    text = re.sub(
        r"\b(h(?:tt|xx)ps?)\s*:\s*/\s*/\s*",
        lambda match: "https://" if match.group(1).lower().endswith("s") else "http://",
        text,
        flags=re.IGNORECASE,
    )
    text = OBFUSCATED_TLD_RE.sub(
        lambda match: "." + re.sub(r"\s+", "", match.group(0)).lstrip(".").lower(),
        text,
    )
    text = WORD_DOT_RE.sub(".", text)
    text = WORD_AT_RE.sub("@", text)
    text = re.sub(r"(?<=\w)\s*@\s*(?=\w)", "@", text)
    return text


def sorted_unique(values, *, case_insensitive=False):
    if case_insensitive:
        by_key = {}
        for value in values:
            by_key.setdefault(value.casefold(), value)
        values = by_key.values()
    return sorted(set(values), key=str.casefold)


def extract_identifiers(text):
    text = normalize_obfuscation(text)

    emails = sorted_unique((match.group(0).lower() for match in EMAIL_RE.finditer(text)))

    links = []
    for match in LINK_RE.finditer(text):
        link = match.group(0).rstrip(".,;:!?)]}>'\"")
        if link:
            links.append(link)
    links = sorted_unique(links, case_insensitive=True)

    ips = []
    for match in IPV4_RE.finditer(text):
        candidate = match.group(0)
        try:
            ips.append(str(ipaddress.ip_address(candidate)))
        except ValueError:
            pass
    ips = sorted_unique(ips)

    phones = []
    for match in PHONE_RE.finditer(text):
        raw = match.group(0).strip()
        if raw in ips or re.fullmatch(r"\d{4}[-/.]\d{1,2}[-/.]\d{1,2}", raw):
            continue
        digits = re.sub(r"\D", "", raw)
        if not 7 <= len(digits) <= 15:
            continue
        if raw.startswith("+"):
            phones.append("+" + digits)
        elif raw.startswith("00"):
            phones.append("+" + digits[2:])
        else:
            phones.append(digits)
    phones = sorted_unique(phones)

    telegram = {
        "@" + match.group(1).lower()
        for regex in (TELEGRAM_LINK_RE, TELEGRAM_LABEL_RE, TELEGRAM_HANDLE_RE)
        for match in regex.finditer(text)
    }

    identifiers = {
        "phones": phones,
        "emails": emails,
        "links": links,
        "telegram": sorted(telegram),
        "ipAddresses": ips,
        "cryptoAddresses": sorted_unique(CRYPTO_RE.findall(text), case_insensitive=True),
    }
    return {key: value for key, value in identifiers.items() if value}


def load_existing(path):
    if not path:
        return []
    with open(path, encoding="utf-8") as file:
        existing = json.load(file)
    if not isinstance(existing, list):
        raise ValueError(f"expected a JSON array in {path}")
    return existing


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--existing")
    args = parser.parse_args()

    fresh = json.load(sys.stdin)
    if not isinstance(fresh, list):
        raise ValueError("expected a JSON array from PostgreSQL")

    enriched_by_username = {}
    fresh_order = []
    for user in fresh:
        if not isinstance(user, dict) or not isinstance(user.get("username"), str):
            raise ValueError("each PostgreSQL row must be a user object with a username")
        user = dict(user)
        content = user.pop("content", [])
        if not isinstance(content, list):
            raise ValueError(f"expected content array for {user['username']}")
        source_text = "\n".join(
            value for value in [user.get("displayName"), *content] if isinstance(value, str)
        )
        identifiers = extract_identifiers(source_text)
        if identifiers:
            user["identifiers"] = identifiers
        enriched_by_username[user["username"]] = user
        fresh_order.append(user["username"])

    existing = load_existing(args.existing)
    result = []
    seen = set()
    for old_user in existing:
        if not isinstance(old_user, dict) or not isinstance(old_user.get("username"), str):
            raise ValueError("each existing row must be a user object with a username")
        username = old_user["username"]
        if username in enriched_by_username:
            fresh_user = enriched_by_username[username]
            merged_user = {**old_user, **fresh_user}
            if "identifiers" not in fresh_user:
                merged_user.pop("identifiers", None)
            result.append(merged_user)
        else:
            result.append(old_user)
        seen.add(username)

    for username in fresh_order:
        if username not in seen:
            result.append(enriched_by_username[username])

    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
