<!-- Copyright (c) 2026 ernie-image-sagemaker contributors -->
<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ERNIE-Image SageMaker 엔드포인트를 Amazon EKS에서 직접 호출하기

SageMaker 엔드포인트만 만들고, EKS 애플리케이션(Pod)이 **AWS SDK로 엔드포인트를 직접 호출**하는 구성입니다.
Lambda와 API Gateway를 거치지 않고, 공개 주소도 만들지 않습니다. EC2·ECS·온프레미스 서버에서도 같은 API와 같은 필드를 씁니다.

> **요약**
> - 호출 경로: EKS Pod → (영어가 아니면 번역) Amazon Translate → `sagemaker-runtime:InvokeEndpoint` → PNG 이미지(응답 본문 안에 base64)
> - 인증: **EKS Pod Identity**(권장) 또는 IRSA. 코드나 Secret에 액세스 키를 두지 않습니다.
> - 사설망: VPC 인터페이스 엔드포인트(`sagemaker.runtime`, `translate`)를 쓰면 인터넷을 거치지 않습니다.
> - 제한 시간: SageMaker 실시간 호출 최대 **60초**(API Gateway의 29초 제한이 없음). 실측 10 steps 약 21~23초, 20 steps 약 34초.
> - 주의: 앞단(Lambda 등)이 처리 상한을 대신 지켜 주지 않으므로, **애플리케이션이 동시 호출 수를 모델 복제본 수 이하로 제한**해야 합니다(4장).

---

## 1. 구성

```
[EKS 클러스터 (내 VPC)]
  애플리케이션 Pod (ServiceAccount → IAM 역할, Pod Identity)
     │ ① TranslateText (ko → en)          ── VPC 엔드포인트: com.amazonaws.<리전>.translate
     │ ② InvokeEndpoint (Inference Component) ── VPC 엔드포인트: com.amazonaws.<리전>.sagemaker.runtime
     ▼
[Amazon SageMaker 실시간 엔드포인트]  ml.g6e.12xlarge × N대, GPU마다 ERNIE-Image 모델 1개 (1대당 4개)
     │
     └─ 응답: {"data":[{"b64_json":"<PNG base64>"}]}  → Pod가 디코드해 저장·전달 (필요하면 S3에 저장)
```

- 응답에 이미지가 바로 들어 있어 별도 S3 버킷이 필요 없습니다. 저장이나 배포가 필요하면 애플리케이션이 S3에 올립니다.
- 모델은 영어 프롬프트를 받습니다. 번역(Amazon Translate)이 필요하면 애플리케이션이 직접 호출합니다. 앞단에 Lambda를 두는 구성이라면 Lambda가 하던 일입니다.

## 2. SageMaker 엔드포인트 만들기

AWS 계정의 **CloudShell에서 `ernie.sh`로 설치**합니다. 절차, 점검 항목, 대수 증감, 삭제는 [`../README.md`](../README.md)를 따릅니다.

```bash
./ernie.sh config set INSTANCE_COUNT 2
./ernie.sh check && ./ernie.sh install
./ernie.sh status      # 마지막 줄: EndpointName / InferenceComponentName
```

- 대수 규칙: 인스턴스 N대 → 모델 복제본 **N × 4개** (ml.g6e.12xlarge, GPU 1장당 모델 1개)
- 대수 변경: `./ernie.sh scale N` (늘리기는 중단 없음, 줄이기는 약 5~10분 생성 중단)
- 삭제: `./ernie.sh delete`. **엔드포인트가 사라져야 비용이 멈춥니다.**

## 3. EKS Pod에 권한 주기

