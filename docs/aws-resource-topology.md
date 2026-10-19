# AWS 생성 리소스와 상세 동작

[프로젝트 홈](../README.md) · [전체 구성](architecture.md) · [선언 전체 목록](aws-resource-inventory.md) · [알림 구성](observability.md)

기존 전체 구성도는 서비스 흐름을 요약합니다. 이 문서는 **실제 Terraform 선언을 기준으로 네트워크 배치, 생성 주체, 권한과 요청 흐름**을 풀어 설명합니다. 실행 중인 AWS 환경을 조회한 그림은 아니며, 코드의 조건에 따라 생성 여부와 개수가 달라집니다.

[![AWS 리소스 상세 토폴로지](assets/aws-resources-detail.png)](assets/aws-resources-detail.png)

[확대 PNG](assets/aws-resources-detail.png) · [편집 가능한 SVG](assets/aws-resources-detail.svg)

그림의 AWS 관리 서비스는 논리적으로 배치했습니다. IAM·Route 53·CloudFront는 전역 서비스이며, 오른쪽 서비스 상자는 VPC 내부 배치를 뜻하지 않습니다. AZ ①/②는 변수 배열 순서입니다. `a`/`b`라는 서브넷 키가 실제 AZ 이름의 a/b 접미사를 뜻하지는 않습니다.

## 1. 무엇을 어디에 만드는가

| 영역 | 생성·조회 대상 | 배치와 역할 | 소스 |
| --- | --- | --- | --- |
| 네트워크 | VPC 1, Public 2, Private 2 | VPC `10.0.0.0/16`; 서로 다른 두 AZ에 Public `1/2`, Private `11/12` 대역 | [network.tf](../terraform/network.tf) |
| 인터넷 경로 | IGW 1, Public RT 1, Private RT 2 및 경로·연결 | Public → IGW, 두 Private → 같은 NAT | [routing.tf](../terraform/routing.tf) |
| 외부 송신 | NAT Gateway 1, EIP 1 | Public a에 배치. Private 노드의 외부 다운로드 등에 사용 | [nat.tf](../terraform/nat.tf) |
| 클러스터 | EKS 1, Managed Node Group 1 | AWS 관리 control plane + Private 워커. 노드는 `t3.medium`, desired 3 / min 2 / max 6 | [eks.tf](../terraform/eks.tf), [nodegroup](../terraform/eks-nodegroup.tf) |
| 클러스터 기본 기능 | VPC CNI, CoreDNS, kube-proxy, Metrics Server add-on | Pod 네트워크·내부 DNS·Service 통신·리소스 지표 | [add-ons](../terraform/eks-addons.tf), [metrics](../terraform/eks-metrics-server.tf) |
| 외부 진입 | Helm NGINX + LoadBalancer Service → NLB | NLB는 LB Controller가 생성. 두 Public 서브넷, internet-facing, IP target. NGINX 2개가 TLS와 경로 분기 담당 | [NGINX](../terraform/eks-nginx-helm.tf), [controller](../terraform/eks-alb-helm.tf) |
| 이름·인증서 | 기존 Hosted Zone 조회, Alias·검증 레코드, ACM 인증서 | `server/grafana/argocd` Alias는 DNS 활성화 변수에 따라 생성. 웹 TLS는 cert-manager DNS-01 → Secret | [DNS](../terraform/route53-nlb.tf), [ACM](../terraform/acm.tf), [TLS](../terraform/eks-cert-manager-tls.tf) |
| DB | DB Subnet Group, RDS 1, SG·ingress rules | 두 Private 서브넷을 후보로 사용하지만 인스턴스는 Single-AZ 1대. AZ를 코드에서 고정하지 않음 | [rds.tf](../terraform/rds.tf), [security.tf](../terraform/security.tf) |
| 이미지 원본 | S3 버킷, Public Access Block, AES256, 버킷 정책 | 비공개 상품 이미지. Product는 IRSA로 업로드, CloudFront만 OAC로 원본 조회 | [s3.tf](../terraform/s3.tf), [OAC·정책](../terraform/s3-cloudfront.tf) |
| 이미지 전달 | CloudFront distribution, OAC | 전역 Edge에서 상품 이미지 캐시. 쇼핑몰 HTML/API 전체를 캐시하지 않음 | [s3-cloudfront.tf](../terraform/s3-cloudfront.tf) |
| 이미지 저장소 | ECR repository 5개 | 서비스별 immutable 이미지 태그, push 시 scan | [ecr.tf](../terraform/ecr.tf) |
| 실행 권한 | EKS/GitHub OIDC provider, IAM role·policy·attachment, EKS access | 클러스터·노드·CI·각 AWS 연동 도구의 권한 분리 | [EKS IAM](../terraform/eks-iam.tf), [GitHub OIDC](../terraform/github-oidc.tf), [CI role](../terraform/github-actions-iam.tf) |
| 기본 경보 | CloudWatch RDS CPU alarm, SNS alerts, 조건부 이메일 구독 | 평균 CPU > 80%, 300초 × 3. 이메일은 변수 입력과 구독 확인 필요 | [yobi-alerts.tf](../terraform/yobi-alerts.tf) |

