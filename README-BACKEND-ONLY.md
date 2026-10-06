# MSA 1차 배포용 - Backend Only

이 ZIP은 1차 MSA 배포 실습용이다.

## 포함 서비스
- apigateway
- member-service
- product-service
- ordering-service

## 제거된 항목
- Frontend
- S3 상품 이미지 업로드
- Eureka
- Redis
- Kafka
- Zookeeper

## 1차 실습 확인 방식
브라우저 쇼핑몰 화면이 아니라 Postman으로 API를 확인한다.

- 회원가입: POST /member-service/member/create
- 로그인: POST /member-service/member/doLogin
- 상품 등록: POST /product-service/product/create (JSON)
- 상품 목록: GET /product-service/product/list
- 상품 상세: GET /product-service/product/{id}
- 주문 생성: POST /ordering-service/ordering/create

## 2차 배포
`aws-msa-full-no-eureka-redis-kafka-zookeeper-validated` 버전에서 Frontend + S3를 추가한다.
