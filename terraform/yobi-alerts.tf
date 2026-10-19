# [Yobi V1 AWS 경보] CloudWatch RDS CPU Alarm -> SNS 이메일 구독 구성
# 이메일 구독은 수신자가 확인 메일을 승인해야 활성화됨 (SMS 미포함)
# 이 파일은 AWS Budget 전체 설정이나 Pod 재시작 경보까지 포함하지 않음
# Optional low-cost RDS CPU alert (SNS email requires manual subscription confirmation).
variable "yobi_alert_email" {
  description = "Email recipient of RDS CPU alerts; empty string disables SNS subscription."
  type        = string
  default     = ""
}
resource "aws_sns_topic" "yobi_alerts" {
  name = "${local.name_prefix}-alerts"
}
resource "aws_sns_topic_subscription" "yobi_email" {
  count     = var.yobi_alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.yobi_alerts.arn
  protocol  = "email"
  endpoint  = var.yobi_alert_email
}
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  alarm_actions       = [aws_sns_topic.yobi_alerts.arn]
  ok_actions          = [aws_sns_topic.yobi_alerts.arn]
  treat_missing_data  = "missing"
}
