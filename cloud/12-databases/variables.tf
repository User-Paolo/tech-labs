variable "multi_az" {
  description = "Keeps a standby copy of the database in a second AZ"
  type        = bool
  default     = false
}

variable "read_replica" {
  description = "Adds a read replica next to the main database"
  type        = bool
  default     = false
}
