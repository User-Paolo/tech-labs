output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "ecr_url" {
  value = aws_ecr_repository.app.repository_url
}
