# ============================================================================
# EC2 host hygiene + CloudWatch agent — enforced through SSM State Manager
#
# Why State Manager and not user_data: user_data was set on the live boxes
# outside this repo and sits under lifecycle.ignore_changes (see main.tf), so
# Terraform cannot carry OS-level config through it. Associations target the
# Environment tag, so a rebuilt or added instance picks them up on its own,
# and they re-run daily, so a drifted box self-heals.
#
# Background (2026-09-08): the prod websocket root disk hit 100%. Nothing was
# runaway — a build toolchain, a 2 GB swapfile, snap revision hoarding and
# unattended-upgrade downloads with no autoclean crept up over 7 weeks, with
# no disk metric to warn. nginx then answered 500 to every broadcast body over
# its 8 KB buffer and the SSM agent stopped executing. Three fixes here:
#   1. apt autoclean + snap refresh.retain=2 (stop the creep)
#   2. CloudWatch agent publishing disk_used_percent + mem_used_percent
#   3. alarms on those metrics in monitoring.tf
# ============================================================================

locals {
  # Both instances carry Environment = var.environment (main.tf). SSM only
  # matches instances registered with the agent, so RDS etc. are not targets.
  ssm_ec2_targets = [{
    key    = "tag:Environment"
    values = [var.environment]
  }]

  cloudwatch_agent_config = {
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = {
      namespace = "CWAgent"
      # The agent publishes every metric with the full dimension set (path,
      # device, fstype) AND a rolled-up copy keyed on InstanceId alone. The
      # alarms in monitoring.tf read the rolled-up copy, so a device rename
      # (nvme0n1p1 vs xvda1) can never silently detach an alarm.
      append_dimensions      = { InstanceId = "$${aws:InstanceId}" }
      aggregation_dimensions = [["InstanceId"]]
      metrics_collected = {
        disk = {
          measurement                 = ["used_percent"]
          resources                   = ["/"]
          metrics_collection_interval = 60
          # snap mounts are read-only squashfs images that always report 100%.
          ignore_file_system_types = ["sysfs", "devtmpfs", "tmpfs", "squashfs", "overlay"]
        }
        mem = {
          measurement                 = ["used_percent"]
          metrics_collection_interval = 60
        }
      }
    }
  }
}

# Agent config lives under the env's parameter path so the existing
# SSMParameterRead grant on the instance role covers the fetch. It is a plain
# String managed by Terraform — unrelated to the SecureString shells in ssm.tf
# and outside the /api and /websocket subtrees render-env.sh reads.
resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  name        = "/fuze-store/${var.environment}/cloudwatch-agent/config"
  description = "CloudWatch agent config for the ${var.environment} EC2 instances (disk + memory metrics)."
  type        = "String"
  value       = jsonencode(local.cloudwatch_agent_config)

  tags = { Environment = var.environment }
}

# 1. Install (or upgrade) the CloudWatch agent package.
resource "aws_ssm_association" "cloudwatch_agent_install" {
  name             = "AWS-ConfigureAWSPackage"
  association_name = "${local.name_prefix}-cloudwatch-agent-install"

  parameters = {
    action = "Install"
    name   = "AmazonCloudWatchAgent"
  }

  dynamic "targets" {
    for_each = local.ssm_ec2_targets
    content {
      key    = targets.value.key
      values = targets.value.values
    }
  }

  schedule_expression = "rate(7 days)"
}

# 2. Load the config from Parameter Store and (re)start the agent. Daily so a
#    config edit or a dead agent is picked up without a manual step.
resource "aws_ssm_association" "cloudwatch_agent_configure" {
  name             = "AmazonCloudWatch-ManageAgent"
  association_name = "${local.name_prefix}-cloudwatch-agent-configure"

  parameters = {
    action                        = "configure"
    mode                          = "ec2"
    optionalConfigurationSource   = "ssm"
    optionalConfigurationLocation = aws_ssm_parameter.cloudwatch_agent_config.name
    optionalRestart               = "yes"
  }

  dynamic "targets" {
    for_each = local.ssm_ec2_targets
    content {
      key    = targets.value.key
      values = targets.value.values
    }
  }

  schedule_expression = "rate(1 day)"

  depends_on = [aws_ssm_association.cloudwatch_agent_install]
}

# 3. Package-cache hygiene. Idempotent; the daily run also cleans the apt
#    cache so an unattended-upgrade download never accumulates again.
resource "aws_ssm_association" "host_hygiene" {
  name             = "AWS-RunShellScript"
  association_name = "${local.name_prefix}-host-hygiene"

  parameters = {
    commands = <<-SH
      set -e
      cat > /etc/apt/apt.conf.d/20fuze-autoclean <<'APT'
      // Managed by fuze-store-api-tf (ec2-hygiene.tf). Do not edit on the box.
      APT::Periodic::AutocleanInterval "7";
      Unattended-Upgrade::Remove-Unused-Dependencies "true";
      Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
      Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
      APT
      chmod 0644 /etc/apt/apt.conf.d/20fuze-autoclean
      if command -v snap >/dev/null 2>&1; then snap set system refresh.retain=2; fi
      apt-get clean
      df -h /
    SH
  }

  dynamic "targets" {
    for_each = local.ssm_ec2_targets
    content {
      key    = targets.value.key
      values = targets.value.values
    }
  }

  schedule_expression = "rate(1 day)"
}
