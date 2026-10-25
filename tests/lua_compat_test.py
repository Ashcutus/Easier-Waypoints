"""Runtime Lua must load in the game's embedded Lua 5.2.2, not only in the 5.4 test runner."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "mod" / "easier_waypoints_1" / "content"

# Lua 5.3+ syntax and libraries, plus Lua 5.1 globals that 5.2 removed.
FORBIDDEN = {
    "integer division": r"//",
    "bitwise operator": r"[&|]|<<|>>|~(?!=)",
    "variable attribute": r"<\s*(?:const|close)\s*>",
    "utf8 library": r"\butf8\.",
    "Lua 5.3 math function": r"\bmath\.(?:tointeger|type|ult|maxinteger|mininteger)\b",
    "Lua 5.3 string packing": r"\bstring\.(?:pack|unpack|packsize)\b",
    "table.move": r"\btable\.move\b",
    "Lua 5.1 global": r"(?<![.:\w])(?:setfenv|getfenv|loadstring|unpack|module)\s*\(",
}

TOKEN = re.compile(r"""--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'""", re.S)


def code_only(source):
    # Comments and string contents cannot break compatibility; drop them first.
    return TOKEN.sub(lambda match: " " if match.group(0).startswith("--") else '""', source)


def problems(source):
    code = code_only(source)
    return [name for name, pattern in FORBIDDEN.items() if re.search(pattern, code)]


class LuaCompatibilityTests(unittest.TestCase):
    def test_checker_ignores_strings_and_comments(self):
        self.assertEqual(problems('local a = "x // y | z" -- a // b\n--[[ utf8.char() ]] local b = a ~= nil'), [])
        self.assertEqual(problems("local a = 7 // 2"), ["integer division"])
        self.assertEqual(problems("local a = b & c"), ["bitwise operator"])
        self.assertEqual(problems("local x <const> = 1"), ["variable attribute"])
        self.assertEqual(problems("local a = unpack(t)"), ["Lua 5.1 global"])
        self.assertEqual(problems("local a = table.unpack(t)"), [])

    def test_runtime_lua_is_lua52_compatible(self):
        files = sorted(RUNTIME.rglob("*.lua"))
        self.assertTrue(files)
        for path in files:
            with self.subTest(path=path.relative_to(ROOT).as_posix()):
                self.assertEqual(problems(path.read_text(encoding="utf-8")), [])


if __name__ == "__main__":
    unittest.main()
