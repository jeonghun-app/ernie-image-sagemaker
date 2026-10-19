#!/usr/bin/env bash
# Copyright (c) 2026 ernie-image-sagemaker contributors
# SPDX-License-Identifier: Apache-2.0
#
# ERNIE-Image on Amazon SageMaker (real-time endpoint + Inference Components) — install / scale / delete from AWS CloudShell.
#
#   ./ernie.sh check                     read-only: permissions, quota, network, CLI, existing resources
#   ./ernie.sh install                   create (or resume) role, model, endpoint config, endpoint, model copies
#   ./ernie.sh scale <N> [-y]            change to N instances (N x COPIES_PER_INSTANCE model copies)
#                                        scale out: no interruption / scale in: about 5-10 min without service
#   ./ernie.sh status                    endpoint, instances, model copies, recent requests
#   ./ernie.sh test [C] [T]              generate T images with C in flight (default 1 1); saved under ./out/<time>/
#   ./ernie.sh delete [-y] [--role] [--force] [--clean-enis]   delete model copies, endpoint, config, model
#                                        (--role: the IAM role too; --clean-enis: VPC mode, remove leftover SageMaker ENIs)
#   ./ernie.sh config [show | set KEY VALUE]
#   ./ernie.sh subnets [vpc-id]          list subnets: AZ, free IPs, internet route (for SUBNET_IDS)
#   ./ernie.sh invoke-policy [vpce-id]   print the IAM policy for callers (with vpce-id: deny calls not via that endpoint)
#   ./ernie.sh scp-policy <vpce-id>      print an Organizations SCP that denies EVERY principal's call not via that endpoint
#   ./ernie.sh verify-private            from this shell (internet path), confirm that invoking is DENIED (PASS) or not (FAIL)
#   ./ernie.sh update-cli                install the latest AWS CLI v2 into ~/.local (if check says the CLI is too old)
#
# Settings: config.env next to this script (or ERNIE_CONFIG=/path/to/file).
# ERNIE_SKIP_QUOTA_CHECK=1 skips the quota pre-check (only if Service Quotas shows less than SageMaker really allows).
# ERNIE_TEST_PROMPT="..." replaces the built-in Korean prompt used by "./ernie.sh test".
# Exit codes: 0 ok, 1 failed / needs action, 2 unexpected AWS error (nothing is assumed; re-run after fixing).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$HOME/.local/bin/aws" ]] && export PATH="$HOME/.local/bin:$PATH"   # CLI installed by update-cli
CONFIG="${ERNIE_CONFIG:-$DIR/config.env}"
[[ -f "$CONFIG" ]] || { echo "config not found: $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"

REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
if [[ -z "$REGION" ]]; then   # config / help / update-cli work without a region (outside CloudShell: set it first)
  case "${1:-}" in config|update-cli|"") ;; *) echo "REGION is empty: run ./ernie.sh config set REGION <region>" >&2; exit 1 ;; esac
fi
# the CLI retries throttling / transient errors itself
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER="" AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=6
export PYTHONWARNINGS=ignore

NAME="${NAME:-ernie-image}"
INSTANCE_TYPE="${INSTANCE_TYPE:-ml.g6e.12xlarge}"
SUBNET_IDS="${SUBNET_IDS:-}"; SECURITY_GROUP_IDS="${SECURITY_GROUP_IDS:-}"
SCALE_IN_COOLDOWN_MINUTES="${SCALE_IN_COOLDOWN_MINUTES:-5}"; AZ_BALANCE="${AZ_BALANCE:-false}"
MODEL_NAME="$NAME"; EPC_NAME="$NAME-cfg"; EP_NAME="$NAME"; IC_NAME="$NAME-ic"
DLC_ACCOUNT=763104351884
IMAGE="$DLC_ACCOUNT.dkr.ecr.$REGION.amazonaws.com/vllm:$IMAGE_TAG"
QUOTA_NAME="$INSTANCE_TYPE for endpoint usage"
EC2_TYPE="${INSTANCE_TYPE#ml.}"
TAG_KEY="ernie-image:managed-by"; TAG_VAL="ernie.sh/$NAME"
ROLE_TAG_PREFIX="ernie.sh"   # IAM roles are global and may serve several NAMEs/regions: any ernie.sh tag value marks ours
ACCOUNT=""

c_ok() { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; }
c_warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$*"; }
c_fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1m%s\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { c_fail "$*"; exit 1; }
fatal() { c_fail "$*"; echo "         nothing was assumed; fix the cause and run the same command again" >&2; exit 2; }

# ---------------------------------------------------------------- AWS helpers
# aws_get <aws args...>: prints output and returns 0; returns 1 only when the resource does not exist;
# any other error (AccessDenied, expired token, network) stops the script.
aws_get() {
  local out err rc=0
  err=$(mktemp)
  out=$(aws "$@" 2>"$err") || rc=$?
  if (( rc == 0 )); then rm -f "$err"; printf '%s' "$out"; return 0; fi
  if grep -qE "Could not find|does not exist|NoSuchEntity|ResourceNotFound|NotFound\)" "$err"; then rm -f "$err"; return 1; fi
  local msg; msg=$(tr '\n' ' ' <"$err" | cut -c1-400); rm -f "$err"
  fatal "aws $1 $2 failed: $msg"
}

account_id() {
  [[ -n "$ACCOUNT" ]] || ACCOUNT=$(aws_get sts get-caller-identity --query Account --output text)
  echo "$ACCOUNT"
}
arn_endpoint() { echo "arn:aws:sagemaker:$REGION:$(account_id):endpoint/$EP_NAME"; }
arn_epc() { echo "arn:aws:sagemaker:$REGION:$(account_id):endpoint-config/$EPC_NAME"; }
arn_model() { echo "arn:aws:sagemaker:$REGION:$(account_id):model/$MODEL_NAME"; }
arn_ic() { echo "arn:aws:sagemaker:$REGION:$(account_id):inference-component/$IC_NAME"; }
arn_role() {  # the real ARN (with path) when the role exists
  aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || echo "arn:aws:iam::$(account_id):role/$ROLE_NAME"
}

exists_endpoint() { aws_get sagemaker describe-endpoint --endpoint-name "$EP_NAME" --query EndpointName --output text >/dev/null; }
exists_ic() { aws_get sagemaker describe-inference-component --inference-component-name "$IC_NAME" --query InferenceComponentName --output text >/dev/null; }
exists_model() { aws_get sagemaker describe-model --model-name "$MODEL_NAME" --query ModelName --output text >/dev/null; }
exists_epc() { aws_get sagemaker describe-endpoint-config --endpoint-config-name "$EPC_NAME" --query EndpointConfigName --output text >/dev/null; }
exists_role() { aws_get iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text >/dev/null; }

# is_ours <sagemaker arn>: resource carries our tag (created by this script for this NAME)
# get_or_missing VAR <aws args...>: like aws_get but usable for assignment; exits on unexpected errors
get_or_missing() {
  local __var=$1 __out __rc=0; shift
  __out=$(aws_get "$@") || __rc=$?
  (( __rc == 0 )) || { (( __rc == 1 )) && return 1; exit 2; }
  printf -v "$__var" '%s' "$__out"
}
is_ours() {
  local v; get_or_missing v sagemaker list-tags --resource-arn "$1" --query "Tags[?Key=='$TAG_KEY'].Value | [0]" --output text || return 1
  [[ "$v" == "$TAG_VAL" ]]
}
role_is_ours() {
  local v; get_or_missing v iam list-role-tags --role-name "$ROLE_NAME" --query "Tags[?Key=='$TAG_KEY'].Value | [0]" --output text || return 1
  [[ "$v" == "$ROLE_TAG_PREFIX" || "$v" == "$ROLE_TAG_PREFIX/"* ]]
}
# the inference component is ours and attached to our endpoint (otherwise stop: never touch another deployment)
ic_is_ours_or_die() {
  local ep; icf ep EndpointName || return 1
  [[ "$ep" == "$EP_NAME" ]] || die "inference component '$IC_NAME' belongs to endpoint '$ep', not '$EP_NAME': choose another NAME"
  is_ours "$(arn_ic)" || die "inference component '$IC_NAME' was not created by ernie.sh for NAME=$NAME"
  return 0
}
tags_json() { echo "[{\"Key\":\"$TAG_KEY\",\"Value\":\"$TAG_VAL\"}]"; }

# epf VAR QUERY / icf VAR QUERY: field into VAR; return 1 if the resource does not exist; exit 2 on other AWS errors
epf() { get_or_missing "$1" sagemaker describe-endpoint --endpoint-name "$EP_NAME" --query "$2" --output text; }
icf() { get_or_missing "$1" sagemaker describe-inference-component --inference-component-name "$IC_NAME" --query "$2" --output text; }

