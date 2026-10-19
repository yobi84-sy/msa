terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0, < 7.0" }
  }
}
provider "aws" {
  region              = "ap-northeast-2"
  profile             = "eks-user"
  allowed_account_ids = ["021158485482"]
}
variable "email" {
  type    = string
  default = ""
}
variable "sms_phone" {
  type      = string
  sensitive = true
  default   = ""
  validation {
    condition     = var.sms_phone == "" || can(regex("^\\+[1-9][0-9]{7,14}$", var.sms_phone))
    error_message = "Use a verified E.164 destination or leave SMS disabled."
  }
}
data "aws_eks_cluster" "current" { name = "sales-mall-dev-eks" }
data "aws_db_instance" "current" { db_instance_identifier = "sales-mall-dev-mysql" }
locals {
  oidc = replace(data.aws_eks_cluster.current.identity[0].oidc[0].issuer, "https://", "")
}
resource "aws_sns_topic" "orders_email" { name = "sales-mall-dev-orders-email" }
resource "aws_sns_topic" "orders_sms" { name = "sales-mall-dev-orders-sms" }
resource "aws_sns_topic_subscription" "orders_email" {
  count     = var.email == "" ? 0 : 1
  topic_arn = aws_sns_topic.orders_email.arn
  protocol  = "email"
  endpoint  = var.email
}
resource "aws_sns_topic_subscription" "orders_sms" {
  count     = nonsensitive(var.sms_phone == "") ? 0 : 1
  topic_arn = aws_sns_topic.orders_sms.arn
  protocol  = "sms"
  endpoint  = var.sms_phone
}
resource "aws_iam_role" "publisher" {
  for_each           = { ordering = "soldesk:order-notifications", alertmanager = "monitoring:yobi-alertmanager" }
  name               = "sales-mall-dev-${each.key}-sns"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRoleWithWebIdentity", Principal = { Federated = "arn:aws:iam::021158485482:oidc-provider/${local.oidc}" }, Condition = { StringEquals = { "${local.oidc}:aud" = "sts.amazonaws.com", "${local.oidc}:sub" = "system:serviceaccount:${each.value}" } } }] })
}
resource "aws_iam_role_policy" "publish" {
  for_each = aws_iam_role.publisher
  role     = each.value.id
  policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sns:Publish", Resource = each.key == "ordering" ? [aws_sns_topic.orders_email.arn, aws_sns_topic.orders_sms.arn] : ["arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts"] }] })
}
resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "sales-mall-dev-rds-storage-low"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = data.aws_db_instance.current.id }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = data.aws_db_instance.current.allocated_storage * 1024 * 1024 * 1024 * 0.2
  treat_missing_data  = "missing"
  alarm_actions       = ["arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts"]
  ok_actions          = ["arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts"]
}
resource "aws_cloudwatch_metric_alarm" "rds_memory" {
  alarm_name          = "sales-mall-dev-rds-memory-low"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = data.aws_db_instance.current.id }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "LessThanThreshold"
  threshold           = 128 * 1024 * 1024
  treat_missing_data  = "missing"
  alarm_actions       = ["arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts"]
  ok_actions          = ["arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts"]
}
output "ordering_role" { value = aws_iam_role.publisher["ordering"].arn }
output "alertmanager_role" { value = aws_iam_role.publisher["alertmanager"].arn }
output "orders_email_topic" { value = aws_sns_topic.orders_email.arn }
output "orders_sms_topic" { value = nonsensitive(var.sms_phone == "") ? "" : aws_sns_topic.orders_sms.arn }
