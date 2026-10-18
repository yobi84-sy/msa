# 확장 검토 사항

[프로젝트 홈](../README.md) · [현재 구성](architecture.md) · [검증 범위](validation.md)

아래 항목은 **추가 가능한 설계안**입니다. 현재 적용 완료 기능과 구분하며, 이 문서 게시로 AWS 리소스나 앱 동작을 변경하지 않았습니다. 난도는 설정 파일 수정뿐 아니라 앱 변경·이관·검증까지 포함합니다.

## 먼저 무엇을 추가할지

| 항목 | 현재 단계에서 먼저 넣지 않은 이유 | 필요해지는 상황 | 추가 방향 | 난도 |
| --- | --- | --- | --- | --- |
| **SQS·DLQ** | DB Outbox와 재시도로 현재 주문 알림 실습 가능 | 발송 작업 분리, 처리량 완충, 실패 메시지 재처리 | 학습용 SNS→SQS부터 시작, 이후 전용 소비자 | 학습 경로 낮음 / 운영 경로 중간 |
| **S3 원격 state·잠금** | 현재 실행은 로컬 state 기반, 팀 동시 수정 절차 미구성 | 여러 PC·작업자가 같은 인프라 관리 | state 전용 버킷·권한·키 분리·잠금 후 이관 | 중간 |
| **RDS Multi-AZ** | 현재 DB는 Single-AZ 실습 범위 | AZ/인스턴스 장애 시 자동 failover 필요 | `multi_az=true` 계획 검토, 전환·재연결 시험 | 설정 낮음 / 검증 중간 |
| **AZ별 NAT** | NAT 1개로 리소스 수를 줄인 구성 | 한 AZ의 NAT 장애가 다른 AZ에 미치는 영향 감소 | AZ별 EIP/NAT와 Private 라우트 연결 | 중간 |
| **복제·PDB·분산 배치** | HPA 최소 1개이며 일부 서비스 단일 파드 | 노드 drain·점검 중 서비스 유지 목표 | 최소 2개, readiness 확인, PDB·topology spread | 중간 |
| **Redis 캐시** | 현재는 DB 기반 기능 검증 단계, 캐시 도입을 정당화할 성능 측정 없음 | 반복 상품 조회로 DB 지연·CPU 병목이 확인됨 | 읽기 캐시부터 적용, TTL·무효화·장애 우회 | 중간 |

## SQS: 지금도 알림이 오는데 왜 추가할까?

현재는 `주문·Outbox commit → 앱 발송 작업 → SNS`입니다. SNS 수락 실패는 Outbox에 기록하고 다시 시도합니다. 주문 직후 발송할 수 있다는 이유만으로 큐가 필수인 것은 아닙니다.

SQS를 추가하면 앱과 후속 작업의 실행 속도를 분리하고, 소비자를 중단했다가 다시 처리하거나 반복 실패 메시지를 DLQ에 모으는 실습을 할 수 있습니다. 다만 **SQS가 이메일·문자를 직접 발송하는 것은 아닙니다.**

### A. 기존 주문 알림을 유지하는 큐 학습

```text
별도 실습 SNS 토픽 → SQS 주 큐 → 수동/테스트 소비자
                         ↘ 반복 처리 실패 → SQS DLQ
```

1. 별도 실습 토픽·주 큐·DLQ를 Terraform으로 만듭니다.
2. 큐 정책은 해당 토픽 ARN의 `sns.amazonaws.com` 발신만 허용합니다.
3. SNS의 SQS 구독을 연결합니다. raw message delivery 여부를 정하고 소비자에서 원문/SNS envelope 처리 방식을 맞춥니다. 주 큐의 `redrive_policy`는 소비자 실패 시 DLQ로 이동시킵니다.
4. 테스트 메시지 한 건을 게시하고 수신→처리→삭제를 확인합니다.
5. 삭제하지 않고 visibility timeout을 지나 다시 수신하는 경우와, 반복 실패 후 DLQ 이동을 확인합니다.

이 경로는 기존 주문 이메일의 코드를 바꾸지 않아 시작하기 쉽습니다. **기존 주문 처리에 큐를 연결한 결과와는 구분해서 기록합니다.** SNS가 SQS로 전달하지 못하는 실패를 보관하는 SNS 구독 DLQ와, 소비자가 처리하지 못하는 SQS 주 큐의 DLQ도 별개입니다.

