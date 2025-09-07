bucket         = "fuze-store-terraform-states"
key            = "prod/terraform.tfstate"
region         = "ap-southeast-1"
dynamodb_table = "terraform-locks"
encrypt        = true
