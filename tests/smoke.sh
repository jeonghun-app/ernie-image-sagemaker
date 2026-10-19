#!/usr/bin/env bash
# Copyright (c) 2026 ernie-image-sagemaker contributors
# SPDX-License-Identifier: Apache-2.0
# Offline smoke test: runs the commands that need no AWS resources against a stub "aws" CLI.
#   bash tests/smoke.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
cat >"$T/bin/aws" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "sts get-caller-identity") echo "123456789012" ;;
  *) echo "stub aws: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/aws"
cp "$ROOT/ernie.sh" "$ROOT/config.env" "$T/"
export PATH="$T/bin:$PATH" HOME="$T/home"
unset AWS_REGION AWS_DEFAULT_REGION
E="$T/ernie.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# help works without a region and shows only the header
out=$("$E" || true)
grep -q "ERNIE-Image on Amazon SageMaker" <<<"$out" || fail "help header"
grep -q "set -euo" <<<"$out" && fail "help prints code"
# a region is required for AWS commands, and can be set without one
"$E" status >/dev/null 2>&1 && fail "status without REGION should fail"
"$E" config set REGION ap-northeast-2 >/dev/null
grep -q '^REGION=ap-northeast-2$' "$T/config.env" || fail "config set REGION"
"$E" config show | grep -q "effective REGION: ap-northeast-2" || fail "config show"
# config validation
"$E" config set NOPE 1 >/dev/null 2>&1 && fail "unknown key accepted"
"$E" config set NAME 'bad value' >/dev/null 2>&1 && fail "invalid value accepted"
# policies are valid JSON with the expected ARNs
"$E" invoke-policy | python3 -m json.tool >/dev/null || fail "invoke-policy JSON"
"$E" invoke-policy vpce-0123456789abcdef0 | python3 -c '
import json, sys
p = json.load(sys.stdin)
assert any(s["Effect"] == "Deny" and s["Condition"]["StringNotEquals"]["aws:SourceVpce"] == "vpce-0123456789abcdef0" for s in p["Statement"])
assert "arn:aws:sagemaker:ap-northeast-2:123456789012:endpoint/ernie-image" in json.dumps(p)
' || fail "invoke-policy with vpce"
"$E" scp-policy vpce-0123456789abcdef0 | python3 -m json.tool >/dev/null || fail "scp-policy JSON"
"$E" scp-policy >/dev/null 2>&1 && fail "scp-policy without vpce should fail"
echo "smoke: all passed"
