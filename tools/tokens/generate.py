#!/usr/bin/env python3
"""Generate platform files from design/tokens.json.

The JSON holds three layers: primitive values, semantic roles, and a binding
section that names the symbol each platform uses for a role. This script reads
only the JSON plus the bindings, so a new platform is a new emitter here, not a
new set of hand-written values.

Usage:
    python3 tools/tokens/generate.py            # write the generated files
    python3 tools/tokens/generate.py --check    # fail if any file is stale
"""

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOKENS = ROOT / "design" / "tokens.json"

SWIFT_OUT = ROOT / "packages/ReadLaterUI/Sources/ReadLaterUI/Generated/ThemeTokens.swift"
CSS_OUT = ROOT / "design/generated/tokens.css"
KOTLIN_OUT = ROOT / "design/generated/Tokens.kt"
XAML_OUT = ROOT / "design/generated/Tokens.xaml"

HEADER = "Generated from design/tokens.json by tools/tokens/generate.py. Do not edit."


def camel(name):
    parts = re.split(r"[.\-]", name)
    head, *tail = parts
    return head + "".join(p[:1].upper() + p[1:] for p in tail)


def pascal(name):
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[.\-]", name))


def kebab(name):
    return name.replace(".", "-")


def resolve(primitive, ref):
    if ref not in primitive:
        raise SystemExit(f"unknown primitive colour {ref!r}")
    return primitive[ref]


def hex_arg(value):
    return "0x" + value.lstrip("#").upper()


def ensure(path, text, check, stale):
    current = path.read_text() if path.exists() else None
    if current != text:
        if check:
            stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)


