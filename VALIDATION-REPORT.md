> **이전 단계 기록** · Backend-only 실습 당시 문서입니다. 현재 구성과 실행 범위는 [프로젝트 README](README.md)와 [실행 안내](docs/runbook.md)를 확인하세요.

# Backend-only validation report

- frontend directory removed
- frontend GitHub Actions steps removed
- frontend ArgoCD application removed
- ingress `/` -> frontend-service route removed
- S3 config/service/dependency/Kubernetes secret references removed
- API Gateway default profile set to `prod`
- `application-prod-uri.yml` removed
- Eureka/Redis/Kafka/Zookeeper strings and related files expected to be absent
- Backend services retained: apigateway, member, product, ordering
