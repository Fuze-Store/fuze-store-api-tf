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
  alias   = "dev"
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
  }
}

# EC2 Instance (WebSocket Server)
resource "aws_instance" "websocket" {
  ami           = var.socket_ami_id
  instance_type = var.socket_instance_type
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
    Name        = "${local.name_prefix}-websocket-ec2"
    Environment = var.environment
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
    cidr_blocks = ["0.0.0.0/0"]
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
  description = "Allow MySQL access from EC2 SG only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from EC2 SG"
    from_port       = 3306
    to_port         = 3306
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

  allocated_storage           = var.db_allocated_storage
  storage_type                = var.db_storage_type
  db_name                     = var.db_name
  username                    = var.db_user
  password                    = var.db_password
  manage_master_user_password = false
  port                        = 5432
  multi_az                    = var.db_multi_az
  publicly_accessible         = false
  skip_final_snapshot         = true
  deletion_protection         = true # Prevent accidental deletion in production

  create_db_subnet_group = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  subnet_ids             = module.vpc.private_subnets

  backup_retention_period = var.db_backup_retention_period
  backup_window           = var.db_backup_window
  tags = {
    Environment = var.environment
  }
}

# S3 Bucket
resource "aws_s3_bucket" "uploads" {
  bucket        = "${local.name_prefix}-uploads"
  force_destroy = true

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
    allowed_origins = var.rds_allowed_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# SQS
resource "aws_sqs_queue" "laravel_queue" {
  name = "${local.name_prefix}-queue"

  tags = {
    Environment = var.environment
  }
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

# Attach EC2 permissions
resource "aws_iam_role_policy_attachment" "ec2_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

# Attach S3 permissions
resource "aws_iam_role_policy_attachment" "ec2_s3" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# Attach SQS permissions
resource "aws_iam_role_policy_attachment" "ec2_sqs" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

# Attach RDS permissions
resource "aws_iam_role_policy_attachment" "ec2_rds" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}

# Attach DynamoDB permissions
resource "aws_iam_role_policy_attachment" "ec2_dynamodb" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

# Attach CloudWatch Logs permissions
resource "aws_iam_role_policy_attachment" "ec2_cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
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

output "rds_endpoint" {
  value = module.rds.db_instance_endpoint
}

# Data source for AZs
data "aws_availability_zones" "available" {}