# one lock per NAME so two shells cannot change the same deployment at once (flock: atomic, released when the process ends)
take_lock() {
  command -v flock >/dev/null || die "flock not found (util-linux; preinstalled in CloudShell)"
  mkdir -p "$HOME/.ernie-locks"
  exec 9>"$HOME/.ernie-locks/$REGION-$NAME.lock"
  flock -n 9 || die "another ernie.sh is changing '$NAME' in $REGION right now; wait for it to finish"
}

# ---------------------------------------------------------------- config validation
int_in() {  # int_in NAME VALUE MIN MAX -> prints the normalized decimal value
  local k=$1 v=$2
  [[ "$v" =~ ^[0-9]{1,4}$ ]] || die "$k must be an integer ($v)"
  v=$((10#$v))
  (( v >= $3 && v <= $4 )) || die "$k must be $3..$4 ($v)"
  echo "$v"
}

validate_config() {
  [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] || die "NAME must be lowercase letters, digits, hyphens, 1-40 chars: $NAME"
  MAX_INSTANCES=$(int_in MAX_INSTANCES "$MAX_INSTANCES" 1 100)
  INSTANCE_COUNT=$(int_in INSTANCE_COUNT "$INSTANCE_COUNT" 1 "$MAX_INSTANCES")
  COPIES_PER_INSTANCE=$(int_in COPIES_PER_INSTANCE "$COPIES_PER_INSTANCE" 1 8)
  SCALE_IN_COOLDOWN_MINUTES=$(int_in SCALE_IN_COOLDOWN_MINUTES "$SCALE_IN_COOLDOWN_MINUTES" 5 1440)
  [[ "$AZ_BALANCE" == "true" || "$AZ_BALANCE" == "false" ]] || die "AZ_BALANCE must be true or false"
  if [[ -n "$SUBNET_IDS" && -z "$SECURITY_GROUP_IDS" ]] || [[ -z "$SUBNET_IDS" && -n "$SECURITY_GROUP_IDS" ]]; then
    die "set both SUBNET_IDS and SECURITY_GROUP_IDS, or leave both empty"
  fi
  [[ -z "$SUBNET_IDS" || "$SUBNET_IDS" =~ ^subnet-[0-9a-f]+(,subnet-[0-9a-f]+)*$ ]] || die "SUBNET_IDS: comma-separated subnet IDs"
  [[ -z "$SECURITY_GROUP_IDS" || "$SECURITY_GROUP_IDS" =~ ^sg-[0-9a-f]+(,sg-[0-9a-f]+)*$ ]] || die "SECURITY_GROUP_IDS: comma-separated sg IDs"
  [[ "$ROLE_NAME" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] || die "ROLE_NAME is not a valid IAM role name"
  if [[ "$INSTANCE_TYPE" == "ml.g6e.12xlarge" ]]; then
    # scale N relies on one copy per GPU, so that N x copies needs exactly N instances
    (( COPIES_PER_INSTANCE == 4 )) || die "ml.g6e.12xlarge has 4 GPUs: COPIES_PER_INSTANCE must be 4 (one copy per GPU)"
  else
    c_warn "INSTANCE_TYPE $INSTANCE_TYPE is not verified (verified: ml.g6e.12xlarge, 4 copies)"
  fi
}

# ---------------------------------------------------------------- check: permissions
caller_arn() { aws_get sts get-caller-identity --query Arn --output text; }

principal_arn() {  # assumed-role/ROLE/session -> role ARN (with path)
  local c=$1
  if [[ "$c" == *":assumed-role/"* ]]; then
    local role="${c#*:assumed-role/}"; role="${role%%/*}"
    aws iam get-role --role-name "$role" --query Role.Arn --output text 2>/dev/null || echo ""
  else
    echo "$c"
  fi
}

# simulate <principal> <resource-arn> <context-json-or-empty> <actions...>; prints denied actions
simulate() {
  local p=$1 res=$2 ctx=$3; shift 3
  local args=(--policy-source-arn "$p" --action-names "$@" --resource-arns "$res")
  [[ -n "$ctx" ]] && args+=(--context-entries "$ctx")
  # shellcheck disable=SC2016  # JMESPath literal, not a shell expansion
  aws iam simulate-principal-policy "${args[@]}" \
    --query 'EvaluationResults[?EvalDecision!=`allowed`].EvalActionName' --output text
}

check_permissions() {
  local c p; c=$(caller_arn)
  if [[ "$c" == *":root" ]]; then c_warn "signed in as root: permission check skipped"; return 0; fi
  p=$(principal_arn "$c")
  if [[ -z "$p" ]]; then c_warn "cannot read your role (iam:GetRole denied): permission check skipped"; return 0; fi
  local acct r denied="" out n=0
  acct=$(account_id); r="arn:aws:sagemaker:$REGION:$acct"
  # every API the script calls, with the resource it calls it on
  local -a groups=(
    "$r:endpoint/$EP_NAME|sagemaker:CreateEndpoint sagemaker:DescribeEndpoint sagemaker:DeleteEndpoint sagemaker:UpdateEndpointWeightsAndCapacities sagemaker:AddTags sagemaker:ListTags"
    "$r:endpoint-config/$EPC_NAME|sagemaker:CreateEndpointConfig sagemaker:DescribeEndpointConfig sagemaker:DeleteEndpointConfig sagemaker:AddTags sagemaker:ListTags"
    "$r:model/$MODEL_NAME|sagemaker:CreateModel sagemaker:DescribeModel sagemaker:DeleteModel sagemaker:AddTags sagemaker:ListTags"
    "$r:inference-component/$IC_NAME|sagemaker:CreateInferenceComponent sagemaker:DescribeInferenceComponent sagemaker:UpdateInferenceComponentRuntimeConfig sagemaker:DeleteInferenceComponent sagemaker:AddTags sagemaker:ListTags"
    "$(arn_role)|iam:GetRole iam:CreateRole iam:PutRolePolicy iam:GetRolePolicy iam:TagRole iam:ListRoleTags iam:DeleteRolePolicy iam:DeleteRole"
    "*|sagemaker:ListEndpoints sagemaker:ListModels sagemaker:ListEndpointConfigs servicequotas:ListServiceQuotas servicequotas:ListAWSDefaultServiceQuotas cloudwatch:GetMetricStatistics ec2:DescribeSubnets ec2:DescribeRouteTables ec2:DescribeSecurityGroups ec2:DescribeInstanceTypeOfferings ec2:DescribeNetworkInterfaces"
  )
  [[ -n "$SUBNET_IDS" ]] && groups+=("*|ec2:DeleteNetworkInterface")
  local g res acts
  for g in "${groups[@]}"; do
    res=${g%%|*}; acts=${g#*|}
    # shellcheck disable=SC2086
    if ! out=$(simulate "$p" "$res" "" $acts 2>&1); then
      c_warn "iam:SimulatePrincipalPolicy not allowed or failed: permission check skipped ($(echo "$out" | head -1 | cut -c1-120))"
      return 0
    fi
    [[ "$out" != "None" && -n "$out" ]] && denied="$denied $out"
    n=$((n + $(wc -w <<<"$acts")))
  done
  # PassRole: on the execution role, to SageMaker only
  out=$(simulate "$p" "$(arn_role)" \
    "ContextKeyName=iam:PassedToService,ContextKeyValues=sagemaker.amazonaws.com,ContextKeyType=string" iam:PassRole 2>&1) || out="iam:PassRole"
  [[ "$out" != "None" && -n "$out" ]] && denied="$denied $out"
  n=$((n + 1))
  # invoking (only ./ernie.sh test uses it from this shell) is reported separately: it may be denied on purpose (7. private only)
  local inv t1 t2
  t1=$(simulate "$p" "$r:endpoint/$EP_NAME" "" sagemaker:InvokeEndpoint 2>/dev/null || echo "sagemaker:InvokeEndpoint")
  t2=$(simulate "$p" "*" "" translate:TranslateText 2>/dev/null || echo "translate:TranslateText")
  inv="${t1/None/} ${t2/None/}"; inv="${inv## }"; inv="${inv%% }"
  if [[ -z "${inv// /}" ]]; then c_ok "test from this shell: allowed (InvokeEndpoint, TranslateText)"
  else c_warn "test from this shell: not allowed ($inv). Fine if invoking is restricted to a VPC endpoint on purpose"; fi
  if [[ -z "${denied// /}" ]]; then
    c_ok "management permissions: $n API calls allowed for $p (identity policies, boundaries and SCPs as simulated by IAM)"
  else
    c_fail "permissions missing for $p:$(tr -s ' \t' '\n' <<<"$denied" | sort -u | tr '\n' ' ')"
    return 1
  fi
}

# ---------------------------------------------------------------- check: quota
# applied quota value, else the AWS default; empty if unreadable.
# (the CLI paginates and applies --query per page, so filter values instead of "| [0]")
get_quota() {
  local v
  v=$(aws service-quotas list-service-quotas --service-code sagemaker \
      --query "Quotas[?QuotaName=='$QUOTA_NAME'].Value" --output text 2>/dev/null | grep -Eo '^[0-9]+' | head -1 || true)
  [[ -n "$v" ]] || v=$(aws service-quotas list-aws-default-service-quotas --service-code sagemaker \
      --query "Quotas[?QuotaName=='$QUOTA_NAME'].Value" --output text 2>/dev/null | grep -Eo '^[0-9]+' | head -1 || true)
  echo "$v"
}

# instances of INSTANCE_TYPE held by OTHER endpoints in this region (max of current/desired, per variant); "" if unreadable
instances_in_use() {
  EXCLUDE="$EP_NAME" ITYPE="$INSTANCE_TYPE" python3 - <<'PY' 2>/dev/null || echo ""
import os, boto3
sm = boto3.client("sagemaker")
total = 0
for page in sm.get_paginator("list_endpoints").paginate():
    for e in page["Endpoints"]:
        name = e["EndpointName"]
        if name == os.environ["EXCLUDE"]:
            continue
        d = sm.describe_endpoint(EndpointName=name)
        def variants(name):
            return {v["VariantName"]: v for v in sm.describe_endpoint_config(EndpointConfigName=name)["ProductionVariants"]}
        cur = variants(d["EndpointConfigName"])
        pend = d.get("PendingDeploymentSummary", {})
        pcfg = variants(pend["EndpointConfigName"]) if pend.get("EndpointConfigName") else cur
        rows = [(v, cur) for v in d.get("ProductionVariants", [])] + [(v, pcfg) for v in pend.get("ProductionVariants", [])]
        for v, cfg in rows:
            c = cfg.get(v.get("VariantName"), {})
            if (v.get("InstanceType") or c.get("InstanceType")) == os.environ["ITYPE"]:
                mis = v.get("ManagedInstanceScaling") or c.get("ManagedInstanceScaling") or {}
                reserved = mis.get("MaxInstanceCount", 0) if mis.get("Status") == "ENABLED" else 0
                total += max(v.get("CurrentInstanceCount") or 0, v.get("DesiredInstanceCount") or 0, reserved)
print(total)
PY
}

check_quota() {  # check_quota <total instances this deployment needs now> <total it may need later>
  local need=$1 later=$2 q used
  if [[ "${ERNIE_SKIP_QUOTA_CHECK:-}" == "1" ]]; then c_warn "quota pre-check skipped (ERNIE_SKIP_QUOTA_CHECK=1): SageMaker decides at create time"; return 0; fi
  q=$(get_quota); used=$(instances_in_use)
  if [[ -z "$q" || -z "$used" ]]; then
    c_fail "cannot read quota '$QUOTA_NAME' or current usage (servicequotas / sagemaker:List* permissions)"; return 1
  fi
  local free=$((q - used))
  if (( free < need )); then
    c_fail "quota '$QUOTA_NAME' = $q, used or reserved by other endpoints = $used, free = $free < $need needed"
    echo "         -> request an increase (Service Quotas > Amazon SageMaker > '$QUOTA_NAME'), or lower MAX_INSTANCES" >&2
    echo "         (SageMaker checks the quota against MAX_INSTANCES when it creates the endpoint)" >&2
    return 1
  elif (( free < later )); then
    c_warn "quota '$QUOTA_NAME' = $q (free $free): enough for $need now; scaling to $later needs a quota increase"
  else
    c_ok "quota '$QUOTA_NAME' = $q (free $free) >= $later"
  fi
}

# ---------------------------------------------------------------- check: network
# route of a subnet: "nat" | "tgw" | "igw" | "none"  (explicitly associated table, else the VPC main table)
subnet_route() {
  SN=$1 python3 - <<'PY' 2>/dev/null || echo "error"
import os, boto3
ec2 = boto3.client("ec2"); sn = os.environ["SN"]
vpc = ec2.describe_subnets(SubnetIds=[sn])["Subnets"][0]["VpcId"]
rts = ec2.describe_route_tables(Filters=[{"Name": "association.subnet-id", "Values": [sn]}])["RouteTables"]
if not rts:
    rts = ec2.describe_route_tables(Filters=[{"Name": "vpc-id", "Values": [vpc]}, {"Name": "association.main", "Values": ["true"]}])["RouteTables"]
kind = "none"
for r in (rts[0]["Routes"] if rts else []):
    if r.get("DestinationCidrBlock") != "0.0.0.0/0" or r.get("State") != "active":
        continue
    kind = "nat" if r.get("NatGatewayId") else "tgw" if r.get("TransitGatewayId") else "igw" if str(r.get("GatewayId", "")).startswith("igw-") else "other"
print(kind)
PY
}

az_offers_type() {  # EC2 offering of the same GPU type in this AZ (a hint; SageMaker capacity is separate)
  local n; n=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
      --filters "Name=location,Values=$1" "Name=instance-type,Values=$EC2_TYPE" --query 'length(InstanceTypeOfferings)' --output text 2>/dev/null || echo "?")
  [[ "$n" == "1" ]] && echo yes || echo no
}

check_network() {
  if [[ -z "$SUBNET_IDS" ]]; then
    c_ok "network: SageMaker-managed (SageMaker chooses AZs; no subnet / IP / NAT planning needed)"
    return 0
  fi
  local rc=0 sn vpc="" azs="" az ip v route nsub per
  nsub=$(tr ',' '\n' <<<"$SUBNET_IDS" | wc -l)
  per=$(( (MAX_INSTANCES * 2 + nsub - 1) / nsub ))
  for sn in ${SUBNET_IDS//,/ }; do
    if ! get_or_missing v ec2 describe-subnets --subnet-ids "$sn" --query 'Subnets[0].[AvailabilityZone,AvailableIpAddressCount,VpcId]' --output text; then
      c_fail "subnet $sn not found in $REGION"; rc=1; continue
    fi
    read -r az ip v <<<"$v"
    [[ -z "$vpc" ]] && vpc=$v
    [[ "$v" == "$vpc" ]] || { c_fail "subnet $sn is in $v, others in $vpc (use one VPC)"; rc=1; }
    route=$(subnet_route "$sn")
    case "$route" in
      nat) c_ok "subnet $sn  $az  free IPs $ip  default route: NAT gateway  ($INSTANCE_TYPE offered in AZ: $(az_offers_type "$az"))" ;;
      tgw) c_warn "subnet $sn  $az  default route: transit gateway -> confirm it reaches the internet (Hugging Face download)" ;;
      igw) c_fail "subnet $sn  $az: public subnet (internet gateway). SageMaker ENIs get no public IP -> use a private subnet with NAT"; rc=1 ;;
      error) c_fail "subnet $sn: cannot read its route table (ec2:DescribeRouteTables)"; rc=1 ;;
      *)   c_fail "subnet $sn  $az: no active 0.0.0.0/0 route -> the model cannot be downloaded from Hugging Face"; rc=1 ;;
    esac
    if (( ip < 2 )); then c_fail "subnet $sn has $ip free IPs"; rc=1
    elif (( ip < per )); then c_warn "subnet $sn has $ip free IPs; plan about $per per subnet for $MAX_INSTANCES instances"; fi
    [[ " $azs " == *" $az "* ]] || azs="$azs $az"
  done
  if (( $(wc -w <<<"$azs") < 2 )); then c_warn "subnets cover one AZ ($azs): instances can start only there. Add a subnet in another AZ"
  else c_ok "subnets cover $(wc -w <<<"$azs") AZs:$azs"; fi
  # security groups: rules add up across groups; only 0.0.0.0/0 counts (a prefix list may be S3-only)
  local res
  res=$(SGS=$SECURITY_GROUP_IDS VPC=$vpc python3 - <<'PY' 2>/dev/null || echo "error"
import os, boto3
gs = boto3.client("ec2").describe_security_groups(GroupIds=os.environ["SGS"].split(","))["SecurityGroups"]
bad = [g["GroupId"] for g in gs if g["VpcId"] != os.environ["VPC"]]
ok = False
for g in gs:
    for p in g.get("IpPermissionsEgress", []):
        proto = p.get("IpProtocol")
        port_ok = proto == "-1" or (proto == "tcp" and p.get("FromPort", 0) <= 443 <= p.get("ToPort", 65535))
        ok = ok or (port_ok and any(x.get("CidrIp") == "0.0.0.0/0" for x in p.get("IpRanges", [])))
print(("vpc-mismatch:" + ",".join(bad)) if bad else ("443-ok" if ok else "443-missing"))
PY
)
  case "$res" in
    443-ok) c_ok "security groups $SECURITY_GROUP_IDS: outbound HTTPS 443 to 0.0.0.0/0 allowed" ;;
    443-missing) c_fail "security groups $SECURITY_GROUP_IDS: no outbound HTTPS 443 to 0.0.0.0/0 (needed via NAT for the model download)"; rc=1 ;;
    vpc-mismatch*) c_fail "security groups not in $vpc: ${res#vpc-mismatch:}"; rc=1 ;;
    *) c_fail "security groups $SECURITY_GROUP_IDS: cannot read (not found or no ec2:DescribeSecurityGroups)"; rc=1 ;;
  esac
  return $rc
}

