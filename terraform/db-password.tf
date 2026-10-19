# Ephemeral + write-only: the database password is omitted from plan and state.
variable "db_password_wo" {
  type      = string
  sensitive = true
  ephemeral = true
  default   = null
}
variable "db_password_version" {
  type    = number
  default = 1
}

# Delete-only plans do not supply a write-only credential or its update version.
variable "db_password_write_enabled" {
  type    = bool
  default = true
}
