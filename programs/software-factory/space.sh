# shellcheck shell=bash
# Disk space helpers shared by factory-ctl and factory-maintenance.

# gb <bytes>: the amount in GB with one decimal.
gb() {
  local amount
  # Reports must finish, so an amount that cannot be computed reads 0.0.
  amount=$(jq -n "$1 / 1e9") || amount=0
  printf '%.1f GB' "$amount"
}
