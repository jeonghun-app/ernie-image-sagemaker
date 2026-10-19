<!-- Copyright (c) 2026 ernie-image-sagemaker contributors -->
<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ERNIE-Image on Amazon SageMaker: CloudShell 설치 도구

[ERNIE-Image](https://huggingface.co/baidu/ERNIE-Image) 텍스트-이미지 모델을 **내 AWS 계정의 Amazon SageMaker 실시간 엔드포인트**로 띄우는 도구입니다. AWS CloudShell에서 스크립트 하나(`ernie.sh`)로 다음을 모두 합니다.

- 설치 전 점검: 권한, 쿼터, 네트워크, CLI
- 설치, 대수 증감, 상태 확인, 생성 테스트, 삭제

> *English summary: a single Bash script (`ernie.sh`) that checks, installs, scales and deletes an ERNIE-Image real-time endpoint (vLLM-Omni container, one model copy per GPU via Inference Components) in your own AWS account from AWS CloudShell, plus a guide and a Python sample for calling it privately from Amazon EKS. Docs are in Korean; the script output and code comments are in English.*

```
[내 애플리케이션 (예: EKS Pod)]
   │ ① Amazon Translate (한국어 등 → 영어)
   │ ② sagemaker-runtime:InvokeEndpoint  (IAM 인증, VPC 엔드포인트로 사설화 가능)
   ▼
[SageMaker 실시간 엔드포인트]  ml.g6e.12xlarge × N대
   └ Inference Component: GPU 1장마다 ERNIE-Image 모델 1개 (1대당 4개)
   │
   └ 응답: {"data":[{"b64_json":"<PNG base64>"}]}
```

- **만드는 리소스는 SageMaker 실행 역할, 모델, 엔드포인트 구성, 엔드포인트, 모델 복제본(Inference Component)뿐입니다.** API Gateway, Lambda, 로드밸런서 같은 공개 주소는 만들지 않습니다.
- 모델은 Hugging Face(`baidu/ERNIE-Image`)에서 내려받고, 컨테이너는 AWS 딥러닝 컨테이너(vLLM-Omni, `763104351884.dkr.ecr.<리전>.amazonaws.com/vllm`)를 씁니다.

## 목차

0. [요구 사항](#0-요구-사항)
1. [빠른 시작](#1-빠른-시작)
2. [명령](#2-명령)
3. [설정 (`config.env`)](#3-설정-configenv)
4. [점검 항목과 안전장치](#4-점검-항목과-안전장치)
5. [서브넷과 AZ](#5-서브넷과-az--영향이-있나요)
6. [대수 증감 (`scale`)](#6-대수-증감-scale)
7. [퍼블릭 차단](#7-퍼블릭-차단-공개-경로로는-호출되지-않게)
8. [애플리케이션에서 호출](#8-애플리케이션eks에서-호출)
9. [비용과 삭제](#9-비용과-삭제)
10. [검증 결과](#10-검증-결과)
11. [저장소 구성](#11-저장소-구성)
12. [라이선스](#12-라이선스)

---

## 0. 요구 사항

| 항목 | 내용 |
|---|---|
| 실행 환경 | **AWS CloudShell 권장**(아래가 모두 기본 설치됨). Linux 셸(EC2, 로컬 PC)에서도 실행할 수 있습니다: bash 4 이상, AWS CLI v2, python3 + boto3, `flock`(util-linux), `curl`, `unzip`. macOS는 `flock`이 없어 지원하지 않습니다 |
| 리전 | `ml.g6e.12xlarge` SageMaker 엔드포인트, Amazon Translate, vLLM-Omni 컨테이너 이미지가 모두 있는 리전. **서울(`ap-northeast-2`)과 도쿄(`ap-northeast-1`)에서 검증**했습니다 |
| 쿼터 | Service Quotas → Amazon SageMaker → `ml.g6e.12xlarge for endpoint usage` ≥ 최대 대수(`MAX_INSTANCES`). 새 계정은 보통 0이라 **먼저 증설 요청**이 필요합니다 |
| 권한 | 실행 사용자/역할에 SageMaker 관리, IAM 역할 생성·`PassRole`, Service Quotas 조회 권한. 최소 권한 예시: [`policies/operator-policy.json`](policies/operator-policy.json) |
| 네트워크 | 기본 방식은 SageMaker 관리 네트워크라 준비할 것이 없습니다. 내 VPC 서브넷을 쓰려면 NAT 경로가 있는 프라이빗 서브넷이 필요합니다(5장) |

## 1. 빠른 시작

1. AWS 콘솔 오른쪽 위에서 설치할 **리전**(예: 아시아 태평양(서울))을 고르고, 상단의 **CloudShell** 아이콘(`>_`)을 누릅니다.
2. 이 저장소를 받습니다.
   ```bash
   git clone https://github.com/jeonghun-app/ernie-image-sagemaker.git
   cd ernie-image-sagemaker
   ```
   CloudShell에서 GitHub에 접속할 수 없다면, 저장소 ZIP(**Code → Download ZIP**)을 CloudShell의 **작업 → 파일 업로드**로 올리고 `unzip`으로 풉니다. 이때 실행 권한이 빠질 수 있으니 `chmod +x ernie.sh`를 실행합니다.
3. 대수를 정합니다. 예를 들어 2대로 시작하고 나중에 최대 10대까지 늘릴 수 있게 하려면 다음과 같이 설정합니다. 쿼터가 10대 이상이어야 합니다.
   ```bash
   ./ernie.sh config set INSTANCE_COUNT 2
   ./ernie.sh config set MAX_INSTANCES 10
   ```
4. 점검한 뒤 설치합니다. 실측으로 약 8~15분 걸렸습니다.
   ```bash
   ./ernie.sh check      # 읽기 전용 점검. 마지막 줄이 "result: ready"면 통과
   ./ernie.sh install    # 점검을 통과해야 설치를 시작합니다
   ```
5. 예열하고 확인합니다. 이미지는 `./out/<시각>/`에 저장됩니다.
   ```bash
   ./ernie.sh test 8 48  # 복제본 수(대수 × 4)만큼 동시에, 그 6배 건수
   ./ernie.sh status     # 마지막 줄의 호출 값(EndpointName 등)을 애플리케이션에 설정
   ```
6. 다 쓰면 삭제합니다. **엔드포인트가 있는 동안 비용이 계속 발생합니다**(9장).
   ```bash
   ./ernie.sh delete
   ```

> **퍼블릭 경로를 처음부터 막아야 한다면** 3번 전에 7장의 1~3단계(VPC 엔드포인트, SCP, 역할 정책)를 먼저 적용합니다. 그리고 4번 설치 후 `./ernie.sh verify-private`가 PASS인지 확인합니다. 이 경우 5번 예열은 VPC 안(예: EKS Pod)에서 해야 합니다. CloudShell의 `test`는 거부되기 때문입니다.

> - CloudShell은 키보드 입력이 20~30분 없으면 세션이 끊길 수 있습니다. 끊겨도 AWS 쪽 작업은 계속됩니다. 다시 접속해 `./ernie.sh status`로 상태를 보고 **같은 명령을 다시 실행**하면 남은 단계부터 진행합니다. 진행 중인 단계가 끝날 때까지 기다린 뒤 이어 가므로 바로 끝나지 않을 수 있습니다.
> - `check`가 AWS CLI가 오래됐다고 하면 `./ernie.sh update-cli`를 실행합니다. 최신 CLI를 홈 디렉터리에 설치합니다.
> - 처음 하는 설치라면 [작업 절차서](docs/RUNBOOK_KR.md)의 체크리스트를 따라가는 것이 가장 안전합니다. 오류가 나면 [문제 해결](docs/TROUBLESHOOTING_KR.md)을 봅니다.

## 2. 명령

| 명령 | 하는 일 |
|---|---|
| `./ernie.sh check` | 읽기 전용 점검: CLI 기능, 권한(실제 호출 42개를 리소스 ARN 기준으로), 쿼터, 네트워크, 기존 리소스, Translate |
| `./ernie.sh install` | 점검 → IAM 역할(없으면 생성) → 모델 → 엔드포인트 구성 → 엔드포인트 → 모델 복제본(대수 × 4). 중단됐으면 이어서 진행 |
| `./ernie.sh scale N [-y]` | **N대로 증감**. 늘리기는 중단 없음, 줄이기는 약 5~10분 생성 중단(6장). `-y`면 확인 생략 |
| `./ernie.sh status` | 엔드포인트 상태, 현재 대수, 복제본 수, 최근 5분 요청 수, 호출 값(서울이면 시간당 비용도) |
| `./ernie.sh test [C] [T]` | 동시 C건씩 총 T건 생성(기본 1 1, 10 steps, guidance 4.0, 1344x768). 실패가 있으면 종료 코드 1 |
| `./ernie.sh delete [-y] [--role] [--force] [--clean-enis]` | 복제본 → 엔드포인트 → 구성 → 모델 삭제 후, 남은 리소스가 없는지 확인. `-y` 확인 생략, `--role` 실행 역할도 삭제, `--clean-enis` VPC 모드의 남은 ENI 정리, `--force` 이 도구가 만들지 않은 같은 이름의 리소스도 삭제 |
| `./ernie.sh config show` / `config set KEY VALUE` | 설정 보기·변경 |
| `./ernie.sh subnets [vpc-id]` | 서브넷 후보 목록(AZ, 남은 IP, 기본 경로 종류, AZ별 GPU 유형 제공 여부) |
| `./ernie.sh invoke-policy [vpce-id]` | 호출 측(예: EKS Pod 역할)에 붙일 IAM 정책 출력(7장) |
| `./ernie.sh scp-policy <vpce-id>` | 계정 전체에서 VPC 엔드포인트 밖 호출을 거부하는 SCP 출력(7장) |
| `./ernie.sh verify-private` | 이 셸(인터넷 경로)에서의 호출이 명시적으로 거부되는지 확인. 거부되면 PASS (7장) |
| `./ernie.sh update-cli` | 최신 AWS CLI v2를 `~/.local`에 설치 |

종료 코드는 세 가지입니다.
- `0`: 성공
- `1`: 실패 또는 조치 필요
- `2`: 예상하지 못한 AWS 오류(권한 거부, 토큰 만료 등). 아무것도 추정하지 않고 멈춘 상태이므로, 원인을 고친 뒤 같은 명령을 다시 실행하면 됩니다.

환경 변수

| 변수 | 용도 |
|---|---|
| `ERNIE_CONFIG=/path/to/file` | `config.env` 대신 다른 설정 파일 사용(배포 여러 개를 따로 관리할 때) |
| `ERNIE_SKIP_QUOTA_CHECK=1` | 쿼터 사전 점검 생략. Service Quotas 표시값이 실제 한도보다 작다고 확인된 경우에만 사용 |
| `ERNIE_TEST_PROMPT="..."` | `test`에 쓰는 기본 프롬프트(한국어, 풍경 사진) 대신 사용. 한국어로 쓰면 Translate로 영어 번역 후 생성 |

## 3. 설정 (`config.env`)

| 키 | 기본값 | 설명 |
|---|---|---|
| `REGION` | (비움) | 비우면 CloudShell 리전(`AWS_REGION`) 사용. CloudShell 밖에서는 지정 |
| `NAME` | `ernie-image` | 리소스 이름. 엔드포인트·모델 = `NAME`, 복제본 = `NAME-ic`, 구성 = `NAME-cfg` (소문자·숫자·하이픈, 40자 이내) |
| `INSTANCE_TYPE` | `ml.g6e.12xlarge` | 검증된 유형(NVIDIA L40S 48GB × 4, GPU당 모델 1개). 다른 유형은 [WARN]과 함께 진행되며 검증되지 않았습니다 |
| `INSTANCE_COUNT` | `1` | 설치할 때 시작 대수. 설치 후 대수 변경은 `scale` |
| `MAX_INSTANCES` | `10` | `scale`로 늘릴 수 있는 최대 대수(1~100). **설치할 때 이 대수만큼 쿼터가 있어야 합니다**(SageMaker가 엔드포인트를 만들 때 최대 대수로 쿼터를 확인함, 실측). 설치 후 바꾸려면 삭제 후 재설치 |
| `COPIES_PER_INSTANCE` | `4` | 대당 모델 복제본 수(= GPU 수). ml.g6e.12xlarge는 4로 고정 |
| `SCALE_IN_COOLDOWN_MINUTES` | `5` | SageMaker 자동 정리 대기 시간(5~1440). `scale`의 줄이기는 이 값과 관계없이 바로 처리합니다 |
| `AZ_BALANCE` | `false` | `true`면 모델 복제본을 AZ에 고르게 나눕니다(가용성 우선). `false`면 적은 인스턴스에 모아 줄이기가 빨리 반영됩니다 |
| `MODEL_ID` | `baidu/ERNIE-Image` | Hugging Face 모델 ID(검증값) |
| `IMAGE_TAG` | `omni-sagemaker-cuda-v1.3.1` | vLLM-Omni 컨테이너 태그(검증값) |
| `ROLE_NAME` | `ernie-image-sagemaker-role` | SageMaker 실행 역할. 없으면 설치할 때 생성합니다. IAM 역할은 전 리전 공통이라 여러 리전·이름에서 같이 쓸 수 있게 만들어집니다. 이 도구가 만들지 않은 역할을 지정하면, 이 리전의 이미지 내려받기 권한이 있는지 `check`가 확인합니다 |
| `SUBNET_IDS`, `SECURITY_GROUP_IDS` | (비움) | 내 VPC 서브넷에서 실행할 때만 둘 다 지정(5장) |

- `config set`은 `config.env`를 직접 고칩니다. 나중에 `git pull`로 업데이트할 때 충돌하면 `git stash && git pull && git stash pop`으로 설정을 유지합니다.
- 배포를 여러 개(리전·이름별) 관리하려면 설정 파일을 복사해 `ERNIE_CONFIG=./prod.env ./ernie.sh status`처럼 지정합니다.

## 4. 점검 항목과 안전장치

| 항목 | 점검 내용 | [FAIL]일 때 |
|---|---|---|
| CLI | 필요한 옵션(축소 정책, 복제본 배치, VPC 설정) 지원 여부, python3·boto3, `flock` | `./ernie.sh update-cli` |
| 권한 | 설치·증감·삭제에 쓰는 관리 API 42개를 **실제 리소스 ARN 기준**으로 IAM 정책 시뮬레이션. `iam:PassRole`은 실행 역할을 SageMaker에 넘기는 조건으로 확인. 호출 권한(`test`용)은 따로 표시 | 빠진 동작이 표시됩니다. 실행 사용자/역할에 추가([`policies/operator-policy.json`](policies/operator-policy.json)) |
| 쿼터 | `ml.g6e.12xlarge for endpoint usage` − 다른 엔드포인트의 사용·예약량(관리형 스케일링 최대 대수 포함) ≥ **`MAX_INSTANCES`** | 쿼터 증설 요청 또는 `MAX_INSTANCES` 축소. Service Quotas 표시값이 실제 한도보다 작은 경우가 있어(실측), 실제 한도를 확인했다면 `ERNIE_SKIP_QUOTA_CHECK=1 ./ernie.sh install`로 점검을 건너뛸 수 있습니다 |
| 네트워크 | 서브넷 지정 시: 같은 VPC, 실제 적용되는 경로 테이블의 활성 NAT 경로, 서브넷별 남은 IP, AZ 수, 보안 그룹의 0.0.0.0/0 아웃바운드 443(여러 그룹 합산) | 5장 참고 |
| 기존 리소스 | 같은 이름의 엔드포인트·역할이 있으면, 이 도구가 만든 것인지 확인 | 다른 `NAME`·`ROLE_NAME` 사용 |
| Translate | 번역 호출 가능 여부(`test`와 애플리케이션에서 사용) | [WARN]만 표시 |

안전장치
- **이 도구가 만든 리소스만 다룹니다.** 만들 때 태그(`ernie-image:managed-by = ernie.sh/<NAME>`)를 붙이고, 재사용·삭제 전에 확인합니다. 다른 사람이 만든 같은 이름의 리소스나 역할은 건드리지 않습니다(삭제할 때 `--force`로만 예외).
- **조회 오류를 "없음"으로 판단하지 않습니다.** 권한 거부·토큰 만료 등은 그 자리에서 멈춥니다(종료 코드 2). 삭제는 "찾을 수 없음"이 확인될 때만 완료로 표시합니다.
- **같은 배포를 두 창에서 동시에 바꾸지 못하게** 잠급니다. `flock`으로 `~/.ernie-locks/<리전>-<NAME>.lock`을 잡고, 프로세스가 끝나면 자동으로 풀립니다.
- 역할 삭제(`--role`)는 이 리전에서 그 역할을 쓰는 다른 모델·엔드포인트 구성, 아직 정리 중인 VPC ENI가 없을 때만 합니다. IAM 역할은 전 리전 공통이므로, 다른 리전에서도 같은 `ROLE_NAME`을 쓴다면 `--role`을 쓰지 마세요.
- 엔드포인트 구성을 다른 엔드포인트가 현재 또는 업데이트 중에 참조하고 있으면 다시 만들거나 삭제하지 않습니다. 참조 여부를 확인할 수 없을 때(권한 부족 등)도 보존합니다.
- 권한 시뮬레이션에는 자격 증명 정책, 권한 경계, 조직 SCP가 반영됩니다. 세션 정책 등 일부는 반영되지 않을 수 있습니다. 시뮬레이션 권한(`iam:SimulatePrincipalPolicy`)이 없으면 점검을 건너뛰고 [WARN]을 표시합니다.
- 쿼터 승인은 GPU 확보를 보장하지 않습니다. 대수가 많을수록 실제 사용 전에 미리 설치·리허설해 주세요.

## 5. 서브넷과 AZ — 영향이 있나요?

| 방식 | 설정 | AZ 선택 | 대수에 주는 영향 |
|---|---|---|---|
| **SageMaker 관리 네트워크 (기본, 권장)** | `SUBNET_IDS` 비움 | SageMaker가 자동 선택(사용자가 지정할 수 없음) | 서브넷·IP 영향 없음. 리전 GPU 용량과 쿼터만 영향 |
| **내 VPC** | `SUBNET_IDS`, `SECURITY_GROUP_IDS` 지정 | **지정한 서브넷의 AZ에만** 인스턴스가 배치됨 | 그 AZ들의 GPU 재고와 서브넷별 남은 IP가 상한이 됨 |

**애플리케이션에서 호출하는 것만이 목적이라면 기본 방식으로 충분합니다.** 호출 경로는 애플리케이션 쪽 VPC 엔드포인트로 사설화합니다(7장). 내 VPC 방식은 모델 컨테이너가 VPC 안의 자원(사내 프록시 등)을 써야 할 때만 필요합니다.

내 VPC 방식을 쓸 때
- **서로 다른 AZ의 서브넷 2개 이상**을 지정합니다. 한 AZ만 지정하면 그 AZ에 GPU가 없을 때 대수를 늘릴 수 없습니다.
- 서브넷은 **NAT 게이트웨이 경로가 있는 프라이빗 서브넷**이어야 합니다. 모델(약 28GB)을 Hugging Face에서 내려받기 때문입니다.
  - 퍼블릭 서브넷(인터넷 게이트웨이 경로)은 쓸 수 없습니다. SageMaker 인스턴스에 공인 IP가 붙지 않기 때문이며, `check`가 [FAIL]로 막습니다.
  - Transit Gateway 경로는 [WARN]으로 표시됩니다. 인터넷까지 나가는지 직접 확인해 주세요.
- 서브넷마다 남은 IP를 넉넉히(대당 2개 이상) 둡니다. 보안 그룹은 아웃바운드 HTTPS(443)를 허용해야 합니다.
- 이 도구가 만든 실행 역할에는 VPC 네트워크 인터페이스 권한이 자동으로 들어갑니다.
- 후보 확인 및 설정:
  ```bash
  ./ernie.sh subnets vpc-0abc...            # ROUTE 열이 nat인 서브넷을 AZ가 겹치지 않게 선택
  ./ernie.sh config set SUBNET_IDS subnet-aaa,subnet-bbb
  ./ernie.sh config set SECURITY_GROUP_IDS sg-ccc
  ./ernie.sh check
  ```
- `subnets`에 나오는 GPU 유형 제공 여부는 EC2 기준 참고값입니다. SageMaker의 실제 용량과는 다를 수 있습니다.
- 엔드포인트를 삭제해도 SageMaker가 만든 네트워크 인터페이스(ENI)가 "available" 상태로 남았습니다(실측: 1시간 이상).
  - 이번 `delete` 실행에서 이 엔드포인트를 삭제했다면, 설정한 서브넷 안의 이 엔드포인트 ENI가 분리될 때까지 최대 15분 기다렸다가 삭제합니다.
  - 남은 ENI가 있으면 [WARN]으로 표시됩니다. 잠시 후 `./ernie.sh delete -y --clean-enis`로 정리합니다.
  - ENI를 정리하기 전에는 해당 보안 그룹·서브넷을 지울 수 없습니다.

## 6. 대수 증감 (`scale`)

| 방향 | 동작 | 서비스 영향 | 실측 (서울, 1↔2대) |
|---|---|---|---|
| 늘리기 | 모델 복제본을 N × 4개로 올리면, SageMaker가 인스턴스를 먼저 추가한 뒤 복제본을 올림 | **중단 없음**. 기존 복제본은 계속 처리 | 약 8분 |
| 줄이기 | 복제본 제거 → 인스턴스를 N대로 줄임 → 복제본 N × 4개 재기동 | **약 5~10분 생성 불가** | 약 10~13분 |

- 줄이기를 이렇게 처리하는 이유가 있습니다. 복제본 수만 줄이면 남은 복제본이 여러 인스턴스에 걸쳐 있어 SageMaker가 인스턴스를 회수하지 않았습니다(실측 30분 이상 2대 유지, 비용도 2대분 계속 발생).
- 따라서 **줄이기는 트래픽이 없을 때** 실행합니다. 실행 전에 최근 5분 요청 수를 보여 주고 확인을 묻습니다.
- 줄이는 도중 중단되면(세션 끊김 등) **같은 `scale N`을 다시 실행**합니다. 목표 대수로 복구됩니다(실측: 강제 종료 후 재실행 → 복구 → 생성 8/8).
- 늘리기 전에 쿼터를 다시 확인하고, 부족하거나 읽을 수 없으면 실행하지 않습니다.
- 늘리거나 줄인 직후에는 새 복제본의 첫 요청이 느립니다(실측: 직후 32건 중 1건 실패, 최대 약 47~55초). 끝나면 안내되는 `test` 명령으로 예열해 주세요.

## 7. 퍼블릭 차단 (공개 경로로는 호출되지 않게)

### 7-1. 이 구성에서 "퍼블릭"의 의미

| 항목 | 상태 |
|---|---|
| 공개 URL (API Gateway, Lambda Function URL, 로드밸런서, 공개 권한) | **만들지 않음** |
| 엔드포인트 인스턴스의 공인 IP | **없음** (SageMaker 관리 네트워크 또는 내 프라이빗 서브넷) |
| 호출 인증 | IAM 권한 + AWS 서명(SigV4) 필수. 익명 호출은 불가 |
| AWS 공용 API 주소 `runtime.sagemaker.<리전>.amazonaws.com` | 모든 AWS 서비스와 마찬가지로 **주소 자체는 존재**합니다(VPC 엔드포인트의 프라이빗 DNS도 같은 이름을 씁니다). 7-2를 적용하면, SCP 적용 범위에서 **지정한 VPC 엔드포인트를 거치지 않은 추론 요청은 누가 보내든 거부**됩니다 |

SageMaker 엔드포인트에는 리소스 정책이 없습니다. 그래서 아무 조치가 없으면, 계정 안에서 `sagemaker:InvokeEndpoint` 권한을 가진 사람(예: 관리자)은 인터넷 경로로 호출할 수 있습니다. 7-2가 이 경로를 막습니다.

### 7-2. 차단 절차 — **설치 전에** 적용합니다

1. **VPC 엔드포인트 생성**: 애플리케이션 VPC에 인터페이스 엔드포인트 `com.amazonaws.<리전>.sagemaker.runtime`을 만들고 프라이빗 DNS를 켭니다. ID(`vpce-...`)를 메모합니다.
2. **계정 전체 차단 (SCP, 권장)**: 아래 명령으로 만든 SCP를 AWS Organizations 관리자가 이 계정에 적용합니다. 엔드포인트 ARN은 이름(`NAME`)으로 정해지므로 **엔드포인트를 만들기 전에** 적용할 수 있습니다.
   ```bash
   ./ernie.sh scp-policy vpce-0abc1234def567890 > ernie-scp.json
   ```
   - 관리자를 포함한 계정의 모든 사용자·역할에 적용됩니다. 그 VPC 엔드포인트를 거치지 않은 `InvokeEndpoint`·`InvokeEndpointWithResponseStream`·`InvokeEndpointAsync` 호출을 거부합니다.
   - SCP는 조직의 관리(management) 계정과 서비스 연결 역할에는 적용되지 않습니다. 엔드포인트는 멤버 계정에 두세요.
   - 이 SCP는 지정한 엔드포인트만 대상으로 합니다. 다른 이름의 엔드포인트를 새로 만들거나 공개 프록시를 따로 구성하는 것까지 막지는 않습니다.
3. **호출 역할 정책**: 애플리케이션 역할(예: EKS Pod 역할)에 아래 정책을 붙입니다. 허용 문장과 함께 같은 조건의 명시적 Deny가 들어 있어, SCP를 쓸 수 없을 때는 역할 단위 차단으로도 쓸 수 있습니다.
   ```bash
   ./ernie.sh invoke-policy vpce-0abc1234def567890 > ernie-invoke-policy.json
   ```
4. **설치**: `./ernie.sh install`을 실행합니다. 설치·증감·삭제는 관리 API라서 이 차단의 대상이 아닙니다. `check`의 "test from this shell: not allowed"는 의도된 결과이므로 무시합니다.
5. **차단 확인 (전달 전 필수)**: CloudShell(인터넷 경로)에서 실행합니다.
   ```bash
   ./ernie.sh verify-private
   ```
   - `[PASS] ... denied by an explicit deny (service control policy)`: 정상입니다. 외부 경로 호출이 SCP로 거부됩니다. **계정 전체 차단은 "service control policy"로 PASS가 나와야 확인된 것**입니다. "(IAM policy)"로 PASS가 나오면 지금 사용자·역할만 막힌 것입니다.
   - `[FAIL] this shell could invoke the endpoint`: 차단되지 않은 상태입니다. SCP·정책 적용을 다시 확인합니다.
   - `verify-private`는 `InvokeEndpoint`만 시험합니다. 스트리밍·비동기 호출(`InvokeEndpointWithResponseStream`, `InvokeEndpointAsync`)은 이 엔드포인트에서 쓰지 않지만 정책에는 함께 들어 있습니다.
6. **예열과 동작 확인은 사설 경로에서**: VPC 안(예: EKS Pod)에서 [`eks/sm_invoke.py`](eks/sm_invoke.py)로 예열합니다. 이 상태에서 CloudShell의 `./ernie.sh test`는 거부되는 것이 정상입니다.

CloudShell에서 만든 JSON 파일은 **작업 → 파일 다운로드**로 받아 관리자에게 전달합니다.

실측 결과
- 서울: 역할 정책(3번)을 붙인 역할로 실험했습니다. VPC 엔드포인트 경유 호출은 성공(14초)했고, 인터넷 경로 호출은 `AccessDeniedException ... explicit deny`로 거부됐습니다.
- SCP(2번) 자체와 `InvokeEndpointWithResponseStream`·`InvokeEndpointAsync` 차단은 실측하지 못했습니다. 각자의 계정에서 5번 `verify-private`로 확인해 주세요.

## 8. 애플리케이션(EKS)에서 호출

`./ernie.sh status`의 마지막 줄에 호출 값이 나옵니다.

```
invoke            : EndpointName=<NAME> InferenceComponentName=<NAME>-ic CustomAttributes=route=/v1/images/generations
```

| 항목 | 값 |
|---|---|
| API | `sagemaker-runtime` `InvokeEndpoint` (실시간 호출 최대 60초) |
| `ContentType` | `application/json` |
| `CustomAttributes` | `route=/v1/images/generations` (필수) |
| 요청 본문 | `{"prompt": "<영어 프롬프트>", "size": "1344x768", "n": 1, "num_inference_steps": 10, "guidance_scale": 4.0, "seed": 1}` |
| 응답 본문 | `{"data": [{"b64_json": "<PNG base64>"}]}` |

- 호출 방법, Pod 권한(Pod Identity/IRSA), 동시 호출 수 제한, 사설망 연결은 [`eks/EKS_INTEGRATION_GUIDE_KR.md`](eks/EKS_INTEGRATION_GUIDE_KR.md)를 참고해 주세요. EKS가 아니어도(EC2, ECS, 온프레미스) 같은 API를 씁니다.
- **모든 호출자의 동시 호출 합계는 모델 복제본 수(대수 × 4) 이하**로 유지합니다. 대수를 바꾸면 애플리케이션의 동시 호출 상한도 함께 바꿉니다.
- 프롬프트는 **영어**로 보냅니다. 다른 언어는 Amazon Translate 등으로 먼저 번역합니다.
- 요청에 **`"guidance_scale": 4.0`을 넣어 주세요.** 품질 확인과 시간 측정은 모두 4.0 기준입니다(10 steps 약 22초). 생략하면 약 16초로 빨라지지만 결과가 달라지며, 그 품질은 검증하지 않았습니다.
- 모델 내장 프롬프트 확장(PE)이 프롬프트를 상세 묘사로 다시 쓴 뒤 생성합니다. 현재 컨테이너에서는 끌 수 없습니다.

## 9. 비용과 삭제

- 엔드포인트가 있는 동안 비용이 발생합니다. 서울 온디맨드 기준으로 대당 약 **$16.13/시간**입니다(엔드포인트만, 2026-10 기준). 다른 리전과 최신 요금은 [Amazon SageMaker 요금](https://aws.amazon.com/sagemaker/pricing/)에서 확인하세요. `status`는 서울 리전일 때만 예상 비용을 표시합니다.
- 사용이 끝나면 삭제합니다.
  ```bash
  ./ernie.sh delete        # 엔드포인트 이름을 입력해 확인
  ./ernie.sh delete -y --role   # 확인 없이, 실행 역할까지 삭제
  ```
- 마지막 줄이 `endpoint and model copies are gone: endpoint charges stopped`이면 완료입니다.
- 남은 리소스가 있으면 [FAIL]과 함께 종료 코드 1로 끝납니다. 이때는 다시 실행합니다.

## 10. 검증 결과

2026-10-12~13에 측정했습니다. 환경은 CloudShell과 같은 구성(Amazon Linux 2023, bash 5.2, AWS CLI 2.36, boto3)이고, `ml.g6e.12xlarge`를 썼습니다.

| 시험 | 결과 |
|---|---|
| 설치 2대 (서울) | 엔드포인트 약 2.5분 + 복제본 8개 약 5분. 예열 후 48/48, 16/16 |
| 늘리기 1→2대 | 중단 없이 약 8분. 예열 후 48/48 |
| 줄이기 2→1대 | 약 10분. 이후 8/8 |
| 줄이기 도중 강제 종료 → 다시 `scale 1` / `scale 2` | 1대·복제본 4개로 복구 8/8 / 2대·복제본 8개로 복구 16/16 |
| 내 VPC 모드 (도쿄, NAT 프라이빗 서브넷 2개·AZ 2개, 2회) | 점검 통과 → 설치 약 7분 → 지정 서브넷에 SageMaker ENI 생성 확인 → 생성 성공 → `delete`가 남은 ENI 삭제 후 역할 삭제, 잔존 없음 |
| 퍼블릭 서브넷 지정 | `check` [FAIL]로 설치 차단 |
| 권한이 일부 없는 역할 | `check`가 빠진 20개 동작 표시. 조회 권한이 거부되면 `status`·`delete`가 "없음"으로 오판하지 않고 종료 코드 2로 멈춤 |
| 잘못된 자격 증명, 세션 토큰 만료 | 종료 코드 2로 멈춤(삭제·완료로 표시하지 않음) |
| `invoke-policy` + VPC 엔드포인트 | VPC 엔드포인트 경유 성공, 인터넷 경로는 명시적 거부 |
| 쿼터 부족 (쿼터 1대에 2대 설치) | `check` [FAIL]로 차단 |
| 최대 대수(10)보다 쿼터가 작은 계정 | SageMaker가 생성 거부(`ResourceLimitExceeded`, "request delta of 10") → `check`가 `MAX_INSTANCES` 기준으로 미리 차단 |
| 태그 없는(이 도구가 만들지 않은) 모델 복제본 | `scale`·`delete` 모두 거부, 변경 없음 |
| 두 창에서 동시에 `scale` | 두 번째는 즉시 거부, 첫 번째는 정상 완료 |
| `verify-private` | 차단 정책 없는 관리자: FAIL / 거부 정책을 붙인 역할: PASS(explicit deny) |
| 증설·축소 직후 첫 요청 | 새 복제본이 콜드 상태라 일부 요청이 60초 제한을 넘음(48건 중 1건). 예열 후 정상 |
| 다른 리전용으로 만든 기존 역할 재사용 | 실행 역할 정책을 전 리전 공통으로 만들고, 이 도구가 만들지 않은 역할은 `check`가 이미지 권한을 미리 확인. 실패한 복제본은 `install`·`scale` 재실행 시 지우고 다시 만듦 |
| 생성 시간 (10 steps, 1344x768) | guidance 4.0 약 22.5초 / 생략 약 16.4초. 1대(복제본 4개) ≈ 분당 약 10장 |

검증하지 못한 범위
- 4대 이상 규모, 다른 계정에서의 호출, 온프레미스 경로, SCP를 실제로 적용한 상태는 실측하지 않았습니다.
- 계정마다 CLI 버전, 권한 구성, SCP가 다르면 `check` 결과도 달라질 수 있습니다. 설치 전에 반드시 `check`를 실행해 주세요.

## 11. 저장소 구성

| 경로 | 내용 |
|---|---|
| [`ernie.sh`](ernie.sh) | 점검·설치·증감·상태·테스트·삭제 스크립트 |
| [`config.env`](config.env) | 설정 파일(시작 대수, 최대 대수, 리전, 이름, 서브넷 등) |
| [`eks/`](eks/) | 애플리케이션에서 호출하는 방법: [가이드](eks/EKS_INTEGRATION_GUIDE_KR.md), [Python 예제](eks/sm_invoke.py), [Kubernetes 예시](eks/k8s-example.yaml), [예시 프롬프트](eks/prompt_example.txt) |
| [`docs/RUNBOOK_KR.md`](docs/RUNBOOK_KR.md) | 처음부터 끝까지 따라 하는 작업 절차서(체크리스트, 정상 출력, 멈출 때 조치, CloudShell 밖에서 실행할 때) |
| [`docs/TROUBLESHOOTING_KR.md`](docs/TROUBLESHOOTING_KR.md) | 증상별 원인과 조치, IAM 역할 생성이 막힌 계정에서 관리자가 역할을 미리 만드는 방법 |
| [`policies/`](policies/) | IAM 정책 템플릿: 실행 사용자 최소 권한, SageMaker 실행 역할(신뢰·권한) |
| [`tests/`](tests/) | AWS 없이 도는 점검: [스모크 테스트](tests/smoke.sh)(가짜 `aws` CLI), [문서 링크 검사](tests/check_docs.py) |
| [`CHANGELOG.md`](CHANGELOG.md) | 변경 이력 |

변경을 제안할 때는 아래 점검을 통과시켜 주세요. GitHub Actions(`.github/workflows/ci.yml`)도 같은 점검을 실행합니다.

```bash
pip install shellcheck-py ruff pyyaml boto3
shellcheck ernie.sh tests/smoke.sh
ruff check .
bash tests/smoke.sh
python3 tests/check_docs.py
```

이 점검은 AWS 리소스를 만들지 않습니다. 설치·증감·삭제 동작을 바꿨다면 실제 계정에서 `check` → `install` → `test` → `scale` → `delete`를 확인하고, 결과를 PR에 적어 주세요.

## 12. 라이선스

- 코드(`ernie.sh`, `config.env`, `eks/*.py`, `eks/*.yaml`, `policies/`, CI 설정)는 [Apache License 2.0](LICENSE)을 따릅니다.
- 문서(`*.md`)는 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)을 따릅니다. 자세한 내용은 [NOTICE](NOTICE)에 있습니다.
- ERNIE-Image 모델과 vLLM-Omni 컨테이너는 이 저장소에 포함되지 않으며, 각자의 라이선스를 따릅니다. 사용 전에 [모델 카드](https://huggingface.co/baidu/ERNIE-Image)의 라이선스를 확인해 주세요.
- 이 도구를 써서 생기는 AWS 비용은 계정 소유자가 부담합니다. 사용 후에는 `./ernie.sh delete`로 정리해 주세요.
