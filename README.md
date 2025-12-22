# Fuze Store API Terraform Infrastructure

This repository contains Terraform configurations to provision and manage common AWS services for the Fuze Store SaaS POS application. It automates the setup of networking, compute, database, storage, and messaging resources required for the backend infrastructure.

## What Does This Repository Do?

- **Creates a secure VPC** with public and private subnets
- **Deploys EC2 instances** for the Laravel app and WebSocket server
- **Provisions an RDS PostgreSQL database**
- **Creates an S3 bucket** for file uploads (with CORS and public read policy)
- **Sets up an SQS queue** for background jobs
- **Creates a DynamoDB table** for caching
- **Configures IAM roles and policies** for EC2 access to AWS services
- **Manages security groups** for EC2 and RDS

## Folder Structure

```
.
├── backend.tf                # Backend configuration (S3 remote state)
├── main.tf                   # Main Terraform resources and modules
├── variable.tf               # Input variables
├── envs/                     # Environment-specific configs (dev, prod)
│   ├── dev/
│   │   ├── backend.hcl
│   │   ├── terraform.tfvars
│   │   └── state/
│   └── prod/
│       ├── backend.hcl
│       ├── terraform.tfvars
│       └── state/
└── ...
```

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.3.0
- AWS CLI configured with appropriate profiles and permissions
- An existing EC2 key pair in your AWS account

## Usage

1. **Clone the repository:**

   ```sh
   git clone <this-repo-url>
   cd fuze-store-api-tf
   ```

2. **Select your environment:**
   - Edit or create `envs/dev/terraform.tfvars` or `envs/prod/terraform.tfvars` with environment-specific values (e.g., `key_pair_name`, `db_password`).

3. **Initialize Terraform:**

   ```sh
   terraform init -backend-config=envs/dev/backend.hcl
   # or for prod
   # terraform init -backend-config=envs/prod/backend.hcl
   ```

4. **Plan the deployment:**

   ```sh
   terraform plan -var-file=envs/dev/terraform.tfvars
   # or for prod
   # terraform plan -var-file=envs/prod/terraform.tfvars
   ```

5. **Apply the configuration:**

   ```sh
   terraform apply -var-file=envs/dev/terraform.tfvars
   # or for prod
   # terraform apply -var-file=envs/prod/terraform.tfvars
   ```

6. **Destroy resources (when needed):**

   ```sh
   terraform destroy -var-file=envs/dev/terraform.tfvars
   # or for prod
   # terraform destroy -var-file=envs/prod/terraform.tfvars
   ```

## Variables

See `variable.tf` for all configurable variables. Sensitive values (like `db_password`) should be set in your `terraform.tfvars` files and not committed to version control.

## Outputs

After a successful apply, Terraform will output:

- VPC ID
- EC2 public IPs
- RDS endpoint

## Notes

- The S3 bucket for uploads is configured for public read access. Adjust the policy if you require stricter access.
- RDS deletion protection is enabled by default for safety in production.
- The default region is `ap-southeast-1` (Singapore). Change `aws_region` as needed.
- Ensure your AWS profile has sufficient permissions to create and manage all resources.

## License

This project is intended for internal use. Please review and update the license as appropriate for your organization.
