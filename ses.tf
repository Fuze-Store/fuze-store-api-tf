# --------------------
# SES — transactional email (replaces Zoho SMTP)
#
# The Laravel `ses` mailer sends via the AWS SDK using the EC2 instance role
# (no SMTP credentials anywhere). Each environment/account verifies the domain
# separately: apply, then create the 3 DKIM CNAME records from the
# `ses_dkim_records` output at the DNS host (GoDaddy — not Route53, so
# terraform cannot manage the records).
#
# NOTE: new SES accounts start in SANDBOX (verified recipients only,
# 200 msg/day). Request production access in the SES console before real
# users must receive email.
# --------------------

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.ses_domain

  tags = {
    Environment = var.environment
  }
}

output "ses_dkim_records" {
  description = "CNAME records to create at the DNS host (GoDaddy) for SES DKIM verification"
  value = [
    for token in aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens :
    {
      type  = "CNAME"
      name  = "${token}._domainkey.${var.ses_domain}"
      value = "${token}.dkim.amazonses.com"
    }
  ]
}

output "ses_identity_arn" {
  description = "ARN of the SES domain identity"
  value       = aws_sesv2_email_identity.domain.arn
}