cmd_subnets() {
  local vpc=${1:-} filt=()
  [[ -n "$vpc" ]] && filt=(--filters "Name=vpc-id,Values=$vpc")
  printf '  %-26s %-22s %-16s %8s  %-6s %s\n' SUBNET VPC AZ FREE_IP ROUTE "$EC2_TYPE-in-AZ"
  aws ec2 describe-subnets "${filt[@]}" --query 'Subnets[].[SubnetId,VpcId,AvailabilityZone,AvailableIpAddressCount]' --output text |
  sort -k2,2 -k3,3 | while read -r sn v az ip; do
    printf '  %-26s %-22s %-16s %8s  %-6s %s\n' "$sn" "$v" "$az" "$ip" "$(subnet_route "$sn")" "$(az_offers_type "$az")"
  done
  echo "  ROUTE: nat = usable (private subnet with NAT), tgw = check internet via TGW, igw = public subnet (not usable), none = no internet"
}

check_cli() {
  if aws sagemaker create-endpoint-config --generate-cli-skeleton input 2>/dev/null | grep -q ScaleInPolicy \
     && aws sagemaker create-inference-component --generate-cli-skeleton input 2>/dev/null | grep -q SchedulingConfig \
     && aws sagemaker create-endpoint-config --generate-cli-skeleton input 2>/dev/null | grep -q '"VpcConfig"'; then
    c_ok "AWS CLI $(aws --version 2>&1 | cut -d' ' -f1 | cut -d/ -f2) supports the required options"
  else
    c_fail "AWS CLI $(aws --version 2>&1 | cut -d' ' -f1) is too old. Run: ./ernie.sh update-cli"; return 1
  fi
  python3 -c "import boto3" 2>/dev/null || { c_fail "python3 with boto3 is required (preinstalled in CloudShell)"; return 1; }
}

