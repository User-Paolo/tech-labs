data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_109:This is the default key policy, the account root has to keep control of the key
  #checkov:skip=CKV_AWS_111:This is the default key policy, the account root has to keep control of the key
  #checkov:skip=CKV_AWS_356:In a key policy the resource is always the key itself
  statement {
    sid       = "AccountCanManageTheKey"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "lab16 cluster secrets and image registry"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/lab16"
  target_key_id = aws_kms_key.main.key_id
}

data "aws_iam_policy_document" "cluster_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "lab16-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_cloudwatch_log_group" "cluster" {
  #checkov:skip=CKV_AWS_158:Logs from a one week lab don't need my own KMS key
  #checkov:skip=CKV_AWS_338:Logs from a one week lab don't need a year of retention
  name              = "/aws/eks/lab16/cluster"
  retention_in_days = 7
}

resource "aws_eks_cluster" "main" {
  #checkov:skip=CKV_AWS_39:I reach the API from CloudShell, and only its address is allowed
  #checkov:skip=CKV_AWS_38:The addresses come from admin_cidrs, which refuses 0.0.0.0/0
  #checkov:skip=CKV_AWS_339:1.37 is in standard support on EKS, checkov's list of versions is older than that
  name                      = "lab16"
  version                   = var.cluster_version
  role_arn                  = aws_iam_role.cluster.arn
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Never slide into extended support, which costs 6 times more
  upgrade_policy {
    support_type = "STANDARD"
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.main.arn
    }
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_cidrs
  }

  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
}

# The network plugin, with network policies switched on
resource "aws_eks_addon" "vpc_cni" {
  cluster_name         = aws_eks_cluster.main.name
  addon_name           = "vpc-cni"
  configuration_values = jsonencode({ enableNetworkPolicy = "true" })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
}

# Needs nodes to run on
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.base]
}
