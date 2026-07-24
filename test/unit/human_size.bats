#!/usr/bin/env bats
# The shared docker human-size parser (_human_size_to_bytes / _SIZE_AWK). Backs
# every size the CLI reports (cleat storage, the disk advisory, prune --cache
# reclaimed bytes, the image-bloat sum). Two portability guards are load-bearing
# and each has a fixture: printf "%.0f" (mawk clamps %d at 2^31, so any size
# >= 2 GB collapses) and the digit-before-unit rule (a bare "kB"/"TB" must be 0).

load "../setup"

setup() { _common_setup; source_cli; }
teardown() { _common_teardown; }

_p() { run _human_size_to_bytes "$1"; }

@test "size parser: bare GB" { _p "36.34GB"; assert_output "39019777884"; }
@test "size parser: strips the system-df (NN%) reclaimable suffix" { _p "Images 36.34GB (57%)"; assert_output "39019777884"; }
@test "size parser: reclaimable field shape with percent" { _p "30.1GB (82%)"; assert_output "32319628902"; }
@test "size parser: MB" { _p "67.95MB"; assert_output "71250739"; }
@test "size parser: lowercase kB" { _p "512kB"; assert_output "524288"; }
@test "size parser: uppercase KB" { _p "512KB"; assert_output "524288"; }
@test "size parser: TB overflows a 32-bit int, proving the %.0f guard" { _p "2.5TB"; assert_output "2748779069440"; }
@test "size parser: PB stays exact under a double" { _p "2.5PB"; assert_output "2814749767106560"; }
@test "size parser: zero with a valid unit is 0" { _p "0B"; assert_output "0"; }
@test "size parser: empty is 0" { _p ""; assert_output "0"; }
@test "size parser: a bare unit with no digit is 0 (kB)" { _p "kB"; assert_output "0"; }
@test "size parser: a bare unit with no digit is 0 (TB)" { _p "TB"; assert_output "0"; }
@test "size parser: the docker ps -s field takes the leftmost token" { _p "1.05MB (virtual 1.2GB)"; assert_output "1101005"; }
@test "size parser: raw bytes-with-B round-trips" { _p "1610612736B"; assert_output "1610612736"; }
@test "size parser: garbage with no unit is 0" { _p "not-a-size"; assert_output "0"; }