check_existing() {
  local rc=0
  if exists_endpoint; then
    local st; epf st EndpointStatus || st="?"
    if is_ours "$(arn_endpoint)"; then c_warn "endpoint '$EP_NAME' exists ($st): install resumes or refuses; use scale/delete"
    else c_fail "endpoint '$EP_NAME' exists but was not created by ernie.sh for NAME=$NAME: choose another NAME"; rc=1; fi
  else c_ok "endpoint name '$EP_NAME' is free"; fi
  if exists_role; then
    if role_is_ours; then c_ok "role '$ROLE_NAME' exists (created by ernie.sh; policy refreshed on install)"
    else
      local ra miss="" o acct2; ra=$(arn_role); acct2=$(account_id)
      local -a need=(
        "*|ecr:GetAuthorizationToken"
        "arn:aws:ecr:$REGION:$DLC_ACCOUNT:repository/vllm|ecr:BatchCheckLayerAvailability ecr:GetDownloadUrlForLayer ecr:BatchGetImage"
        "arn:aws:logs:$REGION:$acct2:log-group:/aws/sagemaker/Endpoints/$EP_NAME:*|logs:CreateLogStream logs:PutLogEvents"
      )
      [[ -n "$SUBNET_IDS" ]] && need+=("*|ec2:CreateNetworkInterface ec2:CreateNetworkInterfacePermission ec2:DeleteNetworkInterface ec2:DeleteNetworkInterfacePermission ec2:DescribeNetworkInterfaces ec2:DescribeVpcs ec2:DescribeDhcpOptions ec2:DescribeSubnets ec2:DescribeSecurityGroups")
      local g
      for g in "${need[@]}"; do
        # shellcheck disable=SC2086
        o=$(simulate "$ra" "${g%%|*}" "" ${g#*|} 2>/dev/null || echo "${g#*|}")
        [[ "$o" == "None" ]] || miss="$miss $o"
      done
      if [[ "$miss" == "None" || -z "${miss// /}" ]]; then
        c_warn "role '$ROLE_NAME' exists and was not created by ernie.sh: reused as is (image pull in $REGION allowed), never deleted"
      else
        c_fail "role '$ROLE_NAME' (not created by ernie.sh) cannot do: $miss in $REGION. Use another ROLE_NAME, or add these permissions"; rc=1
      fi
    fi
  else c_ok "role '$ROLE_NAME' will be created"; fi
  return $rc
}

cmd_check() {
  validate_config
  info "check (read-only) in $REGION"
  local c; c=$(caller_arn)
  c_ok "caller: $c (account $(account_id))"
  local rc=0
  check_cli || rc=1
  command -v flock >/dev/null || { c_fail "flock not found (util-linux)"; rc=1; }
  check_permissions || rc=1
  # SageMaker checks the quota against MaxInstanceCount when it creates the endpoint (observed: "request delta of 10" for max 10)
  if ! exists_endpoint; then check_quota "$MAX_INSTANCES" "$MAX_INSTANCES" || rc=1; fi
  check_network || rc=1
  check_existing || rc=1
  if aws translate translate-text --text "테스트" --source-language-code ko --target-language-code en >/dev/null 2>&1; then
    c_ok "Amazon Translate available"
  else c_warn "Amazon Translate call failed (needed by ./ernie.sh test and by your application)"; fi
  printf '\n  plan: %s x %s, %s model copies, scale range 1..%s instances\n' "$INSTANCE_COUNT" "$INSTANCE_TYPE" \
    "$((INSTANCE_COUNT * COPIES_PER_INSTANCE))" "$MAX_INSTANCES"
  (( rc == 0 )) && echo "  result: ready" || echo "  result: fix the [FAIL] items"
  return $rc
}

# endpoints (other than ours) that use EPC_NAME now or in a pending update; prints "?" when it cannot be determined
epc_users() {
  CFG=$EPC_NAME EP=$EP_NAME python3 - <<'PY' 2>/dev/null || echo "?"
import os, boto3
sm = boto3.client("sagemaker"); out = []
for page in sm.get_paginator("list_endpoints").paginate():
    for e in page["Endpoints"]:
        if e["EndpointName"] == os.environ["EP"]:
            continue
        d = sm.describe_endpoint(EndpointName=e["EndpointName"])
        if os.environ["CFG"] in (d.get("EndpointConfigName"), d.get("PendingDeploymentSummary", {}).get("EndpointConfigName")):
            out.append(e["EndpointName"])
print(" ".join(out))
PY
}

# ---------------------------------------------------------------- install
# execution-role policy (valid in every region: IAM roles are global)
role_policy() {
  local acct; acct=$(account_id)
  cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:GetDownloadUrlForLayer","ecr:BatchGetImage"],
  "Resource":"arn:aws:ecr:*:$DLC_ACCOUNT:repository/vllm"},
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams"],
  "Resource":"arn:aws:logs:*:$acct:log-group:/aws/sagemaker/*"},
 {"Effect":"Allow","Action":"cloudwatch:PutMetricData","Resource":"*","Condition":{"StringLike":{"cloudwatch:namespace":"/aws/sagemaker/*"}}},
 {"Effect":"Allow","Action":["ec2:CreateNetworkInterface","ec2:CreateNetworkInterfacePermission","ec2:DeleteNetworkInterface",
  "ec2:DeleteNetworkInterfacePermission","ec2:DescribeNetworkInterfaces","ec2:DescribeVpcs","ec2:DescribeDhcpOptions",
  "ec2:DescribeSubnets","ec2:DescribeSecurityGroups"],"Resource":"*"}]}
EOF
}

