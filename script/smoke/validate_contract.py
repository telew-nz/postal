#!/usr/bin/env python3
"""Check recorded API traffic against the OpenAPI document which describes it.

The smoke test (script/smoke/run.rb) drives the API with inputs which are known
to be valid and records every response it receives. This script replays those
recordings against doc/api/openapi.yaml and reports any place where the
implementation and the document disagree:

  * an operation which was called but is not documented
  * a response status which is not documented for that operation
  * a response content type which is not documented for that status
  * a response body which does not validate against the declared schema
  * a documented operation which the smoke test never reached

Schemathesis fuzzes the API to find inputs which break it. This does the
opposite job: it proves that the responses the API gives for *good* input match
what clients have been told to expect. The two are complementary and both are
deterministic, so neither flakes.

Usage:
    validate_contract.py --spec-url http://postal:5000/api/v2/spec \
                         --recordings /shared/recordings.jsonl
    validate_contract.py --spec-path doc/api/openapi.yaml --recordings r.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - the schemathesis image always has it
    sys.exit("PyYAML is required to read the OpenAPI document")

try:
    import jsonschema_rs
except ImportError:  # pragma: no cover
    jsonschema_rs = None

try:
    import jsonschema
except ImportError:  # pragma: no cover
    jsonschema = None

if jsonschema_rs is None and jsonschema is None:
    sys.exit("either jsonschema_rs or jsonschema is required")


# ---------------------------------------------------------------------------
# Loading and $ref resolution
# ---------------------------------------------------------------------------

def load_spec(url: str | None, path: str | None) -> dict:
    if url:
        with urllib.request.urlopen(url, timeout=30) as response:
            return yaml.safe_load(response.read().decode("utf-8"))
    with open(path, "rb") as handle:
        return yaml.safe_load(handle)


def resolve_pointer(document: dict, pointer: str) -> Any:
    """Follow a local JSON pointer such as '#/components/schemas/Session'."""
    if not pointer.startswith("#/"):
        raise KeyError(f"only local JSON pointers can be resolved, got {pointer!r}")

    node: Any = document
    for raw_token in pointer[2:].split("/"):
        token = raw_token.replace("~1", "/").replace("~0", "~")
        node = node[token]
    return node


def inline(node: Any, document: dict, stack: tuple = ()) -> Any:
    """Recursively replace every local $ref with the document it points at.

    JSON Schema validators resolve $ref against the root of the schema they were
    given, but the pointers in an OpenAPI document are relative to the root of
    the whole document. Extracting one response schema and handing it to a
    validator therefore breaks every reference in it, so they are expanded
    here first. Cycles are cut off by leaving the repeated reference opaque.
    """
    if isinstance(node, dict):
        ref = node.get("$ref")
        if isinstance(ref, str) and ref.startswith("#/"):
            if ref in stack:
                # A recursive schema. Validating through it again would not
                # learn anything new, so accept any value at this point.
                return {}
            return inline(resolve_pointer(document, ref), document, stack + (ref,))

        return {key: inline(value, document, stack) for key, value in node.items()}

    if isinstance(node, list):
        return [inline(item, document, stack) for item in node]

    return node


# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------

def schema_errors(schema: dict, instance: Any) -> list[str]:
    """Return a list of ways in which instance does not satisfy schema."""
    if jsonschema_rs is not None:
        try:
            validator = jsonschema_rs.validator_for(schema)
            return [str(error) for error in validator.iter_errors(instance)]
        except Exception as error:  # a schema the validator cannot compile
            return [f"schema could not be compiled: {error}"]

    validator = jsonschema.Draft202012Validator(schema)
    return [
        f"{'/'.join(str(part) for part in error.absolute_path) or '<root>'}: {error.message}"
        for error in validator.iter_errors(instance)
    ]


# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------

class Report:
    def __init__(self) -> None:
        self.checked = 0
        self.failures: list[str] = []
        self.operations_seen: set[tuple[str, str]] = set()

    def fail(self, message: str) -> None:
        self.failures.append(message)

    @property
    def ok(self) -> bool:
        return not self.failures


def documented_operations(document: dict) -> set[tuple[str, str]]:
    verbs = {"get", "put", "post", "delete", "patch", "head", "options", "trace"}
    operations = set()
    for path, item in (document.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        for verb in item:
            if verb.lower() in verbs:
                operations.add((verb.upper(), path))
    return operations


def pick_response(responses: dict, status: int) -> tuple[str, Any] | None:
    """Find the response object which covers this status code."""
    for key in (str(status), f"{status // 100}XX", "default"):
        if key in responses:
            return key, responses[key]
    return None


def is_json_media(content_type: str) -> bool:
    """Whether a media type carries a JSON document rather than raw bytes."""
    return content_type == "application/json" or content_type.endswith("+json")


def media_matches(declared: set[str], content_type: str) -> bool:
    """Whether one of the declared media types covers the one returned.

    `*/*` is how an OpenAPI document says "whatever the resource declares", and
    that is the honest description of an attachment: the API passes the MIME
    type the message part carried straight through to the client.
    """
    return content_type in declared or "*/*" in declared


def check_recording(recording: dict, document: dict, report: Report) -> None:
    method = recording["method"].upper()
    template = recording["path_template"]
    status = int(recording["status"])
    label = f"{method} {template}"

    report.operations_seen.add((method, template))

    path_item = (document.get("paths") or {}).get(template)
    if path_item is None:
        report.checked += 1
        report.fail(f"{label} -> {status}: the path is not in the OpenAPI document")
        return

    operation = path_item.get(method.lower())
    if operation is None:
        report.checked += 1
        report.fail(f"{label} -> {status}: the method is not documented for this path")
        return

    responses = operation.get("responses") or {}
    match = pick_response(responses, status)
    report.checked += 1

    if match is None:
        report.fail(
            f"{label} -> {status}: status is not documented "
            f"(the document declares {', '.join(sorted(responses)) or 'nothing'})"
        )
        return

    key, response = match
    if isinstance(response, dict) and "$ref" in response:
        response = inline(response, document)

    # 204 and other empty responses carry no content by definition.
    content = (response or {}).get("content") or {}
    if not content:
        if (recording["body"] is not None or recording.get("body_text")) and status != 204:
            report.fail(f"{label} -> {status}: the document declares no body but one was returned")
        return

    content_type = (recording.get("content_type") or "").split(";")[0].strip().lower()
    declared_media = {name.lower() for name in content}
    if content_type and not media_matches(declared_media, content_type):
        report.fail(
            f"{label} -> {status}: returned {content_type} "
            f"but the document declares {', '.join(sorted(content))}"
        )
        return

    media = content.get(content_type) or next(iter(content.values()))
    schema = (media or {}).get("schema")
    if schema is None:
        return

    # Two operations answer with the message itself rather than with a document
    # describing it: the raw .eml download and the attachment content. Those
    # were recorded as text instead of as decoded JSON.
    instance = recording["body"] if is_json_media(content_type) else recording.get("body_text")

    if instance is None:
        if schema.get("format") == "binary":
            # A body which was not valid UTF-8 is not recorded at all, so the
            # content type check above is all that can be verified for it.
            return
        report.fail(f"{label} -> {status}: the document declares a schema but the body was empty")
        return

    errors = schema_errors(inline(schema, document), instance)
    if errors:
        detail = "; ".join(errors[:3])
        report.fail(f"{label} -> {key}: body does not match the declared schema: {detail}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--spec-url", help="fetch the OpenAPI document from this URL")
    source.add_argument("--spec-path", help="read the OpenAPI document from this file")
    parser.add_argument("--recordings", required=True, help="JSONL file written by script/smoke/run.rb")
    args = parser.parse_args()

    document = load_spec(args.spec_url, args.spec_path)
    if not str(document.get("openapi", "")).startswith("3."):
        sys.exit(f"expected an OpenAPI 3 document, got openapi={document.get('openapi')!r}")

    recordings = []
    with open(args.recordings, encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                recordings.append(json.loads(line))

    if not recordings:
        sys.exit(f"no recordings were found in {args.recordings}")

    report = Report()
    for recording in recordings:
        check_recording(recording, document, report)

    declared = documented_operations(document)
    unreached = sorted(declared - report.operations_seen)
    unknown = sorted(report.operations_seen - declared)

    print(f"checked {report.checked} recorded responses "
          f"across {len(report.operations_seen & declared)} of {len(declared)} documented operations")

    if unknown:
        print()
        print("Called but not documented:")
        for method, path in unknown:
            print(f"  {method} {path}")

    if unreached:
        print()
        print(f"Documented but not reached by the smoke test ({len(unreached)}):")
        for method, path in unreached:
            print(f"  {method} {path}")

    if report.failures:
        print()
        print(f"Contract failures ({len(report.failures)}):")
        for index, failure in enumerate(report.failures, start=1):
            print(f"  {index}. {failure}")
        print()
        print("FAILED")
        return 1

    print()
    print("PASSED: every recorded response matches the OpenAPI document")
    return 0


if __name__ == "__main__":
    sys.exit(main())
