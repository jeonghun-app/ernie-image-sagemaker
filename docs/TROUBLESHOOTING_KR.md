<!-- Copyright (c) 2026 ernie-image-sagemaker contributors -->
<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# 문제 해결

`ernie.sh`는 문제를 만나면 원인을 추정하지 않고 멈춥니다. 원인을 고친 뒤 **같은 명령을 다시 실행**하면 남은 단계부터 이어서 진행합니다.

종료 코드는 두 가지로 구분합니다.
- `1`: 조치가 필요하다는 뜻입니다. 메시지에 조치 방법이 나옵니다.
- `2`: 예상하지 못한 AWS 오류입니다. 권한 거부, 토큰 만료, 네트워크 문제 등이며, `nothing was assumed`가 함께 표시됩니다.

## 증상별 조치

| # | 증상 | 가능성 높은 원인 | 조치 |
|---|---|---|---|
| 1 | caller가 `AWSCloud9SSMAccessRole` 같은 인스턴스 역할 | EC2/Cloud9의 인스턴스 역할로 실행 중 | CloudShell 사용, 또는 작업 사용자 자격 증명 설정([작업 절차서 부록 C-3](RUNBOOK_KR.md#c-3-작업-사용자-자격-증명-사용)) |
| 2 | `python3 with boto3 is required` | boto3 없음(CloudShell 밖) | `python3 -m pip install --user boto3` |
| 3 | `Connection was closed ... iam.amazonaws.com` | 프라이빗 서브넷이라 공용 API 경로가 없음 | CloudShell로 전환, 또는 NAT/프록시 경로 확보([부록 C-1](RUNBOOK_KR.md#c-1-네트워크-확인-진행-가능-여부-판단)) |
| 4 | `REGION is empty` | CloudShell 밖이라 리전이 자동으로 정해지지 않음 | `./ernie.sh config set REGION <리전>` |
| 5 | `cannot read your role (iam:GetRole denied)` | 작업 역할에 IAM 조회 권한 없음 | [WARN]이라 진행은 되지만 권한 점검이 생략됨. [`operator-policy.json`](../policies/operator-policy.json)의 권한을 관리자에게 요청 |
| 6 | `permissions missing for ...` | 작업 사용자/역할 권한 부족 | 표시된 동작과 [`operator-policy.json`](../policies/operator-policy.json)을 관리자에게 전달 |
| 7 | `iam create-role failed: AccessDenied`(install 중) | SCP·권한 경계로 IAM 역할 생성 금지(AWS Control Tower 계정에서 흔함) | 관리자가 실행 역할을 미리 생성 → `check` 재실행([아래](#iam-역할-생성이-막힌-계정-관리자가-실행-역할을-미리-만들기)) |
| 8 | `quota ... free = 0 < N needed` 또는 `cannot read quota` | 쿼터 미승인 / 조회 권한 없음 | 쿼터 증설 요청 또는 `MAX_INSTANCES`를 낮춤. 실제 한도를 확인했다면 `ERNIE_SKIP_QUOTA_CHECK=1 ./ernie.sh install` |
| 9 | `ResourceLimitExceeded` ("request delta of N") | 쿼터가 `MAX_INSTANCES`보다 작음(SageMaker는 최대 대수로 쿼터를 확인) | `./ernie.sh delete -y` → `config set MAX_INSTANCES <쿼터 이하>` → `install` |
| 10 | `model copies did not reach ... (GPU capacity or quota)` | 리전의 GPU 용량 부족 | 15~30분 후 `./ernie.sh install`(또는 같은 `scale N`) 재실행. 계속되면 대수를 줄임 |
| 11 | `model copies failed: ...`(이미지 내려받기 권한 등) | 실행 역할에 이 리전의 ECR 이미지 권한이 없음, 모델 내려받기 경로 없음(VPC 모드) | 메시지대로 고친 뒤 `install` 재실행(실패한 복제본을 지우고 다시 만듦). 이 도구가 만들지 않은 역할이면 [`execution-role-policy.json`](../policies/execution-role-policy.json)과 비교 |
| 12 | 종료 코드 2, `nothing was assumed` | 토큰 만료·일시 네트워크 오류·권한 거부 | 다시 로그인/자격 증명 갱신 → 같은 명령 재실행 |
| 13 | `UnauthorizedOperation` / 특정 리전 거부 | SCP 리전 제한 | 그 리전이 허용 리전인지 관리자에게 확인 |
| 14 | `test`가 `AccessDenied` | 퍼블릭 차단(SCP/정책) 적용 상태 또는 Invoke 권한 없음 | 의도된 차단이면 정상 → `verify-private`로 확인하고, 예열은 VPC 안에서 |
| 15 | `test`에서 첫 회 1건 정도 실패, 첫 응답이 40~60초 | 설치·증감 직후 콜드 상태 | `test`를 한 번 더 실행해 예열. 이후 정상 |
| 16 | 응답이 점점 느려지고 60초에 타임아웃 | 동시 호출 수가 복제본 수(대수 × 4)를 넘음 | 애플리케이션의 동시 호출 상한을 낮추거나 `scale`로 대수를 늘림 |
| 17 | `another ernie.sh is changing ...` | 같은 배포를 다른 창에서 변경 중 | 그 창의 작업이 끝날 때까지 대기 |
| 18 | `delete` 후 서브넷·보안 그룹을 지울 수 없음 | VPC 모드에서 SageMaker ENI가 남아 있음 | 잠시 후 `./ernie.sh delete -y --clean-enis` |
| 19 | CloudShell 아이콘이 없음 / 열리지 않음 | SCP로 CloudShell 차단, 또는 CloudShell을 지원하지 않는 리전 | 다른 리전의 CloudShell 사용(`config set REGION`으로 대상 리전 지정), 또는 [부록 C](RUNBOOK_KR.md#부록-c-cloudshell-밖ec2-cloud9-로컬-linux에서-실행할-때) |

## IAM 역할 생성이 막힌 계정: 관리자가 실행 역할을 미리 만들기

관리자 권한이 있는 셸에서 저장소 폴더 안에서 실행합니다. 템플릿의 `<ACCOUNT_ID>`를 이 계정 ID로 바꿔 씁니다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME=ernie-image-sagemaker-role      # config.env의 ROLE_NAME과 같게
sed "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" policies/execution-role-trust.json  > /tmp/ernie-trust.json
sed "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" policies/execution-role-policy.json > /tmp/ernie-role-policy.json

aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/ernie-trust.json
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name sagemaker-hosting --policy-document file:///tmp/ernie-role-policy.json
```

- 권한 경계가 필수인 계정이면 `create-role`에 `--permissions-boundary <지정 ARN>`을 추가합니다.
- 내 VPC 서브넷을 쓰지 않으면 `execution-role-policy.json`의 마지막 문장(`ec2:*NetworkInterface*` 등)은 빼도 됩니다.
- 그 뒤 작업자는 `./ernie.sh check`를 실행합니다. `role '<ROLE_NAME>' exists and was not created by ernie.sh: reused as is`가 [FAIL] 없이 지나가면 `install`을 진행합니다.
- 이렇게 만든 역할은 `delete --role`이 지우지 않습니다(이 도구가 만든 역할이 아니므로). 필요하면 관리자가 삭제합니다.

## 작업자 최소 권한 정책 만들기

[`policies/operator-policy.json`](../policies/operator-policy.json)은 `ernie.sh`가 호출하는 관리 API를 이 배포의 리소스로만 좁힌 정책입니다. `check`가 시뮬레이션하는 동작 목록과 같습니다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -e "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" -e "s/<REGION>/ap-northeast-2/g" \
    -e "s/<NAME>/ernie-image/g" -e "s/<ROLE_NAME>/ernie-image-sagemaker-role/g" \
    policies/operator-policy.json > /tmp/ernie-operator-policy.json
```

| 문장(Sid) | 필요한 경우 |
|---|---|
| `SageMakerOnThisDeployment`, `ExecutionRole`, `PassRoleToSageMakerOnly`, `ReadOnlyChecks` | 항상 |
| `VpcModeOnlyLeftoverEniCleanup` | `SUBNET_IDS`를 지정할 때만(삭제 후 남은 ENI 정리) |
| `OptionalTestFromShell` | CloudShell에서 `./ernie.sh test`를 쓸 때만. 퍼블릭 차단을 적용할 계정이면 빼는 것이 좋습니다 |

- 이미 만든 실행 역할을 쓰고(`iam:CreateRole` 금지 계정), 역할 삭제도 하지 않는다면 `ExecutionRole` 문장에는 `iam:GetRole`, `iam:ListRoleTags`만 남겨도 됩니다.
- `iam:SimulatePrincipalPolicy`가 없으면 `check`가 권한 점검을 건너뛰고 [WARN]을 표시합니다(설치는 가능).