# refresh_role_if_ours: the role the MODEL actually uses gets the current policy if ernie.sh created it.
# Called BEFORE anything is removed, so a refusal (e.g. no iam:PutRolePolicy) stops with the service untouched.
refresh_role_if_ours() {
  local mr; get_or_missing mr sagemaker describe-model --model-name "$MODEL_NAME" --query ExecutionRoleArn --output text || return 0
  local rn=${mr##*/}
  if [[ "$rn" != "$ROLE_NAME" ]]; then c_warn "model uses role '$rn' (not ROLE_NAME '$ROLE_NAME'): left as is"; return 0; fi
  if exists_role && role_is_ours; then
    aws_get iam put-role-policy --role-name "$ROLE_NAME" --policy-name sagemaker-hosting --policy-document "$(role_policy)" >/dev/null
    c_ok "role '$ROLE_NAME' policy refreshed"
  fi
}

ensure_role() {
  local acct; acct=$(account_id)
  local policy; policy=$(role_policy)
  if exists_role; then
    ROLE_ARN=$(aws_get iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
    if role_is_ours; then
      aws_get iam put-role-policy --role-name "$ROLE_NAME" --policy-name sagemaker-hosting --policy-document "$policy" >/dev/null
      c_ok "role: $ROLE_ARN (ernie.sh role, policy refreshed)"
    else
      aws_get iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json | grep -q sagemaker.amazonaws.com \
        || die "role '$ROLE_NAME' cannot be assumed by sagemaker.amazonaws.com"
      c_warn "role: $ROLE_ARN (existing, not created by ernie.sh: make sure it allows ECR pull from $DLC_ACCOUNT, logs$([[ -n "$SUBNET_IDS" ]] && echo ", VPC ENIs"))"
    fi
    return
  fi
  local trust
  trust="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sagemaker.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$acct\"}}}]}"
  ROLE_ARN=$(aws_get iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$trust" \
      --description "SageMaker execution role for ERNIE-Image endpoints (ernie.sh)" --tags "Key=$TAG_KEY,Value=$ROLE_TAG_PREFIX" --query Role.Arn --output text)
  aws_get iam put-role-policy --role-name "$ROLE_NAME" --policy-name sagemaker-hosting --policy-document "$policy" >/dev/null
  c_ok "role created: $ROLE_ARN (waiting 20 s for IAM propagation)"
  sleep 20
}

wait_endpoint() {  # wait_endpoint [timeout-min]
  local lim=${1:-60} st="" why i
  for (( i = 1; i <= lim * 2; i++ )); do
    epf st EndpointStatus || die "endpoint '$EP_NAME' disappeared"
    case "$st" in
      InService) c_ok "endpoint InService"; return 0 ;;
      Failed) epf why FailureReason || why="?"; die "endpoint failed: $why. Run ./ernie.sh delete, then install" ;;
    esac
    (( i % 4 == 1 )) && info "endpoint $st ..."
    sleep 30
  done
  die "endpoint not InService after $lim min (status $st); check ./ernie.sh status later"
}

wait_copies() {  # wait_copies <copies> [timeout-min]
  local want=$1 lim=${2:-90} out st cur inst why i
  for (( i = 1; i <= lim * 2; i++ )); do
    icf out '[InferenceComponentStatus,RuntimeConfig.CurrentCopyCount]' || die "model copies '$IC_NAME' disappeared"
    read -r st cur <<<"$out"
    epf inst 'ProductionVariants[0].CurrentInstanceCount' || die "endpoint '$EP_NAME' disappeared"
    [[ "$st" == "InService" && "$cur" == "$want" ]] && { c_ok "model copies $cur/$want, instances $inst"; return 0; }
    if [[ "$st" == "Failed" ]]; then icf why FailureReason || why="?"; die "model copies failed: $why"; fi
    (( i % 4 == 1 )) && info "model copies $st $cur/$want, instances $inst ..."
    sleep 30
  done
  die "model copies did not reach $want after $lim min (GPU capacity or quota); check ./ernie.sh status later"
}

wait_instances() {  # wait_instances <n> [timeout-min]: 0 when InService with exactly n instances, 1 on timeout
  local n=$1 lim=${2:-20} out st inst why i
  for (( i = 1; i <= lim * 3; i++ )); do
    epf out '[EndpointStatus,ProductionVariants[0].CurrentInstanceCount]' || die "endpoint '$EP_NAME' disappeared"
    read -r st inst <<<"$out"
    [[ "$st" == "InService" && "$inst" == "$n" ]] && return 0
    if [[ "$st" == "Failed" ]]; then epf why FailureReason || why="?"; die "endpoint failed: $why"; fi
    (( i % 6 == 1 )) && info "endpoint $st, instances $inst -> $n ..."
    sleep 20
  done
  return 1
}

wait_gone() {  # wait_gone <exists-function> <label> [timeout-min]
  local f=$1 label=$2 lim=${3:-30} i
  for (( i = 1; i <= lim * 4; i++ )); do
    "$f" || { c_ok "$label deleted"; return 0; }
    sleep 15
  done
  die "$label still exists after $lim min; check the SageMaker console and run delete again"
}

create_copies() {  # create_copies <copies>
  local copies=$1 imb=100
  [[ "$AZ_BALANCE" == "true" ]] && imb=1
  aws_get sagemaker create-inference-component --inference-component-name "$IC_NAME" --endpoint-name "$EP_NAME" \
    --variant-name AllTraffic --runtime-config "CopyCount=$copies" --tags "Key=$TAG_KEY,Value=$TAG_VAL" --specification "$(cat <<EOF
{"ModelName":"$MODEL_NAME","ComputeResourceRequirements":{"NumberOfAcceleratorDevicesRequired":1,"NumberOfCpuCoresRequired":4,
 "MinMemoryRequiredInMb":32768},"StartupParameters":{"ModelDataDownloadTimeoutInSeconds":1800,
 "ContainerStartupHealthCheckTimeoutInSeconds":1800},
 "SchedulingConfig":{"PlacementStrategy":"BINPACK","AvailabilityZoneBalance":{"EnforcementMode":"PERMISSIVE","MaxImbalance":$imb}}}
EOF
)" >/dev/null
  info "model copies starting: $copies (model download + load, about 5-10 min)"
  wait_copies "$copies"
  local n=$((copies / COPIES_PER_INSTANCE))
  if wait_instances "$n" 15; then c_ok "instances $n"
  else local x; epf x 'ProductionVariants[0].CurrentInstanceCount' || x="?"; c_warn "instances $x (expected $n): check ./ernie.sh status"; return 1; fi
}

cmd_install() {
  validate_config
  take_lock
  cmd_check || die "fix the [FAIL] items above, then run install again"
  echo
  if exists_endpoint; then
    is_ours "$(arn_endpoint)" || die "endpoint '$EP_NAME' was not created by ernie.sh for NAME=$NAME"
    if exists_ic; then
      ic_is_ours_or_die
      local ics; icf ics InferenceComponentStatus || ics=""
      [[ "$ics" == "Failed" ]] || die "endpoint '$EP_NAME' and its model copies already exist. Use ./ernie.sh scale N, or ./ernie.sh delete"
      c_warn "model copies are in state Failed: removing them to start again"
      refresh_role_if_ours
      aws_get sagemaker delete-inference-component --inference-component-name "$IC_NAME" >/dev/null
      wait_gone exists_ic "failed model copies" 20
    fi
    c_warn "endpoint '$EP_NAME' exists without model copies (an earlier install or scale stopped): resuming"
    wait_endpoint
    refresh_role_if_ours
    local inst; epf inst 'ProductionVariants[0].CurrentInstanceCount' || die "endpoint disappeared"
    create_copies $((inst * COPIES_PER_INSTANCE))
    echo; cmd_status; return 0
  fi

  info "install: $INSTANCE_COUNT x $INSTANCE_TYPE, $((INSTANCE_COUNT * COPIES_PER_INSTANCE)) model copies"
  ensure_role

  # model and endpoint config are recreated with the current settings (only ours; never someone else's)
  if exists_ic; then die "inference component '$IC_NAME' already exists (attached elsewhere?): choose another NAME"; fi
  if exists_model; then
    is_ours "$(arn_model)" || die "model '$MODEL_NAME' exists and was not created by ernie.sh: choose another NAME"
    aws_get sagemaker delete-model --model-name "$MODEL_NAME" >/dev/null
  fi
  aws_get sagemaker create-model --model-name "$MODEL_NAME" --execution-role-arn "$ROLE_ARN" --tags "$(tags_json)" \
    --primary-container "$(cat <<EOF
{"Image":"$IMAGE","Environment":{"HF_MODEL_ID":"$MODEL_ID","SM_VLLM_MODEL":"$MODEL_ID","SM_VLLM_TENSOR_PARALLEL_SIZE":"1",
 "SM_VLLM_GPU_MEMORY_UTILIZATION":"0.9","SM_VLLM_DTYPE":"auto","MAX_BATCH_SIZE":"1","MAX_CONCURRENT_REQUESTS":"2",
 "SAGEMAKER_MODEL_SERVER_TIMEOUT":"3600","HF_HUB_ENABLE_HF_TRANSFER":"1"}}
EOF
)" >/dev/null
  c_ok "model: $MODEL_NAME ($MODEL_ID)"

  if exists_epc; then
    is_ours "$(arn_epc)" || die "endpoint config '$EPC_NAME' exists and was not created by ernie.sh: choose another NAME"
    local users; users=$(epc_users)
    [[ -z "$users" ]] || die "endpoint config '$EPC_NAME' is used by endpoint(s) ${users}: choose another NAME"
    aws_get sagemaker delete-endpoint-config --endpoint-config-name "$EPC_NAME" >/dev/null
  fi
  local vpcargs=()
  if [[ -n "$SUBNET_IDS" ]]; then
    vpcargs=(--vpc-config "{\"Subnets\":[\"${SUBNET_IDS//,/\",\"}\"],\"SecurityGroupIds\":[\"${SECURITY_GROUP_IDS//,/\",\"}\"]}")
  fi
  aws_get sagemaker create-endpoint-config --endpoint-config-name "$EPC_NAME" --execution-role-arn "$ROLE_ARN" \
    --tags "$(tags_json)" "${vpcargs[@]}" --production-variants "$(cat <<EOF
