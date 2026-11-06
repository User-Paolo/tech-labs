locals {
  alb_dimension = { LoadBalancer = aws_lb.web.arn_suffix }
  tg_dimension  = { LoadBalancer = aws_lb.web.arn_suffix, TargetGroup = aws_lb_target_group.web.arn_suffix }
  asg_dimension = { AutoScalingGroupName = aws_autoscaling_group.web.name }

  alarms = {
    unhealthy = {
      metric     = "UnHealthyHostCount"
      statistic  = "Maximum"
      threshold  = 0
      periods    = 1
      dimensions = local.tg_dimension
      summary    = "At least one instance is failing its health check"
    }
    errors = {
      metric     = "HTTPCode_ELB_5XX_Count"
      statistic  = "Sum"
      threshold  = 5
      periods    = 1
      dimensions = local.alb_dimension
      summary    = "The load balancer returned more than 5 errors in a minute"
    }
    slow = {
      metric     = "TargetResponseTime"
      statistic  = "Average"
      threshold  = 1
      periods    = 2
      dimensions = local.alb_dimension
      summary    = "Responses took over a second on average for 2 minutes"
    }
  }
}

resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:CloudWatch alarms can't publish to a topic using the AWS managed key
  name = "lab11-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "lab11-${each.key}"
  alarm_description   = each.value.summary
  namespace           = "AWS/ApplicationELB"
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  dimensions          = each.value.dimensions
  period              = 60
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "web" {
  dashboard_name = "lab11-web"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Requests"
          region = "us-east-1"
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.web.arn_suffix],
            ["AWS/ApplicationELB", "RequestCountPerTarget", "TargetGroup", aws_lb_target_group.web.arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Instances in the group"
          region = "us-east-1"
          stat   = "Maximum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.web.name],
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.web.name],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Healthy and unhealthy instances"
          region = "us-east-1"
          stat   = "Maximum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.web.arn_suffix, "LoadBalancer", aws_lb.web.arn_suffix],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.web.arn_suffix, "LoadBalancer", aws_lb.web.arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Errors and response time"
          region = "us-east-1"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.web.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.web.arn_suffix, { stat = "Average", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}
