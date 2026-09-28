# A case statement inside a $( ): bash 3.2 finds the end of a command
# substitution by counting parentheses, so the first case pattern's ) closes it
# early and the rest is a syntax error at run time. This finds each $( ... )
# the way 3.2 does (unquoted parens counted, single quotes, double quotes,
# comments and heredoc bodies skipped) and flags any whose body holds the word
# case. Prints file:line for each and exits 1 when there is one.
#
#   awk -f case_in_subst.awk bin/cleat

function flag(ln, txt) { print FILENAME ":" ln ": " txt; bad++ }

# The heredoc terminator a line opens, or "" for none. A quoted terminator and
# an unquoted one are both skipped: no case belongs in a heredoc body.
function heredoc_word(s,    i, w) {
  i = index(s, "<<")
  if (!i || substr(s, i + 2, 1) == "<") return ""
  w = substr(s, i + 2)
  sub(/^-/, "", w)
  sub(/^[ \t]*/, "", w)
  gsub(/["']/, "", w)
  sub(/[^A-Za-z0-9_].*$/, "", w)
  if (w !~ /^[A-Za-z_]/) return ""
  return w
}

BEGIN { depth = 0; hd = "" }

# body[d] holds the UNQUOTED text of the substitution open at depth d: 3.2
# skips quoted text when it matches parens, so a quoted "case" is harmless. A
# nested substitution is checked on its own and stands in its parent as $().
{
  line = $0
  if (hd != "") {
    t = line; sub(/^[\t]*/, "", t)
    if (t == hd) hd = ""
    next
  }
  n = length(line)
  i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (inq == "'") {
      if (c == "'") inq = ""
      i++; continue
    }
    if (c == "\\") { if (depth && inq == "") body[depth] = body[depth] " "; i += 2; continue }
    if (inq == "\"" && c == "\"" && dqd == depth) { inq = ""; i++; continue }
    if (inq == "") {
      if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;(|&]/)) break
      if (c == "'") { inq = "'"; i++; continue }
      if (c == "\"") { inq = "\""; dqd = depth; i++; continue }
    }
    if (c == "$" && substr(line, i + 1, 1) == "(") {
      depth++; paren[depth] = 1; body[depth] = ""; start[depth] = NR; saveq[depth] = inq; savedqd[depth] = dqd
      inq = ""; i += 2; continue
    }
    if (depth && inq == "") {
      if (c == "(") paren[depth]++
      else if (c == ")") {
        paren[depth]--
        if (paren[depth] == 0) {
          if (body[depth] ~ /(^|[^A-Za-z0-9_])case[ \t]/) flag(start[depth], substr(body[depth], 1, 80))
          inq = saveq[depth]; dqd = savedqd[depth]
          depth--
          if (depth && inq == "") body[depth] = body[depth] "$()"
          i++; continue
        }
      }
      body[depth] = body[depth] c
    }
    i++
  }
  if (depth && inq == "") body[depth] = body[depth] "\n"
  if (depth == 0 && inq == "") {
    w = heredoc_word(line)
    if (w != "") hd = w
  }
}

END { exit bad ? 1 : 0 }