[{"VariantName":"AllTraffic","InstanceType":"$INSTANCE_TYPE","InitialInstanceCount":$INSTANCE_COUNT,
  "ModelDataDownloadTimeoutInSeconds":1800,"ContainerStartupHealthCheckTimeoutInSeconds":1800,
  "RoutingConfig":{"RoutingStrategy":"LEAST_OUTSTANDING_REQUESTS"},
  "ManagedInstanceScaling":{"Status":"ENABLED","MinInstanceCount":1,"MaxInstanceCount":$MAX_INSTANCES,
    "ScaleInPolicy":{"Strategy":"CONSOLIDATION","MaximumStepSize":$MAX_INSTANCES,"CooldownInMinutes":$SCALE_IN_COOLDOWN_MINUTES}}}]
EOF
)" >/dev/null
  c_ok "endpoint config: $EPC_NAME (instances 1..$MAX_INSTANCES$([[ -n "$SUBNET_IDS" ]] && echo ", VPC subnets $SUBNET_IDS"))"

  aws_get sagemaker create-endpoint --endpoint-name "$EP_NAME" --endpoint-config-name "$EPC_NAME" --tags "$(tags_json)" >/dev/null
  info "endpoint creating (observed about 3 min)"
  wait_endpoint
  create_copies $((INSTANCE_COUNT * COPIES_PER_INSTANCE))
  echo; cmd_status
  local c=$((INSTANCE_COUNT * COPIES_PER_INSTANCE))
  echo; echo "  Next: warm up with ./ernie.sh test $c $((c * 6))   (first images after a start are slow)"
}

# ---------------------------------------------------------------- scale
recent_invocations() {  # requests to the model copies in the last 5 minutes ("?" if unknown)
  local v
  v=$(aws cloudwatch get-metric-statistics --namespace AWS/SageMaker --metric-name Invocations \
      --dimensions "Name=InferenceComponentName,Value=$IC_NAME" --statistics Sum --period 300 \
      --start-time "$(date -u -d '-5 min' +%FT%TZ 2>/dev/null || date -u -v-5M +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
      --query 'sum(Datapoints[].Sum)' --output text 2>/dev/null || echo "?")
  [[ "$v" == "None" ]] && v=0
  echo "${v%.*}"
}

cmd_scale() {
  validate_config
  local n="" yes=0 a
  for a in "$@"; do case "$a" in -y) yes=1 ;; *) n=$a ;; esac; done
  [[ -n "$n" ]] || die "usage: ./ernie.sh scale <instances> [-y]"
  take_lock
  exists_endpoint || die "endpoint '$EP_NAME' not found (run install first)"
  is_ours "$(arn_endpoint)" || die "endpoint '$EP_NAME' was not created by ernie.sh for NAME=$NAME"
  local cfgname mx; epf cfgname EndpointConfigName || die "endpoint disappeared"
  get_or_missing mx sagemaker describe-endpoint-config --endpoint-config-name "$cfgname" \
      --query 'ProductionVariants[0].ManagedInstanceScaling.MaxInstanceCount' --output text || die "endpoint config '$cfgname' not found"
  [[ "$mx" =~ ^[0-9]+$ ]] || die "this endpoint has no managed instance scaling (not created by this script version)"
  n=$(int_in instances "$n" 1 "$mx")
  local st; epf st EndpointStatus || die "endpoint disappeared"
  [[ "$st" == "InService" ]] || wait_endpoint 30
  local cur copies=$((n * COPIES_PER_INSTANCE))
  epf cur 'ProductionVariants[0].CurrentInstanceCount' || die "endpoint disappeared"
  if ic_is_ours_or_die; then   # failed copies cannot be updated: remove them and restore (recovery path below)
    local ics; icf ics InferenceComponentStatus || ics=""
    if [[ "$ics" == "Failed" ]]; then
      c_warn "model copies are in state Failed: removing them, then restoring $n instances"
      refresh_role_if_ours
      aws_get sagemaker delete-inference-component --inference-component-name "$IC_NAME" >/dev/null
      wait_gone exists_ic "failed model copies" 20
    fi
  fi

  if ! ic_is_ours_or_die; then   # recovery: an earlier scale or install stopped after removing the copies
    c_warn "no model copies on '$EP_NAME' (an earlier run stopped): restoring $n instances with $copies copies"
    if (( n < cur )); then
      aws_get sagemaker update-endpoint-weights-and-capacities --endpoint-name "$EP_NAME" \
        --desired-weights-and-capacities "VariantName=AllTraffic,DesiredInstanceCount=$n" >/dev/null
      wait_instances "$n" 30 || die "instances did not reach $n; run ./ernie.sh scale $n again"
    elif (( n > cur )); then
      # with no copies, SageMaker would release added instances again; starting the copies makes it add them
      check_quota "$n" "$n" || die "not enough quota for $n instances"
    fi
    refresh_role_if_ours
    create_copies "$copies"
    echo; cmd_status
    return 0
  fi

  if (( n >= cur )); then
    if (( n > cur )); then check_quota "$n" "$n" || die "not enough quota for $n instances"; fi
    info "scale out: instances $cur -> $n, model copies -> $copies (existing copies keep serving)"
    aws_get sagemaker update-inference-component-runtime-config --inference-component-name "$IC_NAME" \
      --desired-runtime-config "CopyCount=$copies" >/dev/null
    wait_copies "$copies"
    if wait_instances "$n" 15; then c_ok "instances $n"
    else local x; epf x 'ProductionVariants[0].CurrentInstanceCount' || x="?"; c_warn "copies are $copies but instances are $x (target $n): check ./ernie.sh status"; return 1; fi
    (( n > cur )) && echo "  Next: warm up the new copies: ./ernie.sh test $copies $((copies * 6))"
    return 0
  fi

  # scale in: SageMaker does not release an instance while copies are spread over it (observed: copies 8 -> 4 kept
  # 2 instances for 30+ min). So the copies are removed, the instance count is lowered, and the copies start again.
  local rq; rq=$(recent_invocations)
  echo "  scale in: instances $cur -> $n, model copies -> $copies"
  echo "  WARNING: image generation is UNAVAILABLE for about 5-10 minutes while the model copies restart."
  echo "           Stop sending requests first. Requests in the last 5 minutes: $rq"
  if (( ! yes )); then
    read -r -p "  type 'yes' to continue: " a
    [[ "$a" == "yes" ]] || die "cancelled"
  fi
  refresh_role_if_ours   # before removing anything
  info "removing model copies ..."
  aws_get sagemaker delete-inference-component --inference-component-name "$IC_NAME" >/dev/null
  wait_gone exists_ic "model copies" 20
  aws_get sagemaker update-endpoint-weights-and-capacities --endpoint-name "$EP_NAME" \
    --desired-weights-and-capacities "VariantName=AllTraffic,DesiredInstanceCount=$n" >/dev/null \
    || die "could not lower the instance count. Run ./ernie.sh scale $n again (it restores the copies)"
  info "releasing instances $cur -> $n ..."
  wait_instances "$n" 30 || die "instances did not reach $n. Run ./ernie.sh scale $n again (it restores the copies)"
  c_ok "instances $n"
  create_copies "$copies"
  echo "  Next: warm up: ./ernie.sh test $copies $((copies * 6))"
}

