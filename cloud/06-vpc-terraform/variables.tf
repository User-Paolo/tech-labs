variable "my_ip" {
  description = "My home IP, the only address allowed to reach the web server"
  type        = string

  validation {
    condition     = can(cidrhost("${var.my_ip}/32", 0))
    error_message = "my_ip has to be a plain IPv4 address like 203.0.113.10."
  }
}

variable "enable_nat" {
  description = "NAT gateway for the private subnets, about $0.05 an hour with its Elastic IP"
  type        = bool
  default     = true
}

variable "block_my_ip" {
  description = "Adds a NACL deny for my IP on port 80 in front of the public subnets"
  type        = bool
  default     = false
}
