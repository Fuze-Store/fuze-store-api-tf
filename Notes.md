# Setting Up Remote State with S3 and DynamoDB for Terraform

## Create S3 bucket (region must match your backend.hcl)

`aws s3api create-bucket --bucket fuze-store-terraform-states-{environment} --region ap-southeast-1 --create-bucket-configuration LocationConstraint=ap-southeast-1`

## S3 Tagging

`aws s3api put-bucket-tagging --bucket fuze-store-terraform-states-{environment} --tagging 'TagSet=[{Key=Environment,Value={environment}}]'`

## Block public access (important for state security)

`aws s3api put-public-access-block --bucket fuze-store-terraform-states-{environment} --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true`

## Enable versioning (so you can roll back states if needed)

`aws s3api put-bucket-versioning --bucket fuze-store-terraform-states-{environment} --versioning-configuration Status=Enabled`

## Create DynamoDB table for locking

`aws dynamodb create-table --table-name terraform-locks-{environment} --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST --tags Key=Environment,Value={environment}`


## Switch environment

terraform init -reconfigure -backend-config=envs/{environment}/backend.hcl
terraform plan -var-file=envs/{environment}/terraform.tfvars
terraform apply -var-file=envs/{environment}/terraform.tfvars
terraform destroy -var-file=envs/{environment}/terraform.tfvars
