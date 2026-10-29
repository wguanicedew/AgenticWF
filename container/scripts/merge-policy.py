#!/usr/bin/env python3
"""Merge authsvc route policies into one policy.yaml (written to stdout).

    merge-policy.py kb.yaml agent.yaml auth.yaml > policy.yaml

Rules keep the order of the files given, then their order within each file. A rule whose
(path, methods) an earlier file already has is dropped, so put the most specific source first:
authsvc evaluates the first matching rule. `required_scopes` must agree across files.
"""
import sys

import yaml


def key(rule):
    methods = rule.get("methods")
    return rule["path"], tuple(sorted(m.upper() for m in methods)) if methods else None


def main(paths):
    required, rules, seen = None, [], set()
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh) or {}
        scopes = doc.get("required_scopes")
        if scopes is not None:
            if required is not None and sorted(scopes) != sorted(required):
                sys.exit(f"{path}: required_scopes {scopes} differ from {required}")
            required = scopes
        for rule in doc.get("rules") or []:
            k = key(rule)
            if k not in seen:
                seen.add(k)
                rules.append(rule)

    out = {"required_scopes": required or [], "rules": rules}
    sys.stdout.write(
        "# Generated at image build by merge-policy.py from:\n"
        + "".join(f"#   {p}\n" for p in paths)
        + "# First matching rule wins; requests matching no rule are denied.\n"
        + "# Mount your own file at /etc/agenticwf/policy.yaml to change it.\n\n"
    )
    yaml.safe_dump(out, sys.stdout, sort_keys=False, default_flow_style=None, width=120)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
