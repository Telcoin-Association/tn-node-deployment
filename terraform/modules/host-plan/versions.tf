# Renders what the hosts read at first boot and what the operator runs next.
# It declares no provider and creates nothing, so every root calls it the same
# way and its tests plan with no credentials at all. Validations that compare
# two variables need 1.9.
terraform {
  required_version = ">= 1.9, < 2.0"
}
