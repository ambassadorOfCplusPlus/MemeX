# Catch the one editing mistake this project makes over and over: a "\n" inside a C string
# literal collapsing into a REAL newline when the edit passes through a shell heredoc. The
# compiler does catch it - "C2001: newline in constant" - but only after a five-minute build,
# and it has now cost a build cycle in the middle of a measurement more than once.
#
# The test is deliberately dumb: a line of code that opens a double-quoted string and never
# closes it is broken. Line comments and raw string literals are skipped, and a trailing
# backslash (line continuation) is allowed.
#
# Run it on every source touched, BEFORE handing the tree to a build:
#   python bench/check_literals.py <file> [<file> ...]
import re
import sys

QUOTE = re.compile(r'(?<!\\)"')
ESCAPED_BACKSLASH = "\\" + "\\"


def broken_lines(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            text = line.rstrip("\r\n")
            code = text.split("//", 1)[0] if "//" in text else text
            if 'R"' in code or code.rstrip().endswith("\\"):
                continue
            # Drop escaped backslashes first, so that a literal ending in \\ is not mistaken
            # for an escaped quote.
            flat = code.replace(ESCAPED_BACKSLASH, "")
            if len(QUOTE.findall(flat)) % 2 == 1:
                out.append((n, text.strip()))
    return out


def main(argv):
    rc = 0
    for path in argv:
        bad = broken_lines(path)
        if bad:
            rc = 1
            print("%s: nezakrytyh strokovyh literalov: %d" % (path, len(bad)))
            for n, text in bad[:10]:
                print("   %d: %s" % (n, text[:110]))
    print("chisto" if rc == 0 else "NAJDENY OBORVANNYE LITERALY")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
