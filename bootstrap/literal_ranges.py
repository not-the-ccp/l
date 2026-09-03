from __future__ import annotations

"""Integer-literal range checks for the bootstrap semantic oracle."""


def install(core):
    if getattr(core, "_literal_ranges_installed", False):
        return

    Checker = core.Checker
    original_expr = Checker.expr

    def expr(self, node, expected=None):
        ty = original_expr(self, node, expected)
        if node.kind == "int":
            info = core.int_info(ty)
            if info is not None:
                width, signed = info
                value = core.parse_int_text(node.a[0])
                if signed:
                    low = -(1 << (width - 1))
                    high = (1 << (width - 1)) - 1
                else:
                    low = 0
                    high = (1 << width) - 1
                if not low <= value <= high:
                    self.err(f"integer literal {value} does not fit {ty}", node)
        return ty

    Checker.expr = expr
    core._literal_ranges_installed = True
