output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "ecr_url" {
  value = aws_ecr_repository.app.repository_url
}

output "db_address" {
  value = aws_db_instance.main.address
}

output "db_secret_arn" {
  value = aws_db_instance.main.master_user_secret[0].secret_arn
}
