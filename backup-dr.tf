# Verge Cloud - Backup and Disaster Recovery

# AWS Backup Vault
resource "aws_backup_vault" "main" {
  name = "${var.project_name}-backup-vault"
  
  tags = {
    Name = "${var.project_name}-backup-vault"
  }
}

# AWS Backup Plan
resource "aws_backup_plan" "main" {
  name = "${var.project_name}-backup-plan"

  rule {
    rule_name         = "daily-backups"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 ? * * *)"  # Daily at 5:00 UTC
    
    lifecycle {
      delete_after = 30  # Keep daily backups for 30 days
    }
  }

  rule {
    rule_name         = "weekly-backups"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 ? * SUN *)"  # Every Sunday at 5:00 UTC
    
    lifecycle {
      delete_after = 90  # Keep weekly backups for 90 days
    }
  }

  rule {
    rule_name         = "monthly-backups"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 1 * ? *)"  # First day of each month at 5:00 UTC
    
    lifecycle {
      delete_after = 365  # Keep monthly backups for 1 year
    }
  }
  
  tags = {
    Name = "${var.project_name}-backup-plan"
  }
}

# AWS Backup Selection
resource "aws_iam_role" "backup_role" {
  name = "${var.project_name}-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-backup-role"
  }
}

resource "aws_iam_role_policy_attachment" "backup_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
  role       = aws_iam_role.backup_role.name
}

resource "aws_backup_selection" "main" {
  name         = "${var.project_name}-backup-selection"
  iam_role_arn = aws_iam_role.backup_role.arn
  plan_id      = aws_backup_plan.main.id

  resources = [
    aws_rds_cluster.main.arn,
    aws_dynamodb_table.sessions.arn,
    aws_dynamodb_table.model_cache.arn,
    # EFS could be added here if used in the infrastructure
  ]
}

# S3 Cross-Region Replication for Critical Buckets
resource "aws_s3_bucket" "media_replica" {
  provider = aws.dr_region
  bucket   = "${var.project_name}-media-replica-${var.environment}"
  
  tags = {
    Name = "${var.project_name}-media-replica"
  }
}

resource "aws_s3_bucket_versioning" "media_replica" {
  provider = aws.dr_region
  bucket   = aws_s3_bucket.media_replica.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media_replica" {
  provider = aws.dr_region
  bucket   = aws_s3_bucket.media_replica.id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_role" "replication" {
  name = "${var.project_name}-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-s3-replication-role"
  }
}

resource "aws_iam_policy" "replication" {
  name = "${var.project_name}-s3-replication-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.media.arn
        ]
      },
      {
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Effect = "Allow"
        Resource = [
          "${aws_s3_bucket.media.arn}/*"
        ]
      },
      {
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Effect = "Allow"
        Resource = [
          "${aws_s3_bucket.media_replica.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "replication" {
  role       = aws_iam_role.replication.name
  policy_arn = aws_iam_policy.replication.arn
}

resource "aws_s3_bucket_replication_configuration" "media" {
  depends_on = [
    aws_s3_bucket_versioning.media,
    aws_s3_bucket_versioning.media_replica
  ]

  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.media.id

  rule {
    id     = "media-replication"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.media_replica.arn
      storage_class = "STANDARD"
    }
  }
}

# DynamoDB Global Tables
resource "aws_dynamodb_table_replica" "sessions" {
  provider         = aws.dr_region
  global_table_arn = aws_dynamodb_table.sessions.arn
}

resource "aws_dynamodb_table_replica" "model_cache" {
  provider         = aws.dr_region
  global_table_arn = aws_dynamodb_table.model_cache.arn
}

# Additional Variables
variable "dr_region" {
  description = "Disaster Recovery AWS region"
  type        = string
  default     = "us-west-2"  # Different from primary region
}

# Create AWS provider for DR region
provider "aws" {
  alias  = "dr_region"
  region = var.dr_region
}

# Create a text file with DR documentation
resource "local_file" "dr_plan" {
  filename = "${path.module}/dr-plan.md"
  content  = <<-EOT
# Verge Cloud Disaster Recovery Plan

## Overview
This document outlines the disaster recovery plan for the Verge Cloud platform.

## Critical Components
- RDS Aurora Database
- DynamoDB Tables
- S3 Media Storage
- ECS Services
- Redis Cache

## Recovery Point Objective (RPO)
- Database: 1 hour
- S3 Data: Near real-time (cross-region replication)
- DynamoDB: Near real-time (global tables)

## Recovery Time Objective (RTO)
- Critical services: 4 hours
- Full platform: 24 hours

## Disaster Recovery Scenarios
1. **Single AZ failure**
   - Automatic failover for RDS Aurora to standby in another AZ
   - ECS tasks can be rescheduled to other AZs
   - No manual intervention required

2. **Region-wide failure**
   - Trigger manual failover to DR region
   - Update DNS records to point to DR region infrastructure
   - Restore latest RDS snapshot
   - DynamoDB Global Tables provide automatic multi-region replication
   - S3 data is replicated to DR region

## Recovery Steps
1. **Assessment**
   - Identify the scope of the disaster
   - Determine if single-AZ or region-wide recovery is needed

2. **Recovery Execution**
   - For region-wide disaster, deploy infrastructure in DR region using Terraform
   - Restore RDS from latest snapshot if needed
   - Update Route53 records to point to new infrastructure
   - Verify application functionality

3. **Validation**
   - Run automated tests to verify system integrity
   - Check data consistency
   - Verify all services are operational

## Contact Information
- Primary: ops@vergecloud.com
- Secondary: alerts@vergecloud.com

## Testing Schedule
- DR tests should be performed quarterly
- Results should be documented and reviewed by the operations team
EOT
}

# Additional Outputs
output "dr_region" {
  value = var.dr_region
}

output "media_replica_bucket" {
  value = aws_s3_bucket.media_replica.bucket
}
