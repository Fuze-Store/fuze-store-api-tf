terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  name_prefix = "fuze-store-${var.environment}"
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.2"

  name = "${local.name_prefix}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = false
  single_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

# EC2 Instance (Laravel App Server)
resource "aws_instance" "laravel" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = module.vpc.public_subnets[0]
  key_name      = var.key_pair_name

  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  # Optional: use this to trigger reboot if user data changes
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required" # Require IMDSv2
    http_endpoint = "enabled"  # Enable IMDS (usually enabled)
  }

  tags = {
    Name        = "${local.name_prefix}-ec2"
    Environment = var.environment
    Backup      = "true" # targeted by the DLM daily-snapshot policy (see monitoring.tf)
  }
}

# EC2 Instance (WebSocket Server)
resource "aws_instance" "websocket" {
  ami           = var.socket_ami_id
  instance_type = var.socket_instance_type
  subnet_id     = module.vpc.public_subnets[1]
  key_name      = var.key_pair_name

  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  # Optional: use this to trigger reboot if user data changes
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required" # Require IMDSv2
    http_endpoint = "enabled"  # Enable IMDS (usually enabled)
  }

  tags = {
    Name        = "${local.name_prefix}-websocket-ec2"
    Environment = var.environment
    Backup      = "true" # targeted by the DLM daily-snapshot policy (see monitoring.tf)
  }
}

# --------------------
# Security Groups
# --------------------

# EC2 Security Group
resource "aws_security_group" "ec2_sg" {
  name        = "${local.name_prefix}-ec2-sg"
  description = "Allow SSH and outbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr_blocks
  }

  # Allow HTTP (optional)
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS (optional)
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name_prefix}-ec2-sg"
    Environment = var.environment
  }
}

# RDS Security Group
resource "aws_security_group" "rds_sg" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Allow PostgreSQL access from EC2 SG only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from EC2 SG"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name_prefix}-rds-sg"
    Environment = var.environment
  }
}

resource "aws_eip" "ec2_eip" {
  instance = aws_instance.laravel.id

  tags = {
    Name        = "${local.name_prefix}-ec2-eip"
    Environment = var.environment
  }
}

resource "aws_eip" "ec2_websocket_eip" {
  instance = aws_instance.websocket.id

  tags = {
    Name        = "${local.name_prefix}-websocket-eip"
    Environment = var.environment
  }
}

# RDS Postgres
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.13.1"

  identifier           = "${local.name_prefix}-db"
  engine               = "postgres"
  engine_version       = "18.1"
  major_engine_version = "18"
  family               = "postgres18"
  instance_class       = var.db_instance_class

  allocated_storage                = var.db_allocated_storage
  storage_type                     = var.db_storage_type
  storage_encrypted                = var.db_storage_encrypted
  db_name                          = var.db_name
  username                         = var.db_user
  password                         = var.db_password
  manage_master_user_password      = false
  port                             = 5432
  multi_az                         = var.db_multi_az
  publicly_accessible              = false
  skip_final_snapshot              = var.db_skip_final_snapshot
  final_snapshot_identifier_prefix = var.db_skip_final_snapshot ? null : "${local.name_prefix}-db-final"
  deletion_protection              = true # Prevent accidental deletion in production

  # Performance Insights — query visibility (7-day retention is free tier)
  performance_insights_enabled          = var.db_performance_insights_enabled
  performance_insights_retention_period = var.db_performance_insights_enabled ? 7 : null

  create_db_subnet_group = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  subnet_ids             = module.vpc.private_subnets

  backup_retention_period = var.db_backup_retention_period
  backup_window           = var.db_backup_window

  # Custom parameter group for production safety + observability.
  # - rds.force_ssl = 0: the Soketi pg client can't do TLS (RDS is private-subnet + SG-locked, so acceptable).
  # - statement_timeout / idle_in_transaction_session_timeout: cap runaway queries + stuck transactions
  #   so a slow report can't starve the register hot path.
  # - log_min_duration_statement: slow-query log for the observability floor.
  # - timezone = UTC: durable session timezone (the app pins UTC per-connection; this makes it stick).
  parameters = [
    {
      name  = "rds.force_ssl"
      value = "0"
    },
    {
      name  = "statement_timeout"
      value = tostring(var.db_statement_timeout_ms)
    },
    {
      name  = "idle_in_transaction_session_timeout"
      value = tostring(var.db_idle_in_transaction_timeout_ms)
    },
    {
      name  = "log_min_duration_statement"
      value = tostring(var.db_log_min_duration_ms)
    },
    {
      name  = "timezone"
      value = "UTC"
    }
  ]

  tags = {
    Environment = var.environment
  }
}

