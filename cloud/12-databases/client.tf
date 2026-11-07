data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "client" {
  ami                    = data.aws_ssm_parameter.al2023.insecure_value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.this["private-a"].id
  vpc_security_group_ids = [aws_security_group.client.id]
  iam_instance_profile   = aws_iam_instance_profile.client.name
  ebs_optimized          = true
  monitoring             = true

  user_data = templatefile("${path.module}/client.sh.tftpl", {
    db_host    = aws_db_instance.main.address
    db_name    = aws_db_instance.main.db_name
    db_user    = aws_db_instance.main.username
    secret_arn = aws_db_instance.main.master_user_secret[0].secret_arn
    table      = aws_dynamodb_table.notes.name
  })

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = {
    Name = "lab12-client"
  }

  depends_on = [aws_route.private_nat, aws_route_table_association.this]
}