# ---------------------------------------------------------------- status
cmd_status() {
  if ! exists_endpoint; then echo "  endpoint '$EP_NAME' not found in $REGION (no endpoint charges)"; return 0; fi
  local es inst cfg mn mx out
  epf out '[EndpointStatus,ProductionVariants[0].CurrentInstanceCount,EndpointConfigName]' || { echo "  endpoint '$EP_NAME' not found"; return 0; }
  read -r es inst cfg <<<"$out"
  get_or_missing out sagemaker describe-endpoint-config --endpoint-config-name "$cfg" \
      --query 'ProductionVariants[0].ManagedInstanceScaling.[MinInstanceCount,MaxInstanceCount]' --output text || out="? ?"
  read -r mn mx <<<"$out"
  echo "  region            : $REGION"
  local mark=""; is_ours "$(arn_endpoint)" || mark="  [not created by ernie.sh]"
  echo "  endpoint          : $EP_NAME ($es)$mark"
  echo "  instances         : $inst x $INSTANCE_TYPE (scale range $mn..$mx)"
  if exists_ic; then
    local s cur want icep
    icf out '[InferenceComponentStatus,RuntimeConfig.CurrentCopyCount,RuntimeConfig.DesiredCopyCount,EndpointName]' || out="? ? ? ?"
    read -r s cur want icep <<<"$out"
    [[ "$icep" == "$EP_NAME" ]] || echo "  [WARN] '$IC_NAME' is attached to endpoint '$icep', not '$EP_NAME'"
    echo "  model copies      : $IC_NAME ($s) $cur (desired $want)  -> keep concurrent requests <= $cur"
    echo "  requests (5 min)  : $(recent_invocations)"
  else
    echo "  model copies      : none  -> image generation unavailable; run ./ernie.sh install (resumes) or ./ernie.sh scale N"
  fi
  if [[ "$REGION" == "ap-northeast-2" && "$INSTANCE_TYPE" == "ml.g6e.12xlarge" && "$inst" =~ ^[0-9]+$ ]]; then
    echo "  cost (on-demand)  : about \$$(awk -v n="$inst" 'BEGIN{printf "%.2f", n*16.13}')/hour while the endpoint exists (Seoul list price, endpoint only)"
  fi
  echo "  invoke            : EndpointName=$EP_NAME InferenceComponentName=$IC_NAME CustomAttributes=route=/v1/images/generations"
}

# ---------------------------------------------------------------- test
cmd_test() {
  ic_is_ours_or_die || die "no model copies on '$EP_NAME'"
  local c t; c=$(int_in concurrency "${1:-1}" 1 200); t=$(int_in total "${2:-1}" 1 2000)
  local out; out="$DIR/out/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
  EP_NAME="$EP_NAME" IC_NAME="$IC_NAME" OUT_DIR="$out" C="$c" T="$t" python3 - <<'PY'
import base64, concurrent.futures as cf, json, os, statistics, sys, time
import boto3
from botocore.config import Config
# ERNIE_TEST_PROMPT overrides the built-in Korean test prompt (translated ko -> en like an application would)
prompt = os.environ.get("ERNIE_TEST_PROMPT") or (
    "16:9 가로형 풍경 사진. 해 질 녘 바닷가 언덕 위에 하얀 등대가 서 있고, 주황빛 하늘 아래로 잔잔한 파도가 친다. "
    "사실적인 사진 스타일, 부드러운 빛. 이미지 안에는 글자, 로고, 워터마크를 넣지 않는다.")
tr = boto3.client("translate")
sm = boto3.client("sagemaker-runtime", config=Config(read_timeout=65, retries={"max_attempts": 0}, max_pool_connections=64))
en = tr.translate_text(Text=prompt, SourceLanguageCode="ko", TargetLanguageCode="en")["TranslatedText"]
def one(i):
    t = time.time()
    try:
        r = sm.invoke_endpoint(EndpointName=os.environ["EP_NAME"], InferenceComponentName=os.environ["IC_NAME"],
                               ContentType="application/json", CustomAttributes="route=/v1/images/generations",
                               Body=json.dumps({"prompt": en, "size": "1344x768", "n": 1, "num_inference_steps": 10,
                                                "guidance_scale": 4.0, "seed": i}))
        png = base64.b64decode(json.loads(r["Body"].read())["data"][0]["b64_json"])
        if png[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("not a PNG")
        open(os.path.join(os.environ["OUT_DIR"], "img_%04d.png" % i), "wb").write(png)
        return "ok", time.time() - t, ""
    except Exception as e:
        return type(e).__name__, time.time() - t, str(e)[:300]
C, T = int(os.environ["C"]), int(os.environ["T"])
t0 = time.time()
with cf.ThreadPoolExecutor(C) as ex:
    res = list(ex.map(one, range(1, T + 1)))
wall = time.time() - t0
ok = sorted(s for c, s, _ in res if c == "ok")
codes = {}
for c, _, _ in res:
    codes[c] = codes.get(c, 0) + 1
print(f"  in-flight={C} total={T} results={codes} wall={wall:.1f}s images/min={len(ok) / wall * 60:.1f}")
if ok:
    print(f"  latency p50={statistics.median(ok):.1f}s max={ok[-1]:.1f}s  saved: {os.environ['OUT_DIR']}/")
errs = [(c, m) for c, _, m in res if c != "ok"]
for c, m in errs[:3]:
    print("  error:", c, m)
sys.exit(1 if errs else 0)
PY
}

# ---------------------------------------------------------------- delete
cmd_delete() {
  local yes=0 role=0 force=0 clean_enis=0 deleted_ep=0 a
  for a in "$@"; do case "$a" in -y) yes=1 ;; --role) role=1 ;; --force) force=1 ;; --clean-enis) clean_enis=1 ;; *) die "unknown option $a" ;; esac; done
  take_lock
  echo "  delete in $REGION: model copies $IC_NAME, endpoint $EP_NAME, config $EPC_NAME, model $MODEL_NAME$( (( role )) && echo ", role $ROLE_NAME")"
  if exists_endpoint && (( ! force )); then
    is_ours "$(arn_endpoint)" || die "endpoint '$EP_NAME' was not created by ernie.sh for NAME=$NAME (use --force only if you are sure)"
  fi
  if (( ! yes )); then
    read -r -p "  type the endpoint name ($EP_NAME) to confirm: " a
    [[ "$a" == "$EP_NAME" ]] || die "cancelled"
  fi
  if exists_ic; then
    if (( ! force )); then ic_is_ours_or_die; fi
    aws_get sagemaker delete-inference-component --inference-component-name "$IC_NAME" >/dev/null
    info "deleting model copies ..."; wait_gone exists_ic "model copies" 30
  fi
  if exists_endpoint; then
    aws_get sagemaker delete-endpoint --endpoint-name "$EP_NAME" >/dev/null
    info "deleting endpoint ..."; wait_gone exists_endpoint "endpoint" 30
    deleted_ep=1
  fi
  local refs=""
  exists_epc && refs=$(epc_users)
  if exists_epc && [[ -n "$refs" ]]; then
    c_warn "endpoint config '$EPC_NAME' kept: used by endpoint(s) $refs"
  elif exists_epc; then
    if (( force )) || is_ours "$(arn_epc)"; then aws_get sagemaker delete-endpoint-config --endpoint-config-name "$EPC_NAME" >/dev/null; c_ok "endpoint config deleted"
    else c_warn "endpoint config '$EPC_NAME' kept (not created by ernie.sh)"; fi
  fi
  if exists_model; then
    if (( force )) || is_ours "$(arn_model)"; then aws_get sagemaker delete-model --model-name "$MODEL_NAME" >/dev/null; c_ok "model deleted"
    else c_warn "model '$MODEL_NAME' kept (not created by ernie.sh)"; fi
  fi
  # VPC mode: SageMaker leaves this endpoint's network interfaces behind as "available" (observed: over an hour).
  # Removed only when this run deleted our endpoint (ownership checked above) or with --clean-enis,
  # and only ENIs described as this endpoint's, in the configured subnets.
  if [[ -n "$SUBNET_IDS" ]] && (( deleted_ep || clean_enis )); then
    local eni_out
    eni_out=$(EP=$EP_NAME SUBNETS=$SUBNET_IDS python3 - <<'PY' 2>/dev/null || echo "eni check failed (ec2:DescribeNetworkInterfaces / DeleteNetworkInterface)"
import os, time, boto3
ec2 = boto3.client("ec2")
flt = [{"Name": "description", "Values": ["SageMaker managed ENI for endpoint " + os.environ["EP"] + " *"]},
       {"Name": "subnet-id", "Values": os.environ["SUBNETS"].split(",")}]
deleted, left = [], []
for i in range(30):
    enis = ec2.describe_network_interfaces(Filters=flt)["NetworkInterfaces"]
    left = [e["NetworkInterfaceId"] for e in enis if e["Status"] != "available"]
    for e in enis:
        if e["Status"] == "available":
            ec2.delete_network_interface(NetworkInterfaceId=e["NetworkInterfaceId"]); deleted.append(e["NetworkInterfaceId"])
    if not left:
        break
    time.sleep(30)
print(("deleted " + " ".join(deleted) if deleted else "") + ((" still in use: " + " ".join(left)) if left else ""))
PY
)
    case "$eni_out" in
      "") ;;
      *"still in use"*|*failed*) c_warn "VPC network interfaces: $eni_out (later: ./ernie.sh delete -y --clean-enis)" ;;
      *) c_ok "VPC network interfaces left by SageMaker: $eni_out" ;;
    esac
  elif [[ -n "$SUBNET_IDS" ]]; then
    c_warn "leftover SageMaker ENIs of an endpoint deleted earlier are not touched; to remove them: ./ernie.sh delete -y --clean-enis"
  fi

  if (( role )) && exists_role; then
    local users
    users=$(ROLE=$(arn_role) EP=$EP_NAME python3 - <<'PY' 2>/dev/null || echo "?"
import os, boto3
sm = boto3.client("sagemaker"); role = os.environ["ROLE"]; found = []
for page in sm.get_paginator("list_models").paginate():
    for m in page["Models"]:
        if sm.describe_model(ModelName=m["ModelName"]).get("ExecutionRoleArn") == role:
            found.append("model:" + m["ModelName"])
for page in sm.get_paginator("list_endpoint_configs").paginate():
    for c in page["EndpointConfigs"]:
        if sm.describe_endpoint_config(EndpointConfigName=c["EndpointConfigName"]).get("ExecutionRoleArn") == role:
            found.append("endpoint-config:" + c["EndpointConfigName"])
enis = boto3.client("ec2").describe_network_interfaces(
    Filters=[{"Name": "description", "Values": ["SageMaker managed ENI for endpoint " + os.environ["EP"] + "*"]}])["NetworkInterfaces"]
found += ["eni:" + e["NetworkInterfaceId"] for e in enis]
print(" ".join(found))
PY
)
    if [[ -n "$users" ]]; then
      c_warn "role '$ROLE_NAME' kept: still referenced in $REGION by $users (VPC ENIs are released by SageMaker later; run delete --role again then)"
    elif role_is_ours; then
      aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name sagemaker-hosting 2>/dev/null || true
      aws_get iam delete-role --role-name "$ROLE_NAME" >/dev/null && c_ok "role deleted"
    else c_warn "role '$ROLE_NAME' kept (not created by ernie.sh)"; fi
  fi
  # final verification (NotFound only counts as gone)
  local left=""
  exists_ic && left="$left model-copies"
  exists_endpoint && left="$left endpoint"
  if [[ -n "$left" ]]; then c_fail "still present:$left"; return 1; fi
  c_ok "endpoint and model copies are gone: endpoint charges stopped"
}

