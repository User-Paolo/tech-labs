variable "my_ip" {
  description = "My home IP, the only address allowed to reach the load balancer"
  type        = string

  validation {
    condition     = can(cidrhost("${var.my_ip}/32", 0))
    error_message = "my_ip has to be a plain IPv4 address like 203.0.113.10."
  }
}

variable "page_version" {
  description = "Shown on the page, changing it rolls out new instances"
  type        = string
  default     = "v1"
}

variable "alert_email" {
  description = "Where the alarm emails go"
  type        = string
  sensitive   = true
}

variable "requests_per_target" {
  description = "Requests per instance per minute that the scaling policy aims for"
  type        = number
  default     = 100
}
