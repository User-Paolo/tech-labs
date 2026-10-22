resource "aws_lb" "web" {
  #checkov:skip=CKV_AWS_91:Access logs need their own bucket, they fit better in a monitoring lab
  #checkov:skip=CKV_AWS_150:Deletion protection would block terraform destroy at the end of the lab
  #checkov:skip=CKV2_AWS_28:WAF costs money even with no traffic, same call as lab 03
  #checkov:skip=CKV2_AWS_20:No domain, so no certificate and nothing to redirect to
  name                       = "lab07-alb"
  load_balancer_type         = "application"
  subnets                    = local.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true

  tags = {
    Name = "lab07-alb"
  }
}

resource "aws_lb_target_group" "web" {
  #checkov:skip=CKV_AWS_378:Plain HTTP inside the VPC, from the load balancer to private instances
  name                 = "lab07-web"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:No domain, so no certificate for HTTPS
  #checkov:skip=CKV_AWS_103:Same, TLS needs HTTPS first
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