def swift_file(doc):
    primitive = doc["primitive"]["color"]
    colours = doc["semantic"]["color"]
    names = doc["platform"]["swift"]["names"]
    font_names = doc["platform"]["swift"].get("fontNames", {})
    type_ = doc["semantic"]["typography"]
    space = doc["semantic"]["space"]
    radius = doc["semantic"]["radius"]
    size = doc["semantic"]["size"]

    lines = [
        "// " + HEADER,
        "// A view reads these names. A value change happens in the JSON.",
        "",
        "import SwiftUI",
        "",
        "public extension Theme {",
        "    // MARK: - Colour (layer 2, bound to this platform)",
        "",
    ]
    for role, entry in colours.items():
        name = names[role]
        light, dark = entry["light"], entry["dark"]
        alpha = None
        if isinstance(light, dict):
            alpha = light["alpha"]
            light = resolve(primitive, light["color"])
            dark = resolve(primitive, dark["color"])
        else:
            light = resolve(primitive, light)
            dark = resolve(primitive, dark)
        desc = entry.get("description", "")
        lines.append(f"    /// `{role}`. {desc}".rstrip())
        call = f"themedColor(light: {hex_arg(light)}, dark: {hex_arg(dark)})"
        if alpha is not None:
            call += f".opacity({alpha})"
        lines.append(f"    static let {name} = {call}")
        # The raw pair, for the platform adapters that must build a UIColor or
        # NSColor before SwiftUI resolves a Color.
        lines.append(f"    static let {name}Hex: (light: UInt32, dark: UInt32) = ({hex_arg(light)}, {hex_arg(dark)})")
        lines.append("")

    lines += ["    // MARK: - Type (layer 2)", ""]
    weights = {
        "regular": "regular", "medium": "medium", "semibold": "semibold", "bold": "bold",
    }
    designs = {"serif": "serif", "sans": "default", "mono": "monospaced"}
    for role, spec in type_.items():
        weight = weights[spec["weight"]]
        design = designs[spec["family"]]
        desc = spec.get("description", "")
        size_pt = spec["size"]
        mod = ".monospacedDigit()" if spec.get("monospacedDigit") else ""
        symbol = font_names.get(role, role)
        lines.append(f"    /// `{role}`. {desc}".rstrip())
        lines.append(
            f"    static func {symbol}() -> Font {{ .system(size: {size_pt}, weight: .{weight}, design: .{design}){mod} }}"
        )
        # The text engines need the numbers before SwiftUI resolves a Font.
        lines.append(f"    static let {symbol}Size: CGFloat = {size_pt}")
        if "line" in spec:
            lines.append(f"    static let {symbol}Line: CGFloat = {spec['line']}")
        lines.append("")

    lines += ["    // MARK: - Space, shape, size (layer 2)", ""]
    for role, spec in space.items():
        lines.append(f"    /// `{role}`. {spec['description']}")
        lines.append(f"    public static let {role}: CGFloat = {spec['value']}")
        lines.append("")
    for role, spec in radius.items():
        lines.append(f"    /// `radius.{role}`. {spec['description']}")
        lines.append(f"    public static let {role}Radius: CGFloat = {spec['value']}")
        lines.append("")
    for role, spec in size.items():
        if role in ("minTarget", "maxLineWidth"):
            continue  # named exactly below
        lines.append(f"    /// `size.{role}`. {spec['description']}")
        lines.append(f"    public static let {role}: CGFloat = {spec['value']}")
        lines.append("")
    lines.append(f"    /// `size.minTarget`. {size['minTarget']['description']}")
    lines.append(f"    public static let minTarget: CGFloat = {size['minTarget']['value']}")
    lines.append("")
    lines.append(f"    /// `size.maxLineWidth`. {size['maxLineWidth']['description']}")
    lines.append(f"    public static let maxLineWidth: CGFloat = {size['maxLineWidth']['value']}")
    lines.append("")
    body = type_["body"]
    lines.append("    /// The body line box, minus the type size.")
    lines.append(f"    public static let bodyLineSpacing: CGFloat = {body['line'] - body['size']}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def css_file(doc):
    primitive = doc["primitive"]["color"]
    colours = doc["semantic"]["color"]
    space = doc["semantic"]["space"]
    radius = doc["semantic"]["radius"]
    size = doc["semantic"]["size"]
    motion = doc["semantic"]["motion"]
    type_ = doc["semantic"]["typography"]

    def block(roles, mode):
        out = []
        for role, entry in roles.items():
            value = entry[mode]
            if isinstance(value, dict):
                hexv = resolve(primitive, value["color"])
                out.append(f"  --{kebab(role)}: {hexv}{int(value['alpha'] * 255):02X};")
            else:
                out.append(f"  --{kebab(role)}: {resolve(primitive, value)};")
        return out

    light = block(colours, "light")
    dark = block(colours, "dark")

    extra = []
    for role, spec in space.items():
        extra.append(f"  --{kebab(role)}: {spec['value']}px;")
    for role, spec in radius.items():
        extra.append(f"  --radius-{kebab(role)}: {spec['value']}px;")
    for role, spec in size.items():
        extra.append(f"  --size-{kebab(role)}: {spec['value']}px;")
    for role, spec in motion.items():
        extra.append(f"  --motion-{kebab(role)}: {spec['duration']}ms;")
    for role, spec in type_.items():
        extra.append(f"  --type-{kebab(role)}-size: {spec['size']}px;")
        if "line" in spec:
            extra.append(f"  --type-{kebab(role)}-line: {spec['line']}px;")

    lines = [
        f"/* {HEADER} */",
        "",
        ":root {",
        *light,
        *extra,
        "}",
        "",
        "@media (prefers-color-scheme: dark) {",
        "  :root {",
        *[f"  {line}" for line in dark],
        "  }",
        "}",
        "",
        '[data-theme="light"] {',
        *light,
        "}",
        "",
        '[data-theme="dark"] {',
        *dark,
        "}",
    ]
    return "\n".join(lines) + "\n"


def kotlin_file(doc):
    primitive = doc["primitive"]["color"]
    colours = doc["semantic"]["color"]
    space = doc["semantic"]["space"]
    radius = doc["semantic"]["radius"]
    size = doc["semantic"]["size"]
    type_ = doc["semantic"]["typography"]
    motion = doc["semantic"]["motion"]

    props = ", ".join(f"val {camel(role)}: Color" for role in colours)
    lines = [
        f"// {HEADER}",
        "package app.readlater.design",
        "",
        "import androidx.compose.foundation.isSystemInDarkTheme",
        "import androidx.compose.runtime.Composable",
        "import androidx.compose.runtime.ReadOnlyComposable",
        "import androidx.compose.ui.graphics.Color",
        "import androidx.compose.ui.unit.Dp",
        "import androidx.compose.ui.unit.dp",
        "import androidx.compose.ui.unit.sp",
        "",
        "/** Semantic colours. The component layer is Compose; these are layer 2. */",
        "interface ReadLaterTokens {",
        f"    {props}",
        "}",
        "",
        "object LightTokens : ReadLaterTokens {",
    ]
    def kt_color(value):
        if isinstance(value, dict):
            hexv = resolve(primitive, value["color"])
            return f"Color(0xFF{hexv.lstrip('#').upper()}).copy(alpha = {value['alpha']}f)"
        return f"Color(0xFF{resolve(primitive, value).lstrip('#').upper()})"

    for role, entry in colours.items():
        lines.append(f"    override val {camel(role)} = {kt_color(entry['light'])}")
    lines += ["}", "", "object DarkTokens : ReadLaterTokens {"]
    for role, entry in colours.items():
        lines.append(f"    override val {camel(role)} = {kt_color(entry['dark'])}")
    lines += [
        "}",
        "",
        "@Composable",
        "@ReadOnlyComposable",
        "fun tokens(): ReadLaterTokens = if (isSystemInDarkTheme()) DarkTokens else LightTokens",
        "",
        "/** Layer 2 sizes. Android scales these with sp where text is involved. */",
        "object Space {",
    ]
    for role, spec in space.items():
        lines.append(f"    val {role} = {spec['value']}.dp")
    for role, spec in radius.items():
        lines.append(f"    val {role}Radius = {spec['value']}.dp")
    for role, spec in size.items():
        lines.append(f"    val {role} = {spec['value']}.dp")
    lines += [
        "}",
        "",
        "/** Layer 2 type sizes. Compose builds its own TextStyle from these. */",
        "object TypeScale {",
    ]
    for role, spec in type_.items():
        lines.append(f"    val {camel(role)}Size = {spec['size']}.sp")
        if "line" in spec:
            lines.append(f"    val {camel(role)}Line = {spec['line']}.sp")
    lines += ["}", "", "/** Layer 2 motion durations in milliseconds. */", "object Motion {"]
    for role, spec in motion.items():
        lines.append(f"    const val {camel(role)} = {spec['duration']}L")
    lines += ["}"]
    return "\n".join(lines) + "\n"


def xaml_file(doc):
    primitive = doc["primitive"]["color"]
    colours = doc["semantic"]["color"]
    space = doc["semantic"]["space"]
    radius = doc["semantic"]["radius"]
    size = doc["semantic"]["size"]

    def entry(prefix, mode):
        out = []
        for role, spec in colours.items():
            value = spec[mode]
            if isinstance(value, dict):
                hexv = resolve(primitive, value["color"])
                alpha = f"{int(value['alpha'] * 255):02X}"
                out.append(f'                <Color x:Key="{prefix}{pascal(role)}">#{alpha}{hexv.lstrip("#").upper()}</Color>')
            else:
                out.append(f'                <Color x:Key="{prefix}{pascal(role)}">{resolve(primitive, value)}</Color>')
        return out

    lines = [
        f"<!-- {HEADER} -->",
        '<ResourceDictionary',
        '    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"',
        '    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">',
        "    <ResourceDictionary.ThemeDictionaries>",
        '        <ResourceDictionary x:Key="Light">',
        *entry("", "light"),
        "        </ResourceDictionary>",
        '        <ResourceDictionary x:Key="Dark">',
        *entry("", "dark"),
        "        </ResourceDictionary>",
        "    </ResourceDictionary.ThemeDictionaries>",
    ]
    for role, spec in space.items():
        lines.append(f'    <x:Double x:Key="Space{pascal(role)}">{spec["value"]}</x:Double>')
    for role, spec in radius.items():
        lines.append(f'    <x:Double x:Key="Radius{pascal(role)}">{spec["value"]}</x:Double>')
    for role, spec in size.items():
        lines.append(f'    <x:Double x:Key="Size{pascal(role)}">{spec["value"]}</x:Double>')
    for role, spec in doc["semantic"]["typography"].items():
        lines.append(f'    <x:Double x:Key="Type{pascal(role)}Size">{spec["size"]}</x:Double>')
        if "line" in spec:
            lines.append(f'    <x:Double x:Key="Type{pascal(role)}Line">{spec["line"]}</x:Double>')
    for role, spec in doc["semantic"]["motion"].items():
        lines.append(f'    <x:Int32 x:Key="Motion{pascal(role)}">{spec["duration"]}</x:Int32>')
    lines.append("</ResourceDictionary>")
    return "\n".join(lines) + "\n"


def validate(doc):
    """Fail before writing when the JSON cannot produce a usable file."""
    primitive = doc["primitive"]["color"]
    colours = doc["semantic"]["color"]

    for role, entry in colours.items():
        for mode in ("light", "dark"):
            value = entry[mode]
            if isinstance(value, dict):
                if "color" not in value or "alpha" not in value:
                    raise SystemExit(f"{role}.{mode}: needs color and alpha")
                resolve(primitive, value["color"])
                if not 0 <= value["alpha"] <= 1:
                    raise SystemExit(f"{role}.{mode}: alpha out of range")
            else:
                resolve(primitive, value)

    swift = doc["platform"]["swift"]["names"]
    missing = [role for role in colours if role not in swift]
    if missing:
        raise SystemExit("swift binding missing: " + ", ".join(missing))
    symbols = list(swift.values())
    dupes = {s for s in symbols if symbols.count(s) > 1}
    if dupes:
        raise SystemExit("swift symbol used twice: " + ", ".join(sorted(dupes)))

    font_names = doc["platform"]["swift"].get("fontNames", {})
    for role in doc["semantic"]["typography"]:
        symbol = font_names.get(role, role)
        if symbol in symbols:
            raise SystemExit(f"type symbol {symbol!r} collides with a colour symbol")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    doc = json.loads(TOKENS.read_text())
    validate(doc)
    stale = []
    ensure(SWIFT_OUT, swift_file(doc), args.check, stale)
    ensure(CSS_OUT, css_file(doc), args.check, stale)
    ensure(KOTLIN_OUT, kotlin_file(doc), args.check, stale)
    ensure(XAML_OUT, xaml_file(doc), args.check, stale)

    if args.check and stale:
        print("stale: " + ", ".join(stale), file=sys.stderr)
        return 1
    print("tokens: ok" if args.check else "tokens: written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
