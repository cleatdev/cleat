# A bare [[ ]], (( )) or "! cmd" inside a bats test decides nothing unless it is
# the last command the test runs: bash before 4.1 does not stop a test under
# errexit when [[ ]] or (( )) fails, no bash ever stops on a command negated
# with ! and none stops on the first check of an AND list. On the macOS leg (bash 3.2) such a check passes whatever it
# finds. This flags one when the next statement of the test is anything but
# the close of a function or group body (its value is that body's status),
# and always inside a loop (only the last pass would count). Prints
# file:line for each and exits 1 when there is one.
#
#   awk -f bare_check_midtest.awk test/unit/*.bats

function is_bare(t) {
  if (t ~ /\\$/ || t ~ /\|\|/) return 0
  # An AND list of checks ([ a ] && [ b ]) hides its first check's failure the
  # same way, on every bash. One that ends in a command is a conditional.
  if (t ~ /&&/) return (t ~ /^(\[|\(\(|! ).*&& *(\[|\(\(|! )/)
  return (t ~ /^(\[\[ |\(\( |! )/)
}
function report() { print FILENAME ":" pl ": " substr(pt, 1, 90); bad++ }

/^@test / { intest = 1; pend = 0; next }
intest && /^}$/ { intest = 0; pend = 0; next }
intest {
  t = $0
  sub(/^[ \t]+/, "", t)
  if (t == "" || t ~ /^#/) next
  if (pend) {
    if (t ~ /^done/) report()
    else if (t !~ /^(}|fi|esac|;;)/) report()
    pend = 0
  }
  if (is_bare(t)) { pend = 1; pl = FNR; pt = t }
}
END { exit bad ? 1 : 0 }
