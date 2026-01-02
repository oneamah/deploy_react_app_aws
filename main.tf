##################################
# Data Sources
##################################

# Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Shuffle AZs
resource "random_shuffle" "azs" {
  input        = data.aws_availability_zones.available.names
  result_count = length(var.public_subnet_cidrs)
}

# GitHub SSH key from SSM
data "aws_ssm_parameter" "github_ssh_key" {
  name            = var.github_ssh_key_ssm_name
  with_decryption = true
}

##################################
# Networking
##################################

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.tag_name}-vpc-${var.environment}" }
}

# Public subnets
resource "aws_subnet" "public" {
  count                  = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = element(random_shuffle.azs.result, count.index)
  map_public_ip_on_launch = true
  tags = { Name = "${var.tag_name}-public-${count.index+1}-${var.environment}" }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.tag_name}-igw-${var.environment}" }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.tag_name}-public-rt-${var.environment}" }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

##################################
# Security Groups
##################################

# ALB SG
resource "aws_security_group" "alb_sg" {
  vpc_id      = aws_vpc.main.id
  name        = "${var.tag_name}-alb-sg-${var.environment}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 SG
resource "aws_security_group" "app_sg" {
  vpc_id = aws_vpc.main.id
  name   = "${var.tag_name}-app-sg-${var.environment}"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

##################################
# ALB
##################################
resource "aws_lb" "application" {
  name               = "${var.tag_name}-alb-${var.environment}"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "app" {
  name     = "${var.tag_name}-tg-${var.environment}"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path    = "/"
    matcher = "200-399"
  }
}



##################################
# S3 Bucket (React Build)
##################################
resource "aws_s3_bucket" "react_build" {
  bucket = var.s3_bucket
}

##################################
# IAM Role for EC2 to read S3
##################################
resource "aws_iam_role" "ec2_s3_role" {
  name = "${var.tag_name}-ec2-s3-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ec2_s3_policy" {
  name = "${var.tag_name}-ec2-s3-policy-${var.environment}"
  role = aws_iam_role.ec2_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:GetObject", "s3:ListBucket"],
        Resource = [
          aws_s3_bucket.react_build.arn,
          "${aws_s3_bucket.react_build.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_s3_profile" {
  name = "${var.tag_name}-ec2-s3-profile-${var.environment}"
  role = aws_iam_role.ec2_s3_role.name
}

##################################
# Launch Template + ASG
##################################
resource "aws_launch_template" "app" {
  name_prefix   = "${var.tag_name}-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_s3_profile.name
  }

  user_data = base64encode(templatefile("react-app-cloud-init.yml", {
    github_ssh_key = data.aws_ssm_parameter.github_ssh_key.value,
    s3_bucket      = var.s3_bucket
  }))
  
}

resource "aws_autoscaling_group" "app_asg" {
  min_size         = 1
  max_size         = 2
  desired_capacity = 1

  vpc_zone_identifier = aws_subnet.public[*].id
  target_group_arns   = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  health_check_type = "ELB"
  health_check_grace_period = 300

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 180
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.tag_name}-instance-${var.environment}"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  lb_target_group_arn    = aws_lb_target_group.app.arn
}

resource "aws_acm_certificate" "cert" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
  tags = {
    Name = "${var.tag_name}-cert-${var.environment}"
  }
}
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name    = dvo.resource_record_name
      type    = dvo.resource_record_type
      record  = dvo.resource_record_value
      zone_id = var.route53_zone_id
    }
  }

  name    = each.value.name
  type    = each.value.type
  zone_id = each.value.zone_id
  records = [each.value.record]
  ttl     = 60
}

#### link domain to alb with https##### 

resource "aws_route53_record" "app" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_lb.application.dns_name
    zone_id                = aws_lb.application.zone_id
    evaluate_target_health = true
  }
}
resource "aws_route53_record" "www" {
  zone_id = var.route53_zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_lb.application.dns_name
    zone_id                = aws_lb.application.zone_id
    evaluate_target_health = true
  }
}
# HTTP Listener (redirect to HTTPS)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol = "HTTPS"
      port     = "443"
      status_code = "HTTP_301"
    }
  }
}


## Only keep one HTTPS listener (forward to target group)
# HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.application.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  depends_on = [aws_route53_record.cert_validation]
}

resource "aws_wafv2_web_acl" "alb_acl" {
  name        = "${var.tag_name}-waf"
  description = "Allow only custom domain"
  scope       = "REGIONAL"
  default_action {
    block {}
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "alb_acl"
    sampled_requests_enabled   = true
  }
  rule {
    name     = "AllowCustomDomain"
    priority = 1
    action {
      allow {}
    }
    statement {
      byte_match_statement {
        search_string = var.domain_name
        field_to_match {
          single_header {
            name = "host"
          }
        }
        positional_constraint = "EXACTLY"
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      sampled_requests_enabled    = true
      cloudwatch_metrics_enabled  = true
      metric_name                 = "AllowCustomDomain"
    }
  }
}
resource "aws_wafv2_web_acl_association" "waf_alb" {
  resource_arn = aws_lb.application.arn
  web_acl_arn  = aws_wafv2_web_acl.alb_acl.arn
}