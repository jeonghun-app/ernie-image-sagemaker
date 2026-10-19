# Changelog

이 프로젝트의 주요 변경 사항을 기록합니다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를, 버전은 [Semantic Versioning](https://semver.org/lang/ko/)을 따릅니다.

## [1.0.0] - 2026-10-19

처음 공개한 버전입니다. 2026-10 서울·도쿄 리전에서 실측 검증한 스크립트를 바탕으로 합니다.

### Added
- `ernie.sh`: `check`, `install`, `scale`, `status`, `test`, `delete`, `config`, `subnets`, `invoke-policy`, `scp-policy`, `verify-private`, `update-cli`
- `ERNIE_TEST_PROMPT`: `test`에 쓸 프롬프트를 바꾸는 환경 변수
- `eks/sm_invoke.py`의 `SM_SOURCE_LANG`: 프롬프트 언어 지정(`en`이면 Amazon Translate를 건너뜀)
- `policies/`: 작업자 최소 권한, SageMaker 실행 역할(신뢰·권한) 템플릿
- `docs/RUNBOOK_KR.md`(작업 절차서), `docs/TROUBLESHOOTING_KR.md`(문제 해결)
- CI: ShellCheck, Ruff, JSON·YAML 검사, 문서 링크 검사

### Changed
- `REGION`이 비어 있어도 `config`, 도움말, `update-cli`는 실행됩니다. CloudShell 밖에서 `./ernie.sh config set REGION <리전>`으로 먼저 지정할 수 있습니다
- `eks/sm_invoke.py`는 `AWS_REGION`이 없으면 서울 대신 SDK 기본 리전을 씁니다

### Fixed
- 도움말(`./ernie.sh`)에 스크립트 코드 한 줄(`set -euo pipefail`)이 함께 출력되던 문제

[1.0.0]: https://github.com/jeonghun-app/ernie-image-sagemaker/releases/tag/v1.0.0