RDS는 MySQL 8.4 / `db.t4g.micro` / 암호화된 20 GiB gp3, 외부 공개 비활성화, 백업 보존 1일입니다. 현재 `skip_final_snapshot=true`이므로 **기본 destroy가 최종 DB 스냅샷을 보장하지 않습니다.** 통합 실행 패키지의 별도 백업 절차와 기본 Terraform 설정을 구분해야 합니다.

## 2. 누가 생성하고 누가 유지하는가

| 관리 주체 | 담당 | 구분해야 할 점 |
| --- | --- | --- |
| Terraform AWS provider | VPC·IAM·EKS·RDS·S3·ECR·CloudFront·DNS·기본 경보 | 실제 선언 전체는 [리소스 목록](aws-resource-inventory.md) 참조 |
| Terraform Helm / Kubernetes provider | Argo CD·NGINX·cert-manager·LB Controller·Autoscaler, namespace·Ingress·ConfigMap | Helm release 하나가 여러 Kubernetes 객체를 생성 |
| EKS Managed Node Group | 노드 EC2·관련 ASG | 직접 작성한 `aws_instance` 리소스와 구분 |
| AWS Load Balancer Controller | NGINX Service에 대응하는 NLB·target group 등 | `data.aws_lb`는 생성된 NLB 조회. 이름에 alb가 있어도 이 진입점은 NLB |
| Argo CD | GitOps의 앱·모니터링 선언 | 앱 소유권과 replicas 무시 설정으로 HPA와의 충돌 방지 |
| HPA / Cluster Autoscaler | HPA는 Pod 수, Autoscaler는 노드 수 | Pod 증가와 노드 증가는 같은 동작이 아니며 노드 증설은 스케줄 불가 Pod 등의 조건에 좌우됨 |
| cert-manager | ACME 인증서 발급·갱신, TLS Secret, DNS-01 검증 | ACM 인증서와 별도 경로 |

[Argo 앱](../argocd/apps/yobi-v1-msa.yml) · [HPA 선언](../msa/k8s/k8s-hpa) · [Autoscaler](../terraform/eks-cluster-autoscaler.tf) · [상품 IRSA](../terraform/eks-product-s3-iam.tf)

## 3. 요청 한 번이 이동하는 순서

| 그림 번호 | 흐름 | 실제 동작 |
| --- | --- | --- |
| ① | 브라우저 → NLB | 먼저 Route 53에서 주소를 조회하고 NLB에 직접 HTTPS 연결. DNS가 HTTP를 중계하지 않음 |
| ② | NLB → NGINX → Frontend / Gateway | NLB는 IP target으로 전달, NGINX는 Secret으로 TLS 종료. `/`는 Frontend, 서비스 API 접두사는 Spring Cloud Gateway |
| ③ | Gateway → Member / Product / Ordering | Gateway는 접두사를 제거하고 Kubernetes Service DNS로 내부 API 호출. AWS API Gateway 서비스가 아님 |
| ④ | 서비스 → RDS | SG가 Private CIDR의 TCP 3306을 허용. 회원·상품·주문이 같은 DB 테이블 집합을 공유 |
| ⑤ | Product → S3 / 브라우저 → CloudFront → S3 | 업로드 권한은 IRSA, 원본 읽기는 OAC와 버킷 정책. 이미지 경로는 앱 API와 분리 |
| ⑥ | RDS 지표 → CloudWatch → SNS | 기본 CPU 경보가 ALARM으로 바뀌면 이메일 전달. 기본 파일에는 OK 알림 action이 없음 |
| ⑦ | 주문 → DB Outbox → SNS → 수신자 | 주문과 발송 대기 기록을 같은 트랜잭션에 저장한 뒤 별도 발송 작업. 추가 패키지의 토픽·권한·구독 필요 |

