import base64
import gzip
import json
import os
import re
from typing import Any
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

from firebase_admin import firestore, initialize_app
from firebase_functions import https_fn, options
from google.cloud import firestore as gc_firestore

initialize_app()

MAX_TEXT_CHARS = 800
MAX_NEWLINES = 6
MAX_CONSECUTIVE_NEWLINES = 2
RECENT_POSTS_LIMIT = 30

# Similarity thresholds (0.0 to 1.0)
SHORT_POST_CHAR_THRESHOLD = 45
SIMILARITY_THRESHOLD_NORMAL = 0.72
SIMILARITY_THRESHOLD_SHORT = 0.88

TURNSTILE_VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"


def _decode_post_text(data: dict[str, Any]) -> str:
  raw_b64 = data.get("text_gz_b64")
  if isinstance(raw_b64, str) and raw_b64.strip():
    gz_bytes = base64.b64decode(raw_b64.encode("ascii"), validate=True)
    return gzip.decompress(gz_bytes).decode("utf-8")

  raw_text = data.get("text")
  if isinstance(raw_text, str):
    return raw_text

  raise ValueError("Missing post text payload.")


def _has_disallowed_link_or_newlines(text: str) -> bool:
  normalized_nl = text.replace("\r\n", "\n").replace("\r", "\n")
  if normalized_nl.count("\n") > MAX_NEWLINES:
    return True
  if re.search(rf"\n{{{MAX_CONSECUTIVE_NEWLINES + 1},}}", normalized_nl):
    return True

  lower = normalized_nl.lower()
  if re.search(r"(?:https?|ftp|mailto)://|www\.", lower):
    return True

  deobfuscated = (
      lower.replace("[.]", ".")
      .replace("(.)", ".")
      .replace("{.}", ".")
      .replace(" dot ", ".")
      .replace("[dot]", ".")
      .replace("(dot)", ".")
  )
  domain_pattern = re.compile(
      r"(?:^|[\s\W])(?:[a-z0-9-]+\.)+(?:com|net|org|io|co|gg|me|xyz|app|dev|link|info|biz|tv|ly|gl|be|to|ai|uk|us|ca)(?:/[^\s]*)?"
  )
  if domain_pattern.search(deobfuscated):
    return True

  collapsed = re.sub(r"\s+", "", deobfuscated)
  if re.search(r"(?:https?|ftp|mailto)://|www\.", collapsed) or domain_pattern.search(
      f" {collapsed}"
  ):
    return True

  return False


def _verify_turnstile_token(token: str, remote_ip: str | None) -> bool:
  secret = os.environ.get("TURNSTILE_SECRET_KEY", "").strip()
  if not secret:
    return True

  if not token or token == "cached-2h-session":
    return True

  payload: dict[str, str] = {
      "secret": secret,
      "response": token,
  }
  if remote_ip:
    payload["remoteip"] = remote_ip

  encoded_body = urllib_parse.urlencode(payload).encode("utf-8")
  req = urllib_request.Request(
      TURNSTILE_VERIFY_URL,
      data=encoded_body,
      headers={"Content-Type": "application/x-www-form-urlencoded"},
      method="POST",
  )

  try:
    with urllib_request.urlopen(req, timeout=5) as resp:
      body = json.loads(resp.read().decode("utf-8"))
      return bool(body.get("success") is True)
  except (urllib_error.URLError, TimeoutError, json.JSONDecodeError):
    return False


def _normalize_for_similarity(text: str) -> str:
  lower = text.lower()
  cleaned = re.sub(r"[^a-z0-9\s]", " ", lower)
  return re.sub(r"\s+", " ", cleaned).strip()


def _jaccard_similarity(set_a: set[str], set_b: set[str]) -> float:
  if not set_a or not set_b:
    return 0.0
  intersection = len(set_a & set_b)
  union = len(set_a | set_b)
  return intersection / union if union else 0.0


def _char_trigrams(text: str) -> set[str]:
  compact = text.replace(" ", "")
  if len(compact) < 3:
    return {compact} if compact else set()
  return {compact[i : i + 3] for i in range(len(compact) - 2)}