### 3-1. IAM 정책 (Pod가 쓰는 역할에 연결)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "sagemaker:InvokeEndpoint",
      "Resource": [
        "arn:aws:sagemaker:<리전>:<계정ID>:endpoint/<EndpointName>",
        "arn:aws:sagemaker:<리전>:<계정ID>:inference-component/<InferenceComponentName>"
      ] },
    { "Effect": "Allow", "Action": "translate:TranslateText", "Resource": "*" }
  ]
}
```

- 영어 프롬프트만 보내면(`SM_SOURCE_LANG=en`) `translate:TranslateText` 문장은 빼도 됩니다.

- `ernie.sh`는 `NAME`을 소문자로만 받으므로 ARN의 이름도 그대로 쓰면 됩니다.

### 3-2. EKS Pod Identity로 역할 연결 (권장)

1. 클러스터에 `eks-pod-identity-agent` 애드온을 설치합니다.
2. 신뢰 정책이 `pods.eks.amazonaws.com`인 IAM 역할을 만들고 3-1 정책을 붙입니다.
3. ServiceAccount와 역할을 연결합니다.

```bash
aws eks create-addon --cluster-name <클러스터> --addon-name eks-pod-identity-agent
aws eks create-pod-identity-association --cluster-name <클러스터> \
  --namespace image-gen --service-account image-gen --role-arn <역할 ARN>
```

신뢰 정책:
```json
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow",
  "Principal": { "Service": "pods.eks.amazonaws.com" },
  "Action": ["sts:AssumeRole", "sts:TagSession"] }] }
```

- IRSA를 이미 쓰고 있다면 IRSA로 해도 됩니다. ServiceAccount에 `eks.amazonaws.com/role-arn` 주석을 달고, 역할 신뢰 정책에 클러스터 OIDC 제공자를 지정합니다.
- 엔드포인트가 **다른 AWS 계정**에 있으면, 그 계정에 역할을 만들어 Pod 역할이 AssumeRole하는 방식을 씁니다. SageMaker 엔드포인트에는 리소스 정책을 붙일 수 없습니다(이 경로는 실측하지 않았습니다).
- 3-1 정책은 CloudShell에서 `./ernie.sh invoke-policy [vpce-id]`로 바로 만들 수 있습니다. VPC 엔드포인트 ID를 주면 그 경로를 거치지 않은 호출을 거부하는 문장이 추가됩니다(6장, 실측 확인).

### 3-3. Kubernetes 매니페스트 예시

`k8s-example.yaml` 참고 (ServiceAccount, ConfigMap, Deployment).

```yaml
env:
  - { name: AWS_REGION, value: <리전> }
  - { name: SM_ENDPOINT_NAME, value: <EndpointName> }
  - { name: SM_INFERENCE_COMPONENT, value: <InferenceComponentName> }
  - { name: SM_MAX_IN_FLIGHT, value: "4" }   # Pod당 동시 호출 수 (4장 참고)
  - { name: SM_SOURCE_LANG, value: ko }      # 프롬프트 언어. en이면 번역 생략
```

## 4. 동시 호출 수 제어 (중요)

앞단에 Lambda를 두는 구성에서는 Lambda 예약 동시성이 "동시 처리 상한"을 지켜 줍니다. 직접 호출에서는 이 역할을 **애플리케이션이** 맡아야 합니다.

- 기준: **전체 Pod의 동시 호출 합계 ≤ 모델 복제본 수(N × 4)**
  - 예: 1대(복제본 4개)면 Pod 1개 × 4건, 2대(복제본 8개)면 Pod 2개 × 4건 (`SM_MAX_IN_FLIGHT=4`)
  - 롤링 배포 중에는 새 Pod와 기존 Pod가 함께 떠서 합계가 늘어납니다. `maxSurge: 0`으로 두거나 배포는 사용량이 적은 시간에 합니다.
  - Pod 수가 HPA로 늘어나면 합계가 상한을 넘을 수 있습니다. Pod 수 상한을 고정하거나, 큐·세마포어를 공유 계층(예: Redis)에 둡니다.
- 상한을 넘겨 보내면 오류가 바로 나지 않고 **GPU에서 순서를 기다려 응답이 느려집니다**(최대 60초 뒤 타임아웃).
- 샘플 `sm_invoke.py`는 프로세스 안에서 세마포어로 동시 호출 수를 제한합니다.

## 5. 호출 방법

### 5-1. 요청과 응답

| 항목 | 값 |
|---|---|
| API | `sagemaker-runtime` `InvokeEndpoint` |
| `EndpointName` / `InferenceComponentName` | 배포 출력값 |
| `ContentType` | `application/json` |
| `CustomAttributes` | **`route=/v1/images/generations`** (필수) |
| 요청 본문 | `{"prompt": "<영어 프롬프트>", "size": "1344x768", "n": 1, "num_inference_steps": 10, "guidance_scale": 4.0, "seed": 1}` |
| 응답 본문 | `{"data": [{"b64_json": "<PNG base64>"}]}` (1344x768 PNG 약 3MB, base64로 약 4MB) |

- `size`: `1344x768`(16:9 권장), `1376x768`, `1024x768`, `1024x1024`, `768x1344`
- `num_inference_steps`: 10 권장. 60초 제한 안에서 20까지 실측 성공(약 34초)
- `guidance_scale`: **4.0을 꼭 넣어 주세요.** 지금까지의 품질 평가와 시간 측정(10 steps 약 22초)은 모두 4.0 기준입니다. 생략하면 모델 기본값이 적용되어 더 빠르지만(약 16초) 결과가 달라지며, 그 품질은 검증하지 않았습니다.
- 프롬프트는 영어로 보내야 합니다. 한국어 등 다른 언어는 Amazon Translate로 먼저 번역합니다(`sm_invoke.py`는 `SM_SOURCE_LANG`, 기본 `ko`).
- 모델 내장 프롬프트 확장(PE)이 프롬프트를 상세 묘사로 다시 쓴 뒤 생성하며, 현재 컨테이너에서는 끌 수 없습니다.

### 5-2. Python (boto3)

```python
import base64, json, boto3
from botocore.config import Config