[Ingress 경로](../terraform/eks-msa-ingress.tf) · [Gateway 설정](../msa/apigateway/src/main/resources/application-prod.yml) · [주문 처리](../msa/ordering/src/main/java/com/example/ordersystem/ordering/service/OrderingService.java)

## 4. 설치·배포 시 준비되는 순서

1. AWS·GitHub 인증과 입력 값을 확인하고 VPC·서브넷·라우팅·권한을 준비합니다.
2. EKS control plane과 OIDC, NAT 경로·노드 권한을 기반으로 Managed Node Group과 add-on을 구성합니다.
3. Helm으로 Controller·NGINX·cert-manager·Argo CD 등 클러스터 도구를 구성합니다. NGINX Service를 보고 Controller가 NLB를 생성합니다.
4. 생성된 NLB를 조회해 Alias를 연결하고 인증서 Secret·Ingress를 준비합니다. DNS 활성화 단계의 변수와 NLB 준비 여부를 함께 확인합니다.
5. Actions가 다섯 이미지를 ECR에 게시하고 GitOps 태그를 갱신합니다. Argo CD가 Git 선언을 적용하고 노드가 ECR 이미지를 가져옵니다.
6. 앱·DB·상품 이미지·관측·알림을 각각 확인합니다. 패치는 인프라를 전부 다시 만드는 대신 검토한 앱·DB 변경을 적용합니다.

위 순서는 의존관계를 설명한 것이며 Terraform이 모든 리소스를 한 줄씩 직렬 실행한다는 뜻은 아닙니다. 독립 리소스는 병렬 생성합니다. 실행 명령과 공개 소스/통합 패키지의 차이는 [실행 안내](runbook.md)에 정리했습니다.

## 5. 추가 알림과 기본 구성의 경계

공개 `terraform/yobi-alerts.tf`는 RDS CPU·SNS 이메일 기본 경보입니다. 통합 실행 패키지에는 RDS 저장 공간·메모리, EventBridge 예약 → Lambda 접속 검사, 주문 이메일/SMS 토픽·구독·발행 권한 등 추가 구성이 있습니다. 이 추가 Terraform 소스 전체가 공개 저장소의 기본 `terraform/`에 포함된 것은 아닙니다.

Pod·노드·Argo 규칙은 [모니터링 선언](../msa/k8s/k8s-monitoring/alerts-resources.yml)과 [알림 설명](observability.md)을 함께 확인해야 합니다. 규칙 파일 존재만으로 실제 수신까지 검증되었다고 판단하지 않습니다. 이메일은 토픽별 최초 구독 확인이 필요하며, SMS는 계정·지역·샌드박스·번호·발송 조건이 충족되어야 합니다.

SQS·DLQ는 현재 구현하지 않았습니다. Outbox가 SQS를 사용한다는 뜻도 아닙니다. 도입 조건과 방법은 [확장 검토](extensions.md)에 있습니다.

## 6. 배치에서 읽어야 할 한계

- 두 AZ에 서브넷을 두었지만 NAT는 1개, RDS는 Single-AZ입니다.
- 노드와 Pod의 AZ별 개수를 고정하거나 모든 서비스의 최소 두 파드를 보장하지 않습니다.
- EKS API는 public·private가 활성화되어 있습니다. 운영용 접근 제한은 별도 검토 대상입니다.
- RDS SG는 앱 보안 그룹 참조 대신 Private CIDR을 허용합니다. 서비스별 독립 DB와 세밀한 네트워크 격리는 추가 개선 영역입니다.
- 선언 목록·구성도는 코드의 의도를 설명합니다. 실제 생성·삭제·건강 상태는 실행 당시의 plan/state와 AWS 조회로 따로 검증해야 합니다.
