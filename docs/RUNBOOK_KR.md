<!-- Copyright (c) 2026 ernie-image-sagemaker contributors -->
<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# 작업 절차서 — ERNIE-Image SageMaker 엔드포인트 설치·확인·전달

처음 설치하는 사람이 **위에서 아래로 따라가기만 하면** 되도록 만든 체크리스트입니다. 명령과 설정의 상세 설명은 [README](../README.md), 오류별 조치는 [문제 해결](TROUBLESHOOTING_KR.md)에 있습니다.

| 항목 | 내용 |
|---|---|
| 작업 | AWS 계정에 ERNIE-Image SageMaker 실시간 엔드포인트 설치·확인·전달 |
| 도구 | AWS 콘솔 + AWS CloudShell(작업 PC에는 웹 브라우저만 있으면 됨). CloudShell을 쓸 수 없으면 **부록 C** |
| 만드는 리소스 | SageMaker 실행 역할, 모델, 엔드포인트 구성, 엔드포인트, 모델 복제본(Inference Component). Lambda·API Gateway·S3·공개 URL은 만들지 않음 |
| 예상 소요 | 점검 5분 + 설치 약 8~15분 + 예열·확인 약 5분. 퍼블릭 차단을 함께 하면 30분 이상 더 걸리고, 조직 관리자 작업이 필요함 |
| 비용 | 엔드포인트가 있는 동안 대당 약 $16.13/시간(서울 온디맨드, 엔드포인트만, 2026-10 기준) |

> 표기
> - ☐ 체크 항목
> - `$`로 시작하는 줄은 CloudShell에 입력할 명령
> - ▶ 정상일 때 보이는 출력
> - ✖ 멈추고 확인할 상황

---

## 0. 작업 전까지 준비

