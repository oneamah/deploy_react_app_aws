variable "nest-app-repo" {
  description = "The repository URL for the NestJS application."
  type        = string
  sensitive   = true
  default     = null
}
variable "react-app-repo" {
  description = "The repository URL for the React application."
  type        = string
  sensitive   = true
  default     = null
}

variable "primary_region" {
  description = "Primary region for application deployment"
  type        = string
  default     = null
}
variable "secondary_region" {
  description = "Secondary region for application deployment"
  type        = string
  default     = null
}
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = null
}
variable "tag_name" {
  description = "Tag name for resources"
  type        = string
  default     = "MERN-App"
}
variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "development"
}
variable "app_port" {
  description = "Application port"
  type        = number
  default     = 80
}
variable "cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
  default     = null
}
variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = []
}
variable "github_ssh_key_ssm_name" {
  description = "SSM parameter name for GitHub SSH key"
  type        = string
  default     = null

}

variable "s3_bucket" {
  default     = "mern-app-react-build-development"
  description = "S3 bucket name for React build"
  type        = string
}

variable "route53_zone_id" {
  description = "The Route53 Hosted Zone ID for the domain."
  type        = string
}
variable "domain_name" {
  description = "The domain name for Route53."
  type        = string
}