# =========================================================
# Route 53 - 기존 Hosted Zone 조회
# 기존 sy84.store 영역은 생성하거나 삭제하지 않음
# =========================================================

data "aws_route53_zone" "sy84" {
  zone_id = "Z03158761YPLKM1NEY8PO"
}

# =========================================================
# ACM - HTTPS 인증서 생성
# =========================================================

resource "aws_acm_certificate" "server" {
  domain_name       = "*.sy84.store"
  validation_method = "DNS"

  tags = {
    Name = "${local.name_prefix}-server-acm"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =========================================================
# Route 53 - ACM DNS 검증 레코드 자동 생성
# =========================================================

resource "aws_route53_record" "server_acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.server.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.sy84.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

# =========================================================
# ACM - DNS 검증 완료 대기
# =========================================================

resource "aws_acm_certificate_validation" "server" {
  certificate_arn = aws_acm_certificate.server.arn

  validation_record_fqdns = [
    for record in aws_route53_record.server_acm_validation :
    record.fqdn
  ]
}

# =========================================================
# Output - 발급된 ACM 인증서 ARN
# =========================================================

output "acm_server_certificate_arn" {
  value = aws_acm_certificate.server.arn
}
