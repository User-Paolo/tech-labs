# The policy file comes from the controller's own repo, at the version I install
resource "aws_iam_policy" "lb_controller" {
  #checkov:skip=CKV_AWS_355:The official policy for the controller, pinned to v3.6.2
  #checkov:skip=CKV_AWS_290:The official policy for the controller, pinned to v3.6.2
  #checkov:skip=CKV_AWS_289:The official policy for the controller, pinned to v3.6.2
  #checkov:skip=CKV_AWS_286:The official policy for the controller, pinned to v3.6.2
  #checkov:skip=CKV_AWS_287:The official policy for the controller, pinned to v3.6.2
  #checkov:skip=CKV_AWS_288:The official policy for the controller, pinned to v3.6.2
  #checkov:skip=CKV2_AWS_40:The official policy for the controller, pinned to v3.6.2
  name   = "lab16-lb-controller"
  policy = file("${path.module}/iam/lb-controller-policy.json")
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "lab16-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# Only the controller's service account gets this role
resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}