# ---------------------------------------------------------------- invoke-policy
cmd_invoke_policy() {
  # Identity policy for the caller (e.g. the EKS Pod role). With a VPC endpoint ID, an explicit Deny rejects
  # InvokeEndpoint requests that do not come through that interface endpoint, even if another policy allows them.
  local vpce=${1:-} acct; acct=$(account_id)
  local res="\"arn:aws:sagemaker:$REGION:$acct:endpoint/$EP_NAME\", \"arn:aws:sagemaker:$REGION:$acct:inference-component/$IC_NAME\""
  local deny=""
  if [[ -n "$vpce" ]]; then
    [[ "$vpce" =~ ^vpce-[0-9a-f]+$ ]] || die "usage: ./ernie.sh invoke-policy [vpce-id]"
    deny=$(cat <<EOF
,
    {
      "Sid": "DenyInvokeOutsideVpcEndpoint",
      "Effect": "Deny",
      "Action": ["sagemaker:InvokeEndpoint", "sagemaker:InvokeEndpointWithResponseStream", "sagemaker:InvokeEndpointAsync"],
      "Resource": [$res],
      "Condition": {"StringNotEquals": {"aws:SourceVpce": "$vpce"}}
    }
EOF
)
  fi
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeErnieImage",
      "Effect": "Allow",
      "Action": "sagemaker:InvokeEndpoint",
      "Resource": [$res]
    },
    {
      "Sid": "TranslatePrompt",
      "Effect": "Allow",
      "Action": "translate:TranslateText",
      "Resource": "*"
    }$deny
  ]
}
EOF
}

# ---------------------------------------------------------------- scp-policy
cmd_scp_policy() {
  # Service control policy (AWS Organizations): denies invoking this endpoint for EVERY principal in the account
  # (including administrators) unless the request comes through the given VPC interface endpoint.
  local vpce=${1:-} acct; acct=$(account_id)
  [[ "$vpce" =~ ^vpce-[0-9a-f]+$ ]] || die "usage: ./ernie.sh scp-policy <vpce-id>"
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyErnieInvokeOutsideVpcEndpoint",
      "Effect": "Deny",
      "Action": ["sagemaker:InvokeEndpoint", "sagemaker:InvokeEndpointWithResponseStream", "sagemaker:InvokeEndpointAsync"],
      "Resource": [
        "arn:aws:sagemaker:$REGION:$acct:endpoint/$EP_NAME",
        "arn:aws:sagemaker:$REGION:$acct:inference-component/$IC_NAME"
      ],
      "Condition": {"StringNotEquals": {"aws:SourceVpce": "$vpce"}}
    }
  ]
}
EOF
}

# ---------------------------------------------------------------- verify-private
cmd_verify_private() {
  # Calls InvokeEndpoint from THIS shell (CloudShell = internet path, not through your VPC endpoint).
  # PASS = AccessDenied by an explicit deny. FAIL = the call was accepted (the endpoint can be invoked from outside your VPC).
  EP_NAME="$EP_NAME" IC_NAME="$IC_NAME" python3 - <<'PY'
import json, os, sys, boto3
from botocore.config import Config
from botocore.exceptions import ClientError
sm = boto3.client("sagemaker-runtime", config=Config(read_timeout=65, retries={"max_attempts": 0}))
try:
    sm.invoke_endpoint(EndpointName=os.environ["EP_NAME"], InferenceComponentName=os.environ["IC_NAME"], ContentType="application/json",
                       CustomAttributes="route=/v1/images/generations",
                       Body=json.dumps({"prompt": "blank", "size": "1024x768", "n": 1, "num_inference_steps": 4}))
    print("  \033[31m[FAIL]\033[0m this shell could invoke the endpoint: calls outside your VPC endpoint are NOT blocked for this identity")
    sys.exit(1)
except ClientError as e:
    code, msg = e.response["Error"]["Code"], str(e)
    if code == "AccessDeniedException" and "explicit deny" in msg:
        print("  \033[32m[PASS]\033[0m invoking from this shell is denied by an explicit deny (" + ("service control policy" if "service control policy" in msg else "IAM policy") + ")")
        sys.exit(0)
    print("  \033[33m[CHECK]\033[0m call failed but not by an explicit deny: " + msg[:250])
    sys.exit(1)
PY
}

# ---------------------------------------------------------------- update-cli
cmd_update_cli() {
  local arch tmp
  case "$(uname -m)" in x86_64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) die "unsupported CPU $(uname -m)" ;; esac
  command -v unzip >/dev/null || die "unzip not found"
  tmp=$(mktemp -d)
  info "downloading the latest AWS CLI v2 ($arch) ..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$arch.zip" -o "$tmp/awscliv2.zip"
  (cd "$tmp" && unzip -q awscliv2.zip && ./aws/install -i "$HOME/.local/aws-cli" -b "$HOME/.local/bin" --update >/dev/null)
  rm -rf "$tmp"
  c_ok "installed $("$HOME/.local/bin/aws" --version 2>&1 | cut -d' ' -f1) at $HOME/.local/bin (ernie.sh uses it automatically)"
}

# ---------------------------------------------------------------- config
cmd_config() {
  case "${1:-show}" in
    show) grep -E '^[A-Z_]+=' "$CONFIG" | sed 's/^/  /'; echo "  (effective REGION: $REGION)" ;;
    set)
      local k=${2:-} v=${3-}
      if ! [[ "$k" =~ ^[A-Z_]+$ ]] || ! grep -qE "^$k=" "$CONFIG"; then die "unknown key: $k (see ./ernie.sh config show)"; fi
      [[ "$v" =~ ^[A-Za-z0-9._,:/@+=-]*$ ]] || die "invalid characters in value: $v"
      local tmp; tmp=$(mktemp)
      awk -v k="$k" -v v="$v" 'index($0, k"=") == 1 {print k"="v; next} {print}' "$CONFIG" >"$tmp" && cat "$tmp" >"$CONFIG" && rm -f "$tmp"
      c_ok "$k=$v"
      if [[ "$k" == "INSTANCE_COUNT" ]] && exists_endpoint; then c_warn "endpoint exists: INSTANCE_COUNT is used only by install. Use ./ernie.sh scale $v"; fi
      ;;
    *) die "usage: ./ernie.sh config [show | set KEY VALUE]" ;;
  esac
}

case "${1:-}" in
  config|update-cli|"") ;;
  *) ACCOUNT=$(aws_get sts get-caller-identity --query Account --output text) || exit 2 ;;
esac
case "${1:-}" in
  check) cmd_check ;;
  install) cmd_install ;;
  scale) shift; cmd_scale "$@" ;;
  status) cmd_status ;;
  test) shift; cmd_test "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  config) shift; cmd_config "$@" ;;
  subnets) shift; cmd_subnets "$@" ;;
  invoke-policy) shift; cmd_invoke_policy "$@" ;;
  scp-policy) shift; cmd_scp_policy "$@" ;;
  verify-private) cmd_verify_private ;;
  update-cli) cmd_update_cli ;;
  *) sed -n '5,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
