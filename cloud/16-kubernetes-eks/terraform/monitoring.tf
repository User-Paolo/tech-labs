# Container Insights, node and pod metrics in CloudWatch without container logs
resource "aws_iam_role" "cloudwatch_agent" {
  name               = "lab16-cloudwatch-agent"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_addon" "observability" {
  cluster_name         = aws_eks_cluster.main.name
  addon_name           = "amazon-cloudwatch-observability"
  configuration_values = jsonencode({ containerLogs = { enabled = false } })

  pod_identity_association {
    service_account = "cloudwatch-agent"
    role_arn        = aws_iam_role.cloudwatch_agent.arn
  }

  depends_on = [aws_eks_addon.pod_identity, aws_eks_node_group.base]
}

# Grafana in the cluster only reads CloudWatch
resource "aws_iam_role" "grafana" {
  name               = "lab16-grafana"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "grafana" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_eks_pod_identity_association" "grafana" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "monitoring"
  service_account = "grafana"
  role_arn        = aws_iam_role.grafana.arn
}
