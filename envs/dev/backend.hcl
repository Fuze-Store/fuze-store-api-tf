bucket         = "fuze-store-terraform-states-dev"
key            = "dev/terraform.tfstate"
region         = "ap-southeast-1"
dynamodb_table = "terraform-locks-dev"
encrypt        = true
profile        = "fuze-store-dev"
