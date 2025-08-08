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

variable "my_ip" {
  description = "Your IP address to allow SSH access"
  type        = string
  default     = "0.0.0.0/0" # Replace this with your real IP later
}
