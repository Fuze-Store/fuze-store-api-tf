# ============================================================================
# Observability & backups
#  - SNS alerts topic (+ optional email subscription)
#  - CloudWatch alarms: SQS DLQ/backlog, RDS, EC2 status + CPU, DynamoDB throttle
#  - DLM daily EBS snapshots for both EC2 instances
# ============================================================================

# --------------------
# SNS alerts topic
# --------------------
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = {
    Environment = var.environment
  }
}

# Email subscription (only created when alert_email is set). Confirm the
# subscription from your inbox after the first apply.
resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --------------------
# SQS alarms
# --------------------

# Anything in the dead-letter queue means jobs are failing past all retries.
resource "aws_cloudwatch_metric_alarm" "sqs_dlq_not_empty" {
  alarm_name          = "${local.name_prefix}-sqs-dlq-not-empty"
  alarm_description   = "Messages present in the Laravel DLQ (jobs failed past max retries)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.laravel_queue_dlq.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Environment = var.environment }
}

# A backlog that isn't draining (worker down / overloaded). broadcasts age is the
# Reverb/Soketi backpressure canary the scale docs call out.
resource "aws_cloudwatch_metric_alarm" "sqs_backlog_age" {
  for_each = local.laravel_queues

  alarm_name          = "${local.name_prefix}-sqs-${each.key}-backlog-age"
  alarm_description   = "Oldest message in the ${each.key} queue exceeds 5 minutes (jobs not draining)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.laravel_queue[each.key].name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Environment = var.environment }
}

# --------------------
# RDS alarms
# --------------------
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPU sustained above 80%."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = module.rds.db_instance_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Environment = var.environment }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-storage-low"
  alarm_description   = "RDS free storage below 5 GB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5 * 1024 * 1024 * 1024 # 5 GB in bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = module.rds.db_instance_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Environment = var.environment }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${local.name_prefix}-rds-connections-high"
  alarm_description   = "RDS connection count approaching the small-instance ceiling (add PgBouncer/RDS Proxy before scaling app nodes)."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 150 # db.t4g.small max_connections is a few hundred; alert well before the cliff
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = module.rds.db_instance_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Environment = var.environment }
}

# --------------------
# EC2 alarms (both boxes)
# --------------------
locals {
  ec2_instances = {
    api       = aws_instance.laravel.id
    websocket = aws_instance.websocket.id
  }
}

# System status check failure → recover the instance in place + notify.
resource "aws_cloudwatch_metric_alarm" "ec2_system_check" {
  for_each = local.ec2_instances

  alarm_name          = "${local.name_prefix}-ec2-${each.key}-system-check"
  alarm_description   = "EC2 ${each.key} system status check failed — auto-recovering."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = each.value
  }

  # EC2 auto-recovery + notify
  alarm_actions = [
    "arn:aws:automate:${var.aws_region}:ec2:recover",
    aws_sns_topic.alerts.arn,
  ]

  tags = { Environment = var.environment }
}

# Instance status check failure (guest OS level) → notify (not auto-recoverable).
resource "aws_cloudwatch_metric_alarm" "ec2_instance_check" {
  for_each = local.ec2_instances

  alarm_name          = "${local.name_prefix}-ec2-${each.key}-instance-check"
  alarm_description   = "EC2 ${each.key} instance status check failed."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Environment = var.environment }
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu_high" {
  for_each = local.ec2_instances

  alarm_name          = "${local.name_prefix}-ec2-${each.key}-cpu-high"
  alarm_description   = "EC2 ${each.key} CPU sustained above 85%."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Environment = var.environment }
}

# --------------------
# DynamoDB cache throttle (hot-key guard)
# --------------------
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttle" {
  alarm_name          = "${local.name_prefix}-dynamodb-throttle"
  alarm_description   = "DynamoDB cache table is throttling requests (hot key / capacity)."
  namespace           = "AWS/DynamoDB"
  metric_name         = "ThrottledRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.cache.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Environment = var.environment }
}

# ============================================================================
# DLM — daily EBS snapshots of both EC2 instances (tag-targeted: Backup=true)
# ============================================================================
resource "aws_iam_role" "dlm" {
  name = "${local.name_prefix}-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "dlm.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "ec2_daily" {
  description        = "${local.name_prefix} daily EBS snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    target_tags = {
      Backup = "true"
    }

    schedule {
      name = "daily-${var.ebs_snapshot_retention_days}d"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["18:00"] # 02:00 Asia/Manila (UTC+8)
      }

      retain_rule {
        count = var.ebs_snapshot_retention_days
      }

      copy_tags = true
    }
  }

  tags = {
    Environment = var.environment
  }
}
