variable "cluster_version" {
  type    = string
  default = "1.37"
}

variable "admin_cidrs" {
  description = "Addresses allowed to reach the cluster API, normally my CloudShell session"
  type        = list(string)

  validation {
    condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "The cluster API must not be open to the whole internet."
  }
}

variable "base_nodes" {
  type    = number
  default = 2
}

variable "spot_nodes" {
  type    = number
  default = 2
}
