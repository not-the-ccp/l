from __future__ import annotations

"""Const-array support for the bootstrap frontend."""


def install(core):
    if getattr(core, "_const_arrays_installed", False):
        return

    Ty = core.Ty

    class ConstArrayTy(Ty):
        """Read-only capability for one array layer.

        ``kind`` remains ``array`` so the interpreter, bytecode compiler, native
        backend, GC/layout code, and host boundary keep the same runtime
        representation. The distinct Python class gives the static checker a
        distinct type identity without adding runtime state.
        """

        __slots__ = ()

        def __init__(self, element):
            object.__setattr__(self, "kind", "array")
            object.__setattr__(self, "a", (element,))

        def __str__(self):
            return "const []" + str(self.a[0])

    def const_arr(element):
        return ConstArrayTy(element)

    def is_const_array(ty):
        return isinstance(ty, ConstArrayTy)

    def is_mutable_array(ty):
        return isinstance(ty, Ty) and ty.kind == "array" and not is_const_array(ty)

    core.ConstArrayTy = ConstArrayTy
    core.const_arr = const_arr
    core.is_const_array = is_const_array
    core.is_mutable_array = is_mutable_array

    original_parser_type = core.Parser.type

    def parser_type(self):
        if self.maybe("const"):
            start = self.ts[self.i - 1].span
            if not self.maybe("["):
                raise core.LangError(
                    "const in a type must qualify an array: expected []",
                    start,
                )
            self.take("]")
            return const_arr(self.type())
        return original_parser_type(self)

    core.Parser.type = parser_type

    original_substitute = core.substitute

    def substitute(ty, mapping):
        if is_const_array(ty):
            return const_arr(substitute(ty.a[0], mapping))
        return original_substitute(ty, mapping)

    core.substitute = substitute

    Checker = core.Checker
    original_resolve_ty = Checker.resolve_ty

    def resolve_ty(self, ty):
        if is_const_array(ty):
            return const_arr(self.resolve_ty(ty.a[0]))
        return original_resolve_ty(self, ty)

    Checker.resolve_ty = resolve_ty

    original_req = Checker.req

    def req(self, expected, actual, node=None):
        # The sole implicit qualification conversion is shallow []T -> const []T.
        if (
            is_const_array(expected)
            and is_mutable_array(actual)
            and expected.a[0] == actual.a[0]
        ):
            return
        return original_req(self, expected, actual, node)

    Checker.req = req

    original_expr = Checker.expr

    def expr(self, node, expected=None):
        if node.kind == "string":
            u8 = core.name_ty("u8")
            # With no mutable context, strings infer as const []u8. An explicit
            # mutable []u8 context materializes this fresh literal as mutable;
            # this is literal contextual typing, not const-to-mutable conversion.
            if (
                expected is not None
                and is_mutable_array(expected)
                and expected.a[0] == u8
            ):
                ty = core.arr(u8)
            else:
                ty = const_arr(u8)
            node.ty = ty
            self.expr_types[id(node)] = ty
            if expected is not None:
                self.req(expected, ty, node)
            return ty
        return original_expr(self, node, expected)

    Checker.expr = expr

    original_call_type = Checker.call_type

    def call_type(self, node, expected):
        callee, args = node.a
        if (
            callee.kind == "qname"
            and len(callee.a[0]) == 1
            and callee.a[0][0] in self.builtins
        ):
            name = callee.a[0][0]

            if name == "len":
                if len(args) != 1:
                    self.err("len expects one argument", node)
                array_ty = self.expr(args[0])
                if array_ty.kind != "array":
                    self.err("len expects an array", args[0])
                return core.name_ty("u64")

            if name == "push":
                if len(args) != 2:
                    self.err("push expects two arguments", node)
                array_ty = self.expr(args[0])
                if not is_mutable_array(array_ty):
                    if is_const_array(array_ty):
                        self.err("push requires mutable []T, got const []T", args[0])
                    self.err("push first argument must be []T", args[0])
                self.req(
                    array_ty.a[0],
                    self.expr(args[1], array_ty.a[0]),
                    args[1],
                )
                return core.UNIT

            if name == "pop":
                if len(args) != 1:
                    self.err("pop expects one argument", node)
                array_ty = self.expr(args[0])
                if not is_mutable_array(array_ty):
                    if is_const_array(array_ty):
                        self.err("pop requires mutable []T, got const []T", args[0])
                    self.err("pop expects []T", args[0])
                return array_ty.a[0]

            if name == "splice":
                if len(args) != 4:
                    self.err("splice expects array, start, end, replacement", node)
                array_ty = self.expr(args[0])
                if not is_mutable_array(array_ty):
                    if is_const_array(array_ty):
                        self.err("splice requires mutable []T target", args[0])
                    self.err("splice first argument must be []T", args[0])

                u64 = core.name_ty("u64")
                self.req(u64, self.expr(args[1], u64), args[1])
                self.req(u64, self.expr(args[2], u64), args[2])

                replacement_ty = const_arr(array_ty.a[0])
                self.req(
                    replacement_ty,
                    self.expr(args[3], replacement_ty),
                    args[3],
                )
                return core.UNIT

        return original_call_type(self, node, expected)

    Checker.call_type = call_type

    original_place = Checker.place

    def place(self, node):
        if node.kind == "index":
            array_ty = self.expr(node.a[0])
            if is_const_array(array_ty):
                self.err("cannot assign through const []T", node)
        return original_place(self, node)

    Checker.place = place
    core._const_arrays_installed = True
