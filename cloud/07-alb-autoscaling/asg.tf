data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "web" {
  name                   = "lab07-web"
  image_id               = data.aws_ssm_parameter.al2023.insecure_value
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.web.id]
  user_data              = base64encode(templatefile("${path.module}/web.sh.tftpl", { version = var.page_version }))
  ebs_optimized          = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ssm.name
  }

  metadata_options {
    http_tokens = "required"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "lab07-web"
      Lab  = "07"
    }
  }
}

resource "aws_autoscaling_group" "web" {
  name                      = "lab07-web"
  min_size                  = 2
  max_size                  = 4
  desired_capacity          = 2
  vpc_zone_identifier       = local.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  # New instances come up first and old ones go once the new ones are healthy
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
      instance_warmup        = 30
    }
  }

  tag {
    key                 = "Lab"
    value               = "07"
    propagate_at_launch = true
  }

  # The SSM agent backs off if it boots before the NAT route exists
  depends_on = [aws_route.private_nat]
}