# S3 Bucket
resource "aws_s3_bucket" "uploads" {
  bucket        = "${local.name_prefix}-uploads"
  force_destroy = var.s3_force_destroy

  tags = {
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_cors_configuration" "uploads_cors" {
  bucket = aws_s3_bucket.uploads.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT", "POST"]
    allowed_origins = var.s3_cors_allowed_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# --------------------
# Private receipts bucket (BIR top-up / official receipts)
# The app writes receipts here and serves them via short-lived presigned URLs
# (config('fuze.business.receipt_storage_disk'), RenderTopUpReceiptPdfJob).
# NEVER public — unlike the uploads bucket.
# --------------------
resource "aws_s3_bucket" "receipts" {
  bucket        = "${local.name_prefix}-receipts"
  force_destroy = false # never force-destroy compliance records

  tags = {
    Environment = var.environment
    Purpose     = "receipts"
  }
}

resource "aws_s3_bucket_public_access_block" "receipts" {
  bucket                  = aws_s3_bucket.receipts.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "receipts" {
  bucket = aws_s3_bucket.receipts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Laravel queue names (one SQS queue per name; matches onQueue(...) usage in apps/api)
locals {
  laravel_queues = toset(["default", "mail", "receipts", "broadcasts"])

  # Slow-job queues get a longer SQS visibility timeout so a long render/broadcast
  # isn't redelivered mid-flight and double-processed.
  slow_queues = toset(["receipts", "broadcasts"])
}

# SQS Dead Letter Queue (shared across all Laravel queues)
resource "aws_sqs_queue" "laravel_queue_dlq" {
  name                      = "${local.name_prefix}-queue-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Environment = var.environment
  }
}

# SQS work queues — one per Laravel queue name.
# Naming convention: fuze-store-{env}-queue-{name} (matches the DLQ prefix).
# Laravel code stays short via `config('queue.names.<key>')` (see apps/api/config/queue.php),
# resolved at runtime by prepending SQS_QUEUE_PREFIX (e.g. "fuze-store-dev-queue-").
resource "aws_sqs_queue" "laravel_queue" {
  for_each = local.laravel_queues

  name = "${local.name_prefix}-queue-${each.key}"

  visibility_timeout_seconds = contains(local.slow_queues, each.key) ? var.sqs_slow_visibility_timeout : var.sqs_default_visibility_timeout

  tags = {
    Environment = var.environment
    QueueName   = each.key
  }
}

# SQS Redrive Allow Policy — DLQ accepts redrives from every laravel_queue.
# Must be applied before any redrive_policy on the work queues, otherwise
# CreateQueue / SetQueueAttributes is rejected with "RedriveAllowPolicy ... prevents you from completing this request".
resource "aws_sqs_queue_redrive_allow_policy" "dlq_allow" {
  queue_url = aws_sqs_queue.laravel_queue_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [for q in aws_sqs_queue.laravel_queue : q.arn]
  })
}

# SQS Redrive Policy — attached after dlq_allow so the DLQ already permits these source queues
resource "aws_sqs_queue_redrive_policy" "laravel_queue_redrive" {
  for_each = local.laravel_queues

  queue_url = aws_sqs_queue.laravel_queue[each.key].id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.laravel_queue_dlq.arn
    maxReceiveCount     = 5
  })

  depends_on = [aws_sqs_queue_redrive_allow_policy.dlq_allow]
}

# DynamoDB Table
resource "aws_dynamodb_table" "cache" {
  name         = "${local.name_prefix}-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Environment = var.environment
  }
}

# IAM Role and Policy Attachment (simplified)
resource "aws_iam_role" "ec2_role" {
  name = "${local.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Least-privilege policy for EC2 instances
resource "aws_iam_role_policy" "ec2_policy" {
  name = "${local.name_prefix}-ec2-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.uploads.arn,
          "${aws_s3_bucket.uploads.arn}/*",
          aws_s3_bucket.receipts.arn,
          "${aws_s3_bucket.receipts.arn}/*"
        ]
      },
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = concat(
          [for q in aws_sqs_queue.laravel_queue : q.arn],
          [aws_sqs_queue.laravel_queue_dlq.arn]
        )
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem"
        ]
        Resource = [
          aws_dynamodb_table.cache.arn,
          "${aws_dynamodb_table.cache.arn}/index/*"
        ]
      },
      {
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = ["arn:aws:logs:${var.aws_region}:*:*"]
      },
      {
        # Read-only access to this environment's app secrets (see ssm.tf).
        # SecureStrings use the AWS-managed aws/ssm KMS key, so no extra
        # kms:Decrypt grant is needed.
        Sid    = "SSMParameterRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/fuze-store/${var.environment}/*"
        ]
      }
    ]
  })
}

# Instance Profile to link IAM Role to EC2
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.ec2_role.name
}

# S3 bucket policy for public read access

# Allow public bucket policies for uploads bucket
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "uploads_public_read" {
  bucket = aws_s3_bucket.uploads.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadGetObject",
        Effect    = "Allow",
        Principal = "*",
        Action    = "s3:GetObject",
        Resource  = "${aws_s3_bucket.uploads.arn}/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.uploads]
}

# Output basic resources
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "ec2_public_ip" {
  value = aws_instance.laravel.public_ip
}

output "ec2_websocket_public_ip" {
  value = aws_instance.websocket.public_ip
}

output "rds_endpoint" {
  value = module.rds.db_instance_endpoint
}

output "ec2_eip" {
  description = "Elastic IP address for the Laravel EC2 instance"
  value       = aws_eip.ec2_eip.public_ip
}

output "ec2_websocket_eip" {
  description = "Elastic IP address for the WebSocket EC2 instance"
  value       = aws_eip.ec2_websocket_eip.public_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 uploads bucket"
  value       = aws_s3_bucket.uploads.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 uploads bucket"
  value       = aws_s3_bucket.uploads.arn
}

output "receipts_bucket_name" {
  description = "Name of the private S3 receipts bucket (BIR receipts, presigned-URL access)"
  value       = aws_s3_bucket.receipts.id
}

output "receipts_bucket_arn" {
  description = "ARN of the private S3 receipts bucket"
  value       = aws_s3_bucket.receipts.arn
}

output "sqs_queue_urls" {
  description = "Map of Laravel queue name -> SQS queue URL"
  value       = { for k, q in aws_sqs_queue.laravel_queue : k => q.url }
}

output "sqs_queue_arns" {
  description = "Map of Laravel queue name -> SQS queue ARN"
  value       = { for k, q in aws_sqs_queue.laravel_queue : k => q.arn }
}

output "sqs_dlq_url" {
  description = "URL of the SQS dead letter queue"
  value       = aws_sqs_queue.laravel_queue_dlq.url
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB cache table"
  value       = aws_dynamodb_table.cache.name
}

# Data source for AZs
data "aws_availability_zones" "available" {}
