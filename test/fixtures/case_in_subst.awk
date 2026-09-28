# A case statement inside a $( ) that spans lines: bash 3.2 reads the first
# pattern's ) as the end of the substitution.
/^[[:space:]]*#/ { next }
{
  line = $0
  if (open) {
    if (line ~ /(^|[^a-z_])case[[:space:]].*[[:space:]]in([[:space:]]|$)/) { print FILENAME ":" NR ": " line; bad++ }
    if (line ~ /\)"/ || line ~ /^[[:space:]]*\)[[:space:]]*$/ || line ~ /\)[[:space:]]*(\|\||&&|;|$)/ && line !~ /case/) open = 0
    next
  }
  i = index(line, "$(")
  if (i) {
    rest = line
    while ((j = index(rest, "$(")) > 0) rest = substr(rest, j + 2)
    if (rest !~ /\)/) open = 1
  }
}
END { exit bad ? 1 : 0 }
