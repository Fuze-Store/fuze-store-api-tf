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
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "socket_ami_id" {
  description = "AMI ID for WebSocket EC2 instance"
  type        = string
  default     = "ami-05348ce3050db385a"
}

variable "socket_instance_type" {
  description = "EC2 instance type for WebSocket"
  type        = string
  default     = "t4g.micro"
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage (in GB)"
  type        = number
  default     = 20
}
variable "db_storage_type" {
  description = "RDS storage type"
  type        = string
  default     = "gp2"
}

variable "db_name" {
  description = "RDS database name"
  type        = string
  default     = "fuze"
}

variable "db_user" {
  description = "RDS master username"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "db_backup_retention_period" {
  description = "RDS backup retention period (in days)"
  type        = number
  default     = 7
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

variable "db_skip_final_snapshot" {
  description = "Whether to skip the final snapshot when the RDS instance is deleted. Set to false for production safety."
  type        = bool
  default     = false
}

variable "s3_force_destroy" {
  description = "Whether to allow Terraform to destroy the S3 bucket even if it contains objects. Set to true only for dev/test."
  type        = bool
  default     = false
}

variable "ssh_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to SSH into EC2 instances. Restrict to your IP/VPN for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "s3_cors_allowed_origins" {
  description = "List of allowed origins for S3 CORS configuration"
  type        = list(string)
  default     = ["http://localhost:8081", "https://fuze-store.com", "https://store.fuze-store.com"]
}
