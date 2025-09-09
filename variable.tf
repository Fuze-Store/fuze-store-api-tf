variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "ap-southeast-1" # Singapore region
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = "default"
}

variable "ami_id" {
  description = "AMI ID for EC2 instance"
  type        = string
  default     = "ami-08e7e250e7e3deb9b"
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair"
  type        = string
}

variable "db_name" {
  description = "RDS database name"
  type        = string
  default     = "laravel_db"
}

variable "db_user" {
  description = "RDS master username"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "db_backup_retention_period" {
  description = "RDS backup retention period (in days)"
  type        = number
  default     = 0
}

variable "db_backup_window" {
  description = "RDS backup window (in UTC)"
  type        = string
  default     = "05:00-05:30"
}

variable "db_multi_az" {
  description = "Whether to enable Multi-AZ for RDS"
  type        = bool
  default     = false
}

variable "rds_allowed_origins" {
  description = "List of allowed origins for RDS CORS configuration"
  type        = list(string)
  default     = ["http://localhost:8081", "https://fuze-store.com", "https://store.fuze-store.com"]
}

variable "my_ip" {
  description = "Your IP address to allow SSH access"
  type        = string
  default     = "0.0.0.0/0" # Replace this with your real IP later
}
