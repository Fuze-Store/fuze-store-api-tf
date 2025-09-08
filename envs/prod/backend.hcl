bucket         = "fuze-store-terraform-states-prod"
key            = "prod/terraform.tfstate"
region         = "ap-southeast-1"
dynamodb_table = "terraform-locks-prod"
encrypt        = true