| ☐ | 할 일 | 비고 |
|---|---|---|
| ☐ | 작업할 계정과 리전 확정 | `ml.g6e.12xlarge` SageMaker 엔드포인트·Amazon Translate가 있는 리전(서울·도쿄 검증) |
| ☐ | 작업 사용자/역할의 권한 확인 | SageMaker 관리, IAM 역할 생성(`PassRole` 포함), Service Quotas 조회. 최소 권한: [`policies/operator-policy.json`](../policies/operator-policy.json) |
| ☐ | IAM 역할을 만들 수 없는 계정인지 확인 | SCP·권한 경계로 역할 생성이 막혀 있으면, 관리자가 실행 역할을 미리 만듭니다([문제 해결](TROUBLESHOOTING_KR.md#iam-역할-생성이-막힌-계정-관리자가-실행-역할을-미리-만들기)) |
| ☐ | 쿼터 확인·증설 요청 | `ml.g6e.12xlarge for endpoint usage` 값 ≥ **최대 대수**(아래 표의 `MAX_INSTANCES`). 승인까지 며칠 걸릴 수 있음 |
| ☐ | 대수 확정 | 시작 대수 `INSTANCE_COUNT`, 최대 대수 `MAX_INSTANCES`(쿼터 이내). 1대 = 모델 복제본 4개 ≈ 분당 약 10장(10 steps) |
| ☐ | 퍼블릭 차단 여부 확정 | 적용한다면 애플리케이션 VPC의 `sagemaker.runtime` VPC 엔드포인트 ID, SCP를 적용할 조직 관리자 일정 |
| ☐ | 작업 후 상태 합의 | 엔드포인트를 **켜 둘지 / 끌지**. 켜 두면 그때부터 비용이 계속 발생함 |

설정값 기록란 (3단계에서 사용)

| 키 | 값 |
|---|---|
| REGION | ______________ (비워 두면 CloudShell 리전 사용) |
| NAME | ernie-image (기본값 권장) |
| INSTANCE_COUNT | ______ |
| MAX_INSTANCES | ______ (쿼터 ______ 이하) |
| 퍼블릭 차단 | 적용 / 미적용, VPC 엔드포인트 ID: vpce-______________ |

---

## 1. 접속과 준비 (약 5분)

### 1-1. 콘솔 로그인과 계정 확인
- ☐ AWS 콘솔에 로그인
- ☐ 오른쪽 위 **계정 ID가 작업 대상 계정**인지 확인
- ☐ 리전을 작업할 리전으로 선택

### 1-2. CloudShell 열기
- ☐ 콘솔 상단의 CloudShell 아이콘(`>_`)을 클릭하고, 프롬프트가 뜰 때까지 기다림(처음이면 1~2분)
  ```
  $ aws sts get-caller-identity --query '[Account,Arn]' --output text
  ```
  ▶ 계정 ID와 로그인한 사용자/역할이 출력됨. 1-1과 같은 계정인지 확인
  ✖ CloudShell이 아닌 곳(EC2, Cloud9 등)이라면 **부록 C**를 먼저 따릅니다

### 1-3. 저장소 받기
  ```
  $ git clone https://github.com/jeonghun-app/ernie-image-sagemaker.git
  $ cd ernie-image-sagemaker
  $ ./ernie.sh | head -3
  ```
  ▶ 첫 줄에 `ERNIE-Image on Amazon SageMaker ... from AWS CloudShell.`
  - GitHub에 접속할 수 없는 환경이면 ZIP을 받아 **작업 → 파일 업로드**로 올립니다.
    ```
    $ unzip -o ernie-image-sagemaker-main.zip && cd ernie-image-sagemaker-main && chmod +x ernie.sh
    ```
  - 특정 버전으로 작업하려면 `git checkout v1.0.0`처럼 태그를 고릅니다. 작업 기록에 커밋(`git rev-parse --short HEAD`)을 남겨 두면 나중에 확인하기 쉽습니다.

---

## 2. (퍼블릭 차단을 적용하는 경우만) 설치 전에 먼저 적용 (30분 이상)

적용하지 않으면 3단계로 바로 갑니다.

- ☐ 2-1. 애플리케이션 VPC에 인터페이스 엔드포인트 `com.amazonaws.<리전>.sagemaker.runtime`을 만들고 **프라이빗 DNS**를 켬. ID(`vpce-...`) 기록
- ☐ 2-2. SCP 정책을 출력해 조직 관리자에게 전달하고, 이 계정에 적용
  ```
  $ ./ernie.sh scp-policy vpce-xxxxxxxxxxxxxxxxx > ernie-scp.json && cat ernie-scp.json
  ```
- ☐ 2-3. 애플리케이션 역할(예: EKS Pod 역할)에 붙일 정책을 출력해 담당자에게 전달
  ```
  $ ./ernie.sh invoke-policy vpce-xxxxxxxxxxxxxxxxx > ernie-invoke-policy.json && cat ernie-invoke-policy.json
  ```
- 참고
  - SCP는 엔드포인트가 아직 없어도 적용할 수 있습니다. 대상 ARN이 이름으로 정해지기 때문입니다.
  - 설치·증감·삭제는 관리 API라서 SCP의 차단 대상이 아닙니다.
  - 출력한 JSON 파일은 CloudShell **작업 → 파일 다운로드**로 받아 전달합니다.

---

## 3. 설정 (약 2분)

  ```
  $ ./ernie.sh config set REGION <리전>              # CloudShell 리전과 같으면 생략 가능
  $ ./ernie.sh config set INSTANCE_COUNT <시작 대수>
  $ ./ernie.sh config set MAX_INSTANCES <최대 대수>
  $ ./ernie.sh config show
  ```
  ▶ `INSTANCE_COUNT=…`, `MAX_INSTANCES=…`, 마지막 줄 `(effective REGION: <리전>)` 확인

---

## 4. 점검 — 아무것도 만들지 않음 (약 2분)

  ```
  $ ./ernie.sh check
  ```
  ▶ 마지막 줄이 `result: ready`이면 5단계로 갑니다
  ✖ `result: fix the [FAIL] items`이면 아래 표대로 조치한 뒤 `check`를 다시 실행합니다

| [FAIL] 메시지 (앞부분) | 원인 | 조치 |
|---|---|---|
| `permissions missing for ...: <동작 목록>` | 작업 사용자/역할 권한 부족 | 표시된 동작을 관리자에게 요청([`operator-policy.json`](../policies/operator-policy.json)) |
| `quota ... free = X < Y needed` | 쿼터가 최대 대수보다 작음 | `MAX_INSTANCES`를 쿼터 이하로 낮추거나 쿼터 증설 |
| `cannot read quota ...` | Service Quotas 조회 권한 없음 | `servicequotas:ListServiceQuotas` 권한 요청 |
| `role '...' (not created by ernie.sh) cannot do: ...` | 같은 이름의 기존 역할에 권한 부족 | `./ernie.sh config set ROLE_NAME ernie-image-sagemaker-role-2`처럼 새 이름 지정 |
| `endpoint '...' exists but was not created by ernie.sh` | 같은 이름의 다른 엔드포인트 존재 | `./ernie.sh config set NAME ernie-image-2`처럼 새 이름 지정 |
| `AWS CLI ... is too old` | CLI가 오래됨 | `./ernie.sh update-cli` 후 `check` 재실행 |
| `subnet ... public subnet` 등 서브넷 항목 | 서브넷을 지정한 경우의 네트워크 문제 | 기본 방식(서브넷 미지정)이면 나오지 않음. 지정했다면 [README 5장](../README.md#5-서브넷과-az--영향이-있나요) |

[WARN]이 있어도 진행할 수 있습니다. 단 `test from this shell: not allowed`는 경우를 나눠 봅니다.
- 퍼블릭 차단을 적용했다면 정상입니다.
- 적용하지 않았는데 나오면 호출 권한을 확인합니다.

> Service Quotas 화면의 값이 실제 한도보다 작게 표시되는 경우가 있습니다(실측). 실제 한도를 확인한 경우에만 `ERNIE_SKIP_QUOTA_CHECK=1 ./ernie.sh install`로 쿼터 점검을 건너뜁니다.

---

## 5. 설치 (약 8~15분)

  ```
  $ ./ernie.sh install
  ```
  ▶ 진행 중 상태(`endpoint Creating …`, `model copies … ...`)가 주기적으로 출력되고, 아래 순서로 끝납니다.
  ```
  [OK]   role ...
  [OK]   model: ernie-image (baidu/ERNIE-Image)
  [OK]   endpoint config: ernie-image-cfg (instances 1..<MAX>)
  [OK]   endpoint InService
  [OK]   model copies <대수×4>/<대수×4>, instances <대수>
  [OK]   instances <대수>
  ```
  그 뒤 `status` 요약과 `Next: warm up with ./ernie.sh test ...`가 나옵니다.

✖ 멈춘 경우

| 상황 | 조치 |
|---|---|
| CloudShell 세션이 끊김 / 브라우저를 닫음 | CloudShell을 다시 열고 `cd ernie-image-sagemaker && ./ernie.sh status`로 상태를 봅니다. 이어서 `./ernie.sh install`을 **다시 실행**하면 남은 단계부터 진행합니다 |
| `[FAIL] aws ... failed: ... ResourceLimitExceeded` | 쿼터 부족 → `./ernie.sh delete -y`로 정리하고 대수를 조정한 뒤 3단계부터 다시 |
| `[FAIL] model copies failed: ...` | 메시지(권한·이미지 등)로 원인을 해결한 뒤 `./ernie.sh install`을 다시 실행합니다. 실패한 복제본을 지우고 다시 만듭니다 |
| `model copies did not reach ... (GPU capacity or quota)` | GPU 용량 부족일 수 있음 → 시간을 두고 `./ernie.sh status`. 계속 안 되면 대수를 줄여 재시도 |
| `another ernie.sh is changing ...` | 다른 창에서 같은 작업이 실행 중 → 그 창이 끝날 때까지 대기 |
| 종료 코드 2, `nothing was assumed` | 권한 거부·토큰 만료·네트워크 등 → 원인 해결 후 **같은 명령 다시 실행** |

---

## 6. 확인 (약 5분)

### 퍼블릭 차단을 적용하지 않은 경우
  ```
  $ ./ernie.sh test <복제본 수> <복제본 수 × 6>     # 예: 2대 → ./ernie.sh test 8 48
  ```
  ▶ `results={'ok': N}`(실패 0건)이면 정상입니다. 첫 회에는 콜드 상태라 1건 정도 실패할 수 있으니, 한 번 더 실행해 전부 ok인지 봅니다.
  ▶ 생성 이미지는 `./out/<시각>/`에 있습니다. 필요하면 **작업 → 파일 다운로드**로 1장 받아 확인합니다.

### 퍼블릭 차단을 적용한 경우
  ```
  $ ./ernie.sh verify-private
  ```
  ▶ `[PASS] invoking from this shell is denied by an explicit deny (service control policy)`이면 계정 전체 차단이 확인된 것입니다
  ✖ `[PASS] ... (IAM policy)`이면 지금 사용자만 막힌 것입니다. SCP 적용 상태를 확인합니다
  ✖ `[FAIL] this shell could invoke the endpoint`이면 차단이 적용되지 않은 것입니다. 2단계를 확인합니다
  - 이 경우 예열·생성 확인은 VPC 안(예: EKS Pod)에서 [`eks/sm_invoke.py`](../eks/sm_invoke.py)로 합니다. CloudShell의 `test`는 거부되는 것이 정상입니다.

---

## 7. 애플리케이션 담당에게 전달 (약 5분)

  ```
  $ ./ernie.sh status
  ```
- ☐ 다음 줄을 애플리케이션 담당에게 전달합니다.
  `invoke            : EndpointName=… InferenceComponentName=… CustomAttributes=route=/v1/images/generations`
- ☐ 아래 세 가지를 함께 안내합니다.
  1. 요청에 `"guidance_scale": 4.0`을 포함합니다. 품질·시간 측정의 기준이며, 10 steps 1344x768이면 약 22초입니다.
  2. 모든 호출자의 동시 호출 합계는 모델 복제본 수(대수 × 4) 이하로 유지합니다.
  3. 엔드포인트가 있는 동안 비용이 발생하므로, 사용 후에는 삭제합니다.
- ☐ 호출 방법 문서를 안내합니다: [`eks/EKS_INTEGRATION_GUIDE_KR.md`](../eks/EKS_INTEGRATION_GUIDE_KR.md)

---

## 8. (필요 시) 대수 변경

| 명령 | 동작 | 서비스 영향 (실측) |
|---|---|---|
| `./ernie.sh scale <N>` (늘리기) | 인스턴스 추가 후 복제본 N×4 | 중단 없음, 1→2대 약 8분 |
| `./ernie.sh scale <N>` (줄이기) | 복제본 재기동 | **약 10~13분 생성 불가**, 실행 전 확인 질문 |

- 늘리거나 줄인 뒤에는 안내되는 `./ernie.sh test ...`로 예열합니다.
- 줄이기는 트래픽이 없을 때만 합니다. 도중에 끊기면 같은 `scale N`을 다시 실행해 복구합니다.

---

## 9. 작업 종료

### A. 엔드포인트를 켜 두는 경우
- ☐ `./ernie.sh status` 결과(대수, 비용)를 관계자와 확인
- ☐ 삭제 방법 안내: `cd ernie-image-sagemaker && ./ernie.sh delete`

### B. 끄는 경우 (비용 중지)
  ```
  $ ./ernie.sh delete
  ```
  ▶ 엔드포인트 이름(`ernie-image`)을 입력해 확인하면, 마지막 줄에 `endpoint and model copies are gone: endpoint charges stopped`가 나옵니다
  ```
  $ ./ernie.sh status
  ```
  ▶ `endpoint 'ernie-image' not found in <리전> (no endpoint charges)`
  - 실행 역할까지 지우려면 `./ernie.sh delete -y --role`을 씁니다. 다른 모델이 쓰고 있으면 역할은 자동으로 보존됩니다.

### 공통 마무리
- ☐ 생성 이미지(`out/`)와 출력한 정책 파일 중 필요 없는 것은 지웁니다
- ☐ 작업 결과(설치 대수, 엔드포인트 상태, 전달 내용, 남은 조치, 사용한 커밋/태그)를 기록합니다

---

## 부록 A. 명령 요약

| 명령 | 용도 |
|---|---|
| `./ernie.sh check` | 읽기 전용 점검 |
| `./ernie.sh install` | 설치(중단 시 다시 실행하면 이어서) |
| `./ernie.sh status` | 상태, 호출 값, 비용 |
| `./ernie.sh test C T` | 동시 C건씩 총 T건 생성 시험 |
| `./ernie.sh scale N [-y]` | 대수 변경 |
| `./ernie.sh delete [-y] [--role]` | 삭제 |
| `./ernie.sh config show` / `config set KEY VALUE` | 설정 |
| `./ernie.sh scp-policy <vpce>` / `invoke-policy <vpce>` / `verify-private` | 퍼블릭 차단 |

## 부록 B. 사전 검증 범위

- 검증한 것: CloudShell과 같은 OS·셸·CLI 환경에서 AWS를 실측했습니다.
  - 설치 → 생성 → 1↔2대 증감 → 삭제
  - 세션·네트워크 중단 후 재개
  - 권한·쿼터 부족 차단, 다른 리전용 역할 차단
  - VPC 엔드포인트 경유 허용·인터넷 경로 명시적 거부(IAM 정책)
- 검증하지 못한 것: SCP를 실제로 적용한 상태, 4대 이상 규모. 작업할 때 `check`와 `verify-private`로 확인합니다.

## 부록 C. CloudShell 밖(EC2, Cloud9, 로컬 Linux)에서 실행할 때

CloudShell을 쓸 수 없을 때만 사용합니다. CloudShell과 다른 점이 있어서, C-1~C-4를 먼저 해야 `check`가 통과합니다.

| 차이 | CloudShell | EC2·Cloud9·로컬 | 증상 (실제 출력) |
|---|---|---|---|
| 호출 주체 | 콘솔 로그인 역할 | 그대로 두면 **인스턴스 역할**(예: Cloud9의 `AWSCloud9SSMAccessRole`, SageMaker·IAM·쿼터 권한 없음) | `caller: ...assumed-role/AWSCloud9SSMAccessRole/i-...`, `cannot read quota ...`, `cannot read your role` |
| boto3 | 기본 설치 | 없을 수 있음 | `[FAIL] python3 with boto3 is required` |
| 네트워크 | AWS 공용 API 접속 가능 | 프라이빗 서브넷이면 공용 API 경로가 없을 수 있음 | `aws iam get-role failed: ... Connection was closed ... iam.amazonaws.com` |
| 리전 | 콘솔 리전 자동 | 자동 아님 | `REGION is empty: run ./ernie.sh config set REGION <region>` |
| 유휴 시 | 20~30분 무입력이면 세션 종료 | 환경마다 다름(Cloud9은 설정한 시간 후 인스턴스 자동 중지) | 다시 열고 같은 명령 재실행 |

### C-1. 네트워크 확인 (진행 가능 여부 판단)
  ```
  $ R=<리전>
  $ for h in iam.amazonaws.com sts.$R.amazonaws.com servicequotas.$R.amazonaws.com \
             api.sagemaker.$R.amazonaws.com runtime.sagemaker.$R.amazonaws.com translate.$R.amazonaws.com; do
      printf '%-48s %s\n' "$h" "$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://$h/)"; done
  ```
  ▶ 모든 줄에 숫자 응답 코드(예: 302, 403, 404)가 나오면 진행할 수 있습니다. 연결만 확인하는 것이라 코드 값은 상관없습니다
  ✖ `000`이 있으면 그 주소로 나가는 경로가 없습니다
  - `iam`·`servicequotas`·`api.sagemaker` 중 하나라도 `000`이면 이 환경으로는 진행할 수 없습니다. CloudShell을 쓰거나, 네트워크 담당에게 NAT/프록시 경로를 요청합니다
  - `runtime.sagemaker`·`translate`만 `000`이면 설치는 할 수 있습니다. 6단계 `test` 대신 애플리케이션 쪽에서 확인합니다

### C-2. 도구 준비
  ```
  $ python3 -c 'import boto3' 2>/dev/null && echo boto3-ok || python3 -m pip install --user boto3
  $ command -v aws flock unzip curl
  $ aws --version                                   # aws-cli/2.x
  $ git clone https://github.com/jeonghun-app/ernie-image-sagemaker.git && cd ernie-image-sagemaker
  $ ./ernie.sh config set REGION <리전>
  ```
  ▶ `boto3-ok`(또는 설치 완료), 명령 경로 4줄, `config show`의 `(effective REGION: <리전>)`이 나오면 됩니다
  ✖ `pip`가 인터넷 경로가 없어 실패하면 이 환경으로는 진행할 수 없습니다(C-1과 같은 이유)
  ✖ AWS CLI v1이거나 없으면 `./ernie.sh update-cli`로 `~/.local`에 설치합니다

### C-3. 작업 사용자 자격 증명 사용
인스턴스 역할 대신, 권한을 받은 작업 사용자/역할(예: IAM Identity Center의 권한 세트)로 실행해야 합니다. Cloud9의 AWS 관리형 임시 자격 증명은 IAM 작업 일부를 막으므로, 설치(역할 생성)에 쓰지 않습니다.

- ☐ 다음 중 하나로 자격 증명을 설정합니다.
  - IAM Identity Center(SSO): `aws configure sso`로 프로필을 만들고 `export AWS_PROFILE=<프로필>`
  - 또는 SSO 포털 → 대상 계정 → 역할 → **Access keys** → "Set AWS environment variables"의 `export` 3줄을 터미널에 붙여넣기
  ```
  $ aws sts get-caller-identity --query Arn --output text
  ```
  ▶ 작업 사용자/역할의 ARN(예: `arn:aws:sts::<계정>:assumed-role/AWSReservedSSO_<역할>_.../<사용자>`)
  ✖ 여전히 인스턴스 역할이면 설정이 적용되지 않은 것입니다. 같은 터미널에서 다시 설정합니다
- 주의
  - 환경 변수로 붙여넣은 자격 증명은 **그 터미널에서만** 유효합니다. 새 터미널을 열면 다시 붙여넣습니다.
  - 유효 시간이 지나면 `ernie.sh`가 종료 코드 2(`nothing was assumed`)로 멈춥니다. 새 자격 증명을 받아 설정하고 **같은 명령을 다시 실행**하면 이어서 진행합니다.
  - 키는 파일이나 문서에 저장하지 않습니다. 작업이 끝나면 `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`을 실행하고 터미널을 닫습니다.

### C-4. 이후 절차
- 본문 **3단계(설정)부터 똑같이** 진행합니다. 명령을 실행하기 전에 저장소 폴더에 있는지 확인합니다.
- 인스턴스가 유휴로 중지되어도 AWS 쪽 설치는 계속됩니다. 다시 열면 C-3 자격 증명을 다시 설정하고, `./ernie.sh status`를 본 뒤 같은 명령을 다시 실행합니다.
- 9단계에서 작업을 마칠 때 C-3의 `unset`을 실행합니다.
