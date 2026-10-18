# 실행 안내

[프로젝트 홈](../README.md) · [배포 과정](delivery.md) · [운영 편의 도구](tools.md)

## 공개 저장소와 통합 실행 패키지

이 저장소의 기본 브랜치는 `yobi-v1`이며 앱은 4차 복구 이후 상태입니다. 앱 소스·Terraform·GitOps 선언·실제 Actions 기록을 공개합니다.

별도 로컬 **`msa_sy_final` 통합 실행 패키지**는 최신 GUI, 준비 상품/이미지, 세 패치 JSON/ZIP, 알림 생성기와 보완된 설치·삭제 스크립트를 함께 갖고 있습니다. **공개 저장소를 clone한 것만으로 이 패키지가 생기는 것은 아닙니다.** GUI·패치 원본·개인 설정을 문서 작업 중 임의로 게시하지 않았습니다.

| 항목 | 공개 저장소 | 통합 실행 패키지 |
| --- | --- | --- |
| 앱·Dockerfile·배포 YAML | 있음, 복구 이후 코드 | 1차 기준본 및 패치로 단계 전개 |
| Terraform·GitOps | 있음 | 실습용 설정·최신 보완과 함께 사용 |
| 운영 알림 | 생성된 모니터링 선언·RDS CPU 설정 | 생성기·추가 알림 Terraform·최초 설치 연계 포함 |
| GUI·검토 패치 JSON/ZIP | 이번 문서 게시 범위에 포함하지 않음 | 있음 |
| 단일 HTML 애니메이션 | [다운로드 파일](demo/msa-flow.html) | 있음 |

예전 [Backend-only 안내](../README-BACKEND-ONLY.md)와 [당시 검증 보고서](../VALIDATION-REPORT.md)는 과거 단계 기록입니다. 현재의 다섯 서비스·이미지·알림 구성을 설명하는 최신 안내로 사용하지 않습니다.

## 준비

Windows PowerShell 5.1, Git, GitHub CLI, AWS CLI, Terraform 1.11 이상, kubectl, Python 3을 준비합니다. CLI로 소스를 읽거나 앱 테스트만 할 때와 AWS 전체 설치에 필요한 도구 범위는 다릅니다.

```powershell
# 인증 상태와 클라이언트 준비 확인. 리소스를 생성하지 않습니다.
aws sts get-caller-identity --profile eks-user --region ap-northeast-2
gh auth status
terraform version
kubectl version --client
```

프로젝트는 특정 AWS 계정·도메인·ECR·IAM 신뢰 정책을 사용합니다. 다른 계정에서는 이 값들과 OIDC/IRSA·DNS·인증서·메일 수신 대상을 먼저 검토해야 합니다. 비밀번호·키·tfvars·state를 GitHub에 올리지 않습니다.

## 통합 패키지에서 진행할 순서

1. GUI 또는 수동 입력 가이드에서 대상 계정·계획을 확인합니다.
2. 1차 설치: 인프라 → Secret → 기준 소스 빌드 → Argo/Ready/HTTPS/상품 → 알림 구성.
3. 장애용·주문용 SNS 확인 메일을 각각 승인합니다.
4. `adidas-mall-upgrade`: 화면·주문·메일 확인.
5. `soldout-visibility-incident`: 품절 공개 저장 실패와 다른 기능 구분.
6. `soldout-visibility-recovery`: 같은 기능의 복구 확인.
7. 실습 종료 시 백업/초기화 정책을 정하고 검토한 삭제 절차를 진행합니다.

최신 통합 GUI의 **수동 입력 가이드**는 스크립트 실행과 Terraform·kubectl 분해 학습을 구분합니다. 터미널의 패치/삭제 승인은 패치 ID·VPC ID를 포함하는 전체 문구를 요구할 수 있어 GUI의 짧은 입력과 다릅니다.

## 직접 확인할 명령

아래는 이미 설치된 정확한 환경에서 읽기 상태를 확인하는 예입니다. 먼저 kubeconfig가 의도한 클러스터인지 확인합니다.

```powershell
kubectl config current-context
kubectl get nodes
kubectl get applications -n argocd
kubectl get deployments,pods -n soldesk
kubectl get hpa -n soldesk
kubectl get pods -n monitoring
```

Actions success → Argo revision/Synced → Ready → HTTPS → 실제 기능 → 이메일 수신을 따로 확인합니다. 도메인 접속은 인프라가 설치된 동안에만 가능합니다.

## 삭제할 때

Terraform state 파일을 먼저 지우지 않습니다. RDS와 S3의 **BACKUP/RESET** 보존 정책을 정하고, 앱/알림·DNS/NLB·주 인프라의 순서와 정확한 삭제 대상을 확인합니다. 백업을 선택했다면 보존된 스냅샷·S3 객체가 따로 남을 수 있습니다.

공개 저장소의 예전 스크립트를 최신 통합 삭제 절차와 동일하게 가정해 실행하지 않습니다. [write-only 비밀번호 버전 문제](troubleshooting.md#삭제-계획과-write-only-db-비밀번호-버전)처럼 통합본에 보완된 항목이 있습니다. 통합본의 최신 실행 안내와 계획을 기준으로 진행합니다.
