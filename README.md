# Type Refinement

Type refinement attaches information onto runtime values concerning the comptime-known range of the value learned from
comparisons against both comptime values and runtime values that have existing metadata. Every operation performed
on variables either narrows or expands stat which we know statically.

## Scope

This proposal adds type refinement which involves:

- runtime values having compile-time known ranges of values
- any comparison made provides knowledge at compile-time about the range of values of a runtime value
- any computation made either expands or contracts the statically known range of values of a runtime value
- runtime values being "promoted" to comptime values if tests reduce the possible range of values to one value
- refinement of one runtime value may provide information towards refinement of another

This proposal does not:

- define new syntax
- define any features related to resource types (linear, affine, etc) nor resource management
- try to solve the halting problem

## Introduction

Suppose a user tests to see if a runtime value is equivalent to 5:

    lang: zig esc: none file: is_five.zig
    -------------------------------------

    extern fn foo() u32;

    inline fn eql(x: anytype, comptime c: @TypeOf(x)) bool {
        return x == c;
    }

    test {
        const runtime = foo();
        const value = eql(runtime, 5);

        if (value) {
            // value is statically known to be 5 within this
        } else {
            // value is statically known to not be 5 within this scope
        }
    }

The user can statically determine the value of the runtime value given the above tests however zig represents it as
runtime-only information and thus won't consider `value` to be comptime known within the branch despite it being
statically known. What is really being encoded here is:

    extern fn foo() u32;

    fn eql(x: anytype, comptime c: @TypeOf(x)) (b: bool | if (b) (x == c) else (x != c)) {
        return x == c;
    }

    test {
        const result: (x: u32 | x) = foo();
        const is_five: (b: bool | if (b) (x == 5) else (x != 5)) = eql<x>(result, 5);

        if (is_five) {
            comptime assert(@TypeOf(value) == (x: u32 | x == 5));

            // `result` is statically known to be 5 thus is effectively a _comptime-known_ value of type u32
            // yet outside this branch the value remains runtime known.
        } else {
            comptime assert(@TypeOf(value) == (x: u32 | x != 5));

            // `result` is statically known to not be 5 and thus only the fact that it's not 5 is
            // _comptime-known_ while the rest of the range is only runtime known.
        }
    }

Where `(x: T | prop)` expresses that the `x` of type `T` has the property `prop` learned^[note that the syntax
used here is not part of the proposal and is only for demonstrating the state of type refinement] (or in other
cases preserved) after applying `eql`. `eql` also only provides new information on `x` as `c` is fully
comptime-known thus we know everything there is to know about `c`.

In the first branch, `result` is effectively comptime-known thus could be treated like a comptime-known u32 within
the branch despite the source being runtime-only as we've proven a property is true for that branch with the use
of `is_five`.

This proposals explores the addition of such a feature and the implications for existing code.

## Use case: index safety

## Interaction with unreachable and return

    extern fn foo() u32;

    test {
        const tmp: u32 = foo();
        const ok: (b: bool | if (b) (x > 5) else (x <= 5)) = result > 5;

        if (!ok) {
            comptime assert(@TypeOf(tmp) == (x: u32 | x <= 5));
            unreachable;
        }

        comptime assert(@TypeOf(tmp) == (x: u32 | x > 5));
    }

Which can be rewritten as

    extern fn foo() u32;

    test {
        const result: u32 = foo();
        const ok: (b: bool | if (b) (x > 5) else (x <= 5)) = result > 5;

        if (!ok) {
            comptime assert(@TypeOf(result) == (x: u32 | x <= 5));
            unreachable;
        } else {
            comptime assert(@TypeOf(result) == (x: u32 | x > 5));
        }

    }

An `unreachable` branch states that it's an impossible state to get to thus the refinement of `result` is known for the
rest of the current block. Similar, return in the same position states that if the return isn't reached then the
refinements within the other branch can be applied to the containing block instead of just an `else` as there's only one
path.

## Control-flow

    lang: zig esc: none file: control-flow.zig
    ------------------------------------------

    extern fn foo() u32;

    const Example = enum(u8) { a, b, c, d, e };

    test {
        const tag = @intToEnum(Example, foo());

        switch (tag) {
            .a, .b => switch (tag) {
                .a => {},
                .b => {},

                // dead code branch, not sent to codegen and possibly
                // a compile error (unreachable code)
                .c, .d, .e => unreachable,
            },
            .c => {},
            .d => {},
            .e => {},
        }
    }

    test {
        const tag = foo();
        if (tag == .a or tag == .b) switch (tag) {
            .a => {},
            .b => {},

            // dead code branch, not sent to codegen and possibly
            // a compile error (unreachable code)
            // .c, .d, .e => {},
        };
    }

## Safety checks

    lang: zig esc: none file: safety-check.zig
    ------------------------------------------

    const meta = @import("std").meta;
    extern fn foo() u32;
    const Example = enum(u8) { a, b, c };

    test {
        const tmp = foo();
        const len = meta.fieldInfo(Example).len;

        if (tmp < len) {
            // no safety check needed as the value is statically known to be within range
            const x: Example = @intToEnum(Example, tmp);
            _ = x;
        }
    }

# References

- https://ucsd-progsys.github.io/liquidhaskell/

# Related material

- https://idris2.readthedocs.io/en/latest/tutorial/multiplicities.html
- http://ats-lang.sourceforge.net/DOCUMENT/INT2PROGINATS/HTML/c2584.html
- http://ats-lang.sourceforge.net/DOCUMENT/INT2PROGINATS/HTML/c3321.html
- https://bluishcoder.co.nz/2014/04/11/preventing-heartbleed-bugs-with-safe-languages.html

# Extension: constraints in type signatures

Allowing the use of refinement type constraints within type signatures prevents passing the wrong length at runtime by
associating the length with the variable it.

    extern "console" fn consoleLogRaw(
        level: u8,
        buffer: [*:0]const u8,
        len: (n: usize | n < mem.len(buffer)),
    ) void;

    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const scope_prefix = "(" ++  @tagName(scope) ++ "): ";
        const prefix = "[" ++ level.asText() ++ "] " ++ scope_prefix;

        var scratch: [1024]u8 = undefined;

        const len: (n: usize | n <= scratch.len) = std.fmt.bufPrint(&scratch, format, args) catch return;
        consoleLogRaw(@enumToInt(level), &scratch, len);
    }