[SNS 구독 DLQ](https://docs.aws.amazon.com/sns/latest/dg/sns-dead-letter-queues.html) · [SQS visibility timeout](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html)

<details>
<summary>주 큐·DLQ의 Terraform 설정 예시 보기</summary>

미적용 발췌 예시입니다. SNS 토픽·구독·큐 정책·IAM과 소비자 구성이 별도로 필요합니다. 기존 Terraform에 복사해 바로 적용하는 완성본은 아닙니다.

```hcl
resource "aws_sqs_queue" "practice_dlq" {
  name                      = "sales-mall-dev-practice-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "practice" {
  name                       = "sales-mall-dev-practice"
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 60
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.practice_dlq.arn
    maxReceiveCount     = 3
  })
}
```

큐 정책에는 `sqs:SendMessage`, principal `sns.amazonaws.com`, 정확한 토픽의 `aws:SourceArn` 조건을 둡니다. 소비자는 처리 성공 후 메시지를 삭제하고, DLQ의 `ApproximateNumberOfMessagesVisible > 0`도 경보로 관찰합니다. [AWS SNS→SQS 연결](https://docs.aws.amazon.com/sns/latest/dg/subscribe-sqs-queue-to-sns-topic.html)

</details>

### B. 주문 발송 작업을 실제로 분리

```text
주문·Outbox commit → 큐 게시 작업 → SQS → 별도 발송 소비자 → 기존 SNS 이메일/SMS 토픽
                                      ↘ 처리 반복 실패 → DLQ
```

Outbox를 없애고 주문 트랜잭션 안에서 곧바로 SQS를 호출하면 DB commit과 메시지 게시가 어긋날 수 있습니다. Outbox를 유지한 채 게시 대상을 바꾸고, 별도 소비자는 전송 성공 후 메시지를 삭제하도록 만듭니다.

추가 작업은 Queue/DLQ, 게시자·소비자의 범위 제한 IAM/IRSA, 소비자 Deployment 또는 Lambda, 처리 시간에 맞는 visibility timeout, 재시도 정책입니다. 메시지 ID/주문 ID·채널별 중복 방지와 현재 SMS 시도 한도도 소비자 쪽에 유지해야 합니다. **QUEUED·SNS accepted·실제 수신의 상태 의미를 분리**하고 큐 적체·오래된 메시지·DLQ 수를 모니터링합니다.

검증: 소비자 중지 중 주문 → 큐 적재 → 재시작 처리, 처리 직후 프로세스 중단/중복 수신, 실패 DLQ 이동, 재처리, 이메일·문자 도착을 각각 확인합니다. SQS도 중복 전달 가능성이 있어 소비자의 멱등성 검사가 필요합니다.

## S3 원격 state: 여러 PC에서 같은 자원 관리

현재 `terraform/`에 S3 backend 선언이 없습니다. 상품 이미지 버킷을 state 저장소로 겸용하지 않고 전용 버킷을 준비합니다. 버전 관리·접근 차단·최소 권한을 적용하고 state에는 민감한 내용이 있을 수 있으므로 공개하지 않습니다.

검토할 선언 예시는 아래와 같습니다. **미적용 예시**이며 버킷 생성·정확한 state 백업·계정/리전 확인이 먼저입니다.

```hcl
terraform {
  backend "s3" {
    bucket       = "<reviewed-state-bucket>"
    key          = "sales-mall/dev/infra.tfstate"
    region       = "ap-northeast-2"
    profile      = "eks-user"
    encrypt      = true
    use_lockfile = true
  }
}
```

이관은 실행을 멈추고 백업한 뒤 `terraform init -migrate-state`로 수행합니다. 메인/알림 Terraform state는 서로 다른 key로 분리하고, state와 lock 객체 권한을 함께 검토합니다. 두 작업자가 동시에 계획을 실행해 잠금이 동작하는지도 확인합니다. 동시 실행 중 lock 파일을 임의로 삭제하지 않습니다. [HashiCorp S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)

## 가용성: DB·네트워크·파드를 각각 보완

### RDS Multi-AZ

[현재 RDS](../terraform/rds.tf)의 `multi_az=false`를 출발점으로 변경 계획을 검토합니다. standby는 failover용이며 일반 읽기 분산용 read replica와 구분합니다. 변경 자체는 작아도 비용·전환 영향과 앱 DB 연결 재시도를 확인해야 합니다. 검증 환경에서 failover 후 재접속·주문 중복/실패·알람을 확인합니다. [AWS Multi-AZ](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html)

### AZ별 NAT

[현재 NAT](../terraform/nat.tf)는 하나입니다. `aws_eip`·`aws_nat_gateway`를 AZ별 `for_each`로 만들고 Private route table이 자기 AZ의 NAT를 참조하도록 바꿉니다. 잘못된 AZ 매핑이나 경로 교체 중 외부 통신 중단을 확인해야 합니다. 고정 비용이 늘어나므로 짧은 실습 목표와 가용성 목표를 함께 판단합니다. [AWS NAT 기본 동작](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-basics.html)

### 최소 복제 수·PDB·분산

HPA의 `minReplicas=2`와 실제 자원 여유를 먼저 검토합니다. 한 파드에 `minAvailable=1` PDB만 추가하면 drain이 막힐 수 있습니다. readiness, 종료 대기, AZ/노드 분산을 함께 설정하고 승인된 drain 실습 동안 요청 성공률을 측정합니다. PDB는 자발적 중단을 제한하며 모든 노드 장애나 무중단을 보장하지 않습니다. [Kubernetes PDB](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)

## Redis는 먼저 측정한 뒤

상품 목록/상세처럼 반복 읽기가 많은 경로를 먼저 측정하고 도입합니다. 초기에는 짧은 TTL의 읽기 캐시로 범위를 좁히고, 상품 수정·품절 공개·재고 변경 때의 무효화를 설계합니다. **주문 재고의 정확성은 현재 DB 트랜잭션에서 유지**하며 캐시 값만으로 확정하지 않습니다.

추가 순서는 Redis 배치 방식·보안 그룹 결정 → Spring Cache 연결 → 키/TTL → 무효화 → Redis 장애 시 DB 우회 → 지연·DB 부하·오래된 데이터 비교입니다. 측정 없이 Redis가 더 빠르거나 더 싸다고 결론내리지 않습니다. [Spring Data Redis Cache](https://docs.spring.io/spring-data/redis/reference/4.2/redis/redis-cache.html)

## 적용 우선순위를 정하는 기준

팀/PC 간 인프라 공유가 먼저라면 원격 state, 메시징 학습이 목표라면 별도 SQS 실습 경로, 서비스 지속성이 목표라면 복제·PDB·DB/네트워크 이중화를 먼저 검토합니다. 서비스 수를 늘리는 것 자체보다 **어떤 문제를 해결하고 무엇으로 검증할지**를 먼저 정합니다. 구체 비용은 계정·리전·사용량에 맞춰 적용 전 확인합니다.