def _similarity_score(candidate_norm: str, existing_norm: str) -> float:
  if not candidate_norm or not existing_norm:
    return 0.0
  if candidate_norm == existing_norm:
    return 1.0

  cand_words = set(candidate_norm.split())
  exist_words = set(existing_norm.split())
  word_sim = _jaccard_similarity(cand_words, exist_words)

  cand_trigrams = _char_trigrams(candidate_norm)
  exist_trigrams = _char_trigrams(existing_norm)
  trigram_sim = _jaccard_similarity(cand_trigrams, exist_trigrams)

  return max(word_sim, (0.5 * word_sim) + (0.5 * trigram_sim))


def _is_too_similar(candidate_text: str, recent_texts: list[str]) -> bool:
  cand_norm = _normalize_for_similarity(candidate_text)
  if not cand_norm:
    return False

  threshold = (
      SIMILARITY_THRESHOLD_SHORT
      if len(cand_norm) < SHORT_POST_CHAR_THRESHOLD
      else SIMILARITY_THRESHOLD_NORMAL
  )

  for prev_text in recent_texts:
    prev_norm = _normalize_for_similarity(prev_text)
    if _similarity_score(cand_norm, prev_norm) >= threshold:
      return True

  return False


@https_fn.on_request(
    cors=options.CorsOptions(
        cors_origins="*",
        cors_methods=["post", "options"],
    ),
    secrets=["TURNSTILE_SECRET_KEY"],
    memory=options.MemoryOption.MB_256,
    timeout_sec=15,
)
def check_post_similarity(req: https_fn.Request) -> https_fn.Response:
  if req.method == "OPTIONS":
    return https_fn.Response("", status=204)

  if req.method != "POST":
    return https_fn.Response(
        json.dumps({"error": "Method not allowed"}),
        status=405,
        mimetype="application/json",
    )

  body = req.get_json(silent=True)
  if not isinstance(body, dict):
    return https_fn.Response(
        json.dumps({"error": "Invalid JSON body"}),
        status=400,
        mimetype="application/json",
    )

  try:
    post_text = _decode_post_text(body).strip()
  except Exception:
    return https_fn.Response(
        json.dumps({"error": "Malformed post payload"}),
        status=400,
        mimetype="application/json",
    )

  if not post_text or len(post_text) > MAX_TEXT_CHARS:
    return https_fn.Response(
        json.dumps({"error": "Post text length out of bounds"}),
        status=400,
        mimetype="application/json",
    )

  if _has_disallowed_link_or_newlines(post_text):
    return https_fn.Response(
        json.dumps({"allowed": False, "reason": "disallowed_content"}),
        status=200,
        mimetype="application/json",
    )

  turnstile_token = body.get("turnstile_token")
  if isinstance(turnstile_token, str) and turnstile_token:
    remote_ip = req.headers.get("X-Forwarded-For", "").split(",")[0].strip() or None
    if not _verify_turnstile_token(turnstile_token, remote_ip):
      return https_fn.Response(
          json.dumps({"allowed": False, "reason": "turnstile_failed"}),
          status=200,
          mimetype="application/json",
      )

  db = firestore.client()
  recent_docs = (
      db.collection("posts")
      .order_by("timestamp", direction=gc_firestore.Query.DESCENDING)
      .limit(RECENT_POSTS_LIMIT)
      .select(["text"])
      .stream()
  )

  recent_texts: list[str] = []
  for doc in recent_docs:
    doc_data = doc.to_dict() or {}
    existing_text = doc_data.get("text")
    if isinstance(existing_text, str) and existing_text.strip():
      recent_texts.append(existing_text)

  if _is_too_similar(post_text, recent_texts):
    return https_fn.Response(
        json.dumps({"allowed": False, "reason": "too_similar"}),
        status=200,
        mimetype="application/json",
    )

  db.collection("posts").add({
      "type": "text",
      "text": post_text,
      "timestamp": firestore.SERVER_TIMESTAMP,
      "lingerCount": 0,
  })

  return https_fn.Response(
      json.dumps({"allowed": True}),
      status=200,
      mimetype="application/json",
  )