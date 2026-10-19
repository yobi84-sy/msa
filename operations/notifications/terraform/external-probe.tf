resource "aws_iam_role" "probe" {
  name               = "sales-mall-dev-availability-probe"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }] })
}
resource "aws_cloudwatch_log_group" "probe" {
  name              = "/aws/lambda/sales-mall-dev-availability-probe"
  retention_in_days = 1
}
resource "aws_iam_role_policy" "probe" {
  role = aws_iam_role.probe.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "cloudwatch:PutMetricData", Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = "Yobi/Availability" } } },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.probe.arn}:*" }
  ] })
}
resource "aws_lambda_function" "probe" {
  function_name    = "sales-mall-dev-availability-probe"
  role             = aws_iam_role.probe.arn
  runtime          = "python3.13"
  handler          = "external_probe.handler"
  filename         = "${path.module}/external-probe.zip"
  source_code_hash = filebase64sha256("${path.module}/external-probe.zip")
  memory_size      = 128
  timeout          = 20
  depends_on       = [aws_iam_role_policy.probe]
}
resource "aws_lambda_function_event_invoke_config" "probe" {
  function_name                = aws_lambda_function.probe.function_name
  maximum_event_age_in_seconds = 60
  maximum_retry_attempts       = 0
}
resource "aws_cloudwatch_event_rule" "probe" {
  name                = "sales-mall-dev-availability-probe"
  schedule_expression = "rate(1 minute)"
}
resource "aws_cloudwatch_event_target" "probe" {
  rule = aws_cloudwatch_event_rule.probe.name
  arn  = aws_lambda_function.probe.arn
}
resource "aws_lambda_permission" "probe" {
  statement_id  = "AllowScheduledAvailabilityProbe"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.probe.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.probe.arn
}
resource "aws_cloudwatch_metric_alarm" "availability" {
  alarm_name          = "sales-mall-dev-https-unavailable"
  namespace           = "Yobi/Availability"
  metric_name         = "HttpsAvailable"
  dimensions          = { Project = "sales-mall-dev" }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = ["arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts"]
  ok_actions          = ["arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts"]
}