REGION = "ap-northeast-2"  # 엔드포인트를 만든 리전
tr = boto3.client("translate", region_name=REGION)
sm = boto3.client("sagemaker-runtime", region_name=REGION,
                  config=Config(read_timeout=65, retries={"max_attempts": 0}))

en = tr.translate_text(Text=prompt_ko, SourceLanguageCode="ko", TargetLanguageCode="en")["TranslatedText"]
r = sm.invoke_endpoint(EndpointName="<EndpointName>", InferenceComponentName="<InferenceComponentName>",
                       ContentType="application/json", CustomAttributes="route=/v1/images/generations",
                       Body=json.dumps({"prompt": en, "size": "1344x768", "n": 1, "num_inference_steps": 10, "guidance_scale": 4.0}))
png = base64.b64decode(json.loads(r["Body"].read())["data"][0]["b64_json"])
open("result.png", "wb").write(png)
```

- `read_timeout`은 60초보다 길게(예: 65초) 둡니다. boto3 기본값(60초)이면 응답 직전에 끊길 수 있습니다.
- 생성 호출은 SDK 자동 재시도를 끕니다(`max_attempts: 0`). 자동 재시도는 같은 이미지를 한 번 더 만들어 혼잡을 키웁니다.
- Java·Go·Node.js도 같은 API(`InvokeEndpoint`)와 같은 필드를 쓰면 됩니다.
- 전체 예제: [`sm_invoke.py`](sm_invoke.py) (동시 호출 제한, 오류 분류, 동시 요청 테스트 포함)
  ```bash
  export SM_ENDPOINT_NAME=ernie-image SM_INFERENCE_COMPONENT=ernie-image-ic AWS_REGION=ap-northeast-2
  python3 sm_invoke.py prompt_example.txt                          # 1장 → result.png
  python3 sm_invoke.py prompt_example.txt --concurrency 4 --total 24   # 예열·동시 요청 테스트
  ```

### 5-3. 오류와 재시도

| 오류 | 의미 | 조치 |
|---|---|---|
| `ThrottlingException`, `ServiceUnavailable`, `InternalFailure` | 일시적 혼잡 | 1·2·4초 간격 최대 3회 재시도 |
| `ModelError` | 모델 컨테이너 처리 실패 | 1회 재시도. 반복되면 엔드포인트 로그(`/aws/sagemaker/InferenceComponents/<이름>`) 확인 |
| `ReadTimeoutError` / 60초 초과 | 동시 호출 과다 또는 steps 과다 | 최대 1회 재시도. 동시 호출 수와 steps 줄이기 |
| `ValidationError`, `AccessDeniedException` | 이름 오류, 권한 없음 | 재시도하지 말고 설정 확인 |

## 6. 사설망 연결 (인터넷을 거치지 않게)

EKS 노드 서브넷에 아래 VPC 엔드포인트를 만들고 프라이빗 DNS를 켭니다.

| 용도 | 서비스 이름 | 유형 |
|---|---|---|
| 이미지 생성 호출 | `com.amazonaws.<리전>.sagemaker.runtime` | Interface |
| 번역 | `com.amazonaws.<리전>.translate` | Interface |
| Pod Identity 자격 증명 | `com.amazonaws.<리전>.eks-auth` | Interface (Pod Identity 사용 시) |
| IRSA 자격 증명 | `com.amazonaws.<리전>.sts` | Interface (IRSA 사용 시) |
| 결과 이미지를 S3에 저장할 때 | `com.amazonaws.<리전>.s3` | Gateway |

```bash
aws ec2 create-vpc-endpoint --region <리전> --vpc-id <VPC ID> --vpc-endpoint-type Interface \
  --service-name com.amazonaws.<리전>.sagemaker.runtime --subnet-ids <서브넷 ID들> \
  --security-group-ids <노드에서 443 허용> --private-dns-enabled
