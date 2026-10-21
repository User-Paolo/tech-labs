output "web_url" {
  value = "http://${aws_instance.this["web"].public_ip}"
}

output "app_private_ip" {
  value = aws_instance.this["app"].private_ip
}

output "instance_ids" {
  value = { for k, i in aws_instance.this : k => i.id }
}

output "nat_public_ip" {
  value = var.enable_nat ? aws_eip.nat[0].public_ip : null
}
