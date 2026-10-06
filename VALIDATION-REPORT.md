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