# translate, eks-auth(또는 sts)도 같은 방식으로 생성
```

- VPC의 DNS 확인과 DNS 호스트 이름이 켜져 있어야 합니다.
- 엔드포인트 정책으로 호출 대상 엔드포인트 ARN을 제한할 수 있습니다.
- **인터넷 경로 차단**: Pod 역할에 `./ernie.sh invoke-policy <vpce-id>` 정책을 붙이면, 그 VPC 엔드포인트를 거치지 않은 호출은 명시적으로 거부됩니다. 실측(서울): VPC 안 경유 호출 성공, 같은 역할의 인터넷 경로 호출은 `AccessDeniedException`.
- **계정 전체 차단**: 관리자 등 다른 사용자·역할까지 인터넷 경로 호출을 막으려면 `./ernie.sh scp-policy <vpce-id>`로 만든 SCP를 조직 관리자가 적용합니다([`../README.md`](../README.md) 7장).
- EKS 환경마다 DNS·보안 그룹 구성이 다릅니다. 실제 연결은 리허설에서 먼저 확인해 주세요.

## 7. 성능과 비용 (실측, 서울)

| 구성 | 동시 호출 | 결과 | 1장 응답 시간 | 분당 생성 수 |
|---|---|---|---|---|
| 2대 (복제본 8개), SageMaker 직접 호출 | 8건 × 16 | **16/16 성공** | p50 22.1초, p95 22.7초 | 약 21장 |
| 같은 구성 | 1건, 20 steps | 성공 | 33.6초 | - |
| 같은 구성, API Gateway 경유(참고) | 8건 × 16 | 14~16/16 | p95 23초 | 약 15~20장 |

- 직접 호출은 API Gateway의 29초 제한이 없어, 같은 동시 수에서 504가 나지 않았습니다.
- 대수 산정: 1대 = 복제본 4개 = 분당 약 10장(10 steps, 실측). 쿼터·비용(대당 약 $16.13/시간, 서울 온디맨드)·대수 증감은 [`../README.md`](../README.md)를 참고해 주세요. 4대 이상은 실측하지 않았으므로 리허설로 확인해 주세요.
- 배포 직후에는 첫 생성이 느립니다. 동시 호출 수 = 복제본 수로 복제본 수 × 6건을 보내 예열해 주세요.

## 8. 앞단을 두는 구성과 비교 (참고)

Lambda나 API Gateway를 앞에 두는 구성은 이 저장소에 포함되어 있지 않습니다. 선택을 돕기 위한 비교입니다.

| 항목 | SageMaker 직접 호출 (이 문서) | Lambda 직접 호출 | API Gateway |
|---|---|---|---|
| 앞단 리소스 | 없음 | Lambda | API Gateway + Lambda |
| 번역 | 애플리케이션이 호출 | Lambda가 처리 | Lambda가 처리 |
| 생성 제한 시간 | 60초 | 58초 | 27초 |
| 동시 처리 상한 | **애플리케이션이 제어** | Lambda 예약 동시성 (초과 시 429) | Lambda 예약 동시성 |
| 이미지 전달 | 응답에 base64 | S3 URL 또는 base64 | S3 URL 또는 base64 |
| 맞는 경우 | EKS 등 자체 서비스가 있고 직접 제어하려는 경우 | 서버는 있지만 번역·저장을 맡기려는 경우 | 외부에서 HTTPS로 호출해야 하는 경우 |
