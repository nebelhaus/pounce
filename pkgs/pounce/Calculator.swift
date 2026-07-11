import Foundation

// MARK: - Calculator (math quick-answer engine)

// The pure-Swift expression evaluator behind the launcher's inline calculator.
// Hand-rolled Pratt parser rather than NSExpression: NSExpression raises
// ObjC exceptions on malformed input (every second keystroke here) and its
// grammar can't do `%`, `20% of 150`, or unicode operators.
//
// Supported: + - * / ^ mod, ×÷−·, parentheses, unary minus, percent
// (`100 + 10%` → 110, `50 * 10%` → 5, `20% of 150` → 30), implicit
// multiplication (`2(3+4)`, `2pi`), scientific literals (`2e5`), thousands
// separators (`1,000 + 5`), constants (pi/π/tau/e), and one-argument
// functions (sqrt, ln, sin, …).

struct MathEngine: QuickAnswerEngine {
    func evaluate(_ query: String) -> QuickAnswer? {
        guard let result = Calc.evaluate(query) else { return nil }
        // A bare number ("847", "-3", "(42)") is a search, not a sum — only
        // answer when the user actually wrote math.
        guard result.sawOperation else { return nil }
        let value = result.value
        guard value.isFinite else { return nil }
        return QuickAnswer(
            display: CalcFormat.display(value),
            detail: query.trimmingCharacters(in: .whitespaces),
            icon: "equal.square",
            copyText: CalcFormat.copyText(value))
    }
}

// MARK: - Result formatting

enum CalcFormat {
    // Output locale for every quick answer — display AND copy text (pasting
    // "0,3" should match the user's decimal comma). Input parsing stays
    // dot-decimal / comma-thousands (see the lexer): output-only locale is
    // the deliberate first slice, since "1,234" as input is ambiguous.
    // Tests pin this to en_US (and briefly de_DE) for determinism.
    static var locale: Locale = .autoupdatingCurrent

    static func display(_ v: Double, maxSignificant: Int = 10) -> String {
        format(v, grouping: true, maxSignificant: maxSignificant)
    }

    static func copyText(_ v: Double, maxSignificant: Int = 10) -> String {
        format(v, grouping: false, maxSignificant: maxSignificant)
    }

    private static func format(_ v: Double, grouping: Bool, maxSignificant: Int) -> String {
        if v == 0 { return "0" }   // never "-0"
        let f = NumberFormatter()
        f.locale = locale
        if abs(v) >= 1e15 || abs(v) < 1e-9 {
            f.numberStyle = .scientific
            f.exponentSymbol = "e"
        } else {
            f.numberStyle = .decimal
            f.usesGroupingSeparator = grouping
        }
        // Significant-digit capping also swallows float noise: 0.1+0.2 → "0.3".
        f.usesSignificantDigits = true
        f.maximumSignificantDigits = maxSignificant
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

// MARK: - Parser / evaluator

enum Calc {
    struct Result {
        let value: Double
        let sawOperation: Bool   // false for a bare literal/constant
    }

    // Evaluated value plus percent-ness: `10%` stays symbolic until it meets
    // an operator, because its meaning depends on it (100+10% → 110 but
    // 50*10% → 5 — the Raycast/soulver semantics people expect).
    private struct Value {
        var amount: Double
        var isPercent = false
        var resolved: Double { isPercent ? amount / 100 : amount }
    }

    private enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(Character)     // + - * / ^ (normalized)
        case percent
        case lparen, rparen
    }

    static let constants: [String: Double] = [
        "pi": Double.pi, "π": Double.pi, "tau": 2 * Double.pi, "e": M_E,
    ]

    static let functions: [String: (Double) -> Double] = [
        "sqrt": sqrt, "cbrt": cbrt, "abs": abs,
        "ln": log, "log": log10, "log10": log10, "log2": log2, "exp": exp,
        "sin": sin, "cos": cos, "tan": tan,
        "asin": asin, "acos": acos, "atan": atan,
        "floor": floor, "ceil": ceil, "round": { ($0).rounded() },
    ]

    static func evaluate(_ input: String) -> Result? {
        guard let tokens = tokenize(input) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let v = parser.parseExpression(minPrecedence: 0), parser.atEnd else { return nil }
        return Result(value: v.resolved, sawOperation: parser.sawOperation)
    }

    // MARK: Lexer

    private static func tokenize(_ input: String) -> [Token]? {
        let chars = Array(input.lowercased())
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }

            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var raw = ""
                while i < chars.count {
                    let d = chars[i]
                    if d.isNumber || d == "." {
                        raw.append(d); i += 1
                    } else if d == "," || d == "_" {
                        // thousands separator: only mid-number, "1,000"
                        guard i + 1 < chars.count, chars[i + 1].isNumber else { break }
                        i += 1
                    } else {
                        break
                    }
                }
                // scientific suffix: 2e5, 1.5e-3 (only when unambiguous)
                if i < chars.count, chars[i] == "e" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
                    if j < chars.count, chars[j].isNumber {
                        raw.append("e")
                        raw += String(chars[(i + 1)..<j])
                        i = j
                        while i < chars.count, chars[i].isNumber { raw.append(chars[i]); i += 1 }
                    }
                }
                guard let value = Double(raw) else { return nil }
                tokens.append(.number(value))
                continue
            }

            if c.isLetter || c == "π" {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i] == "π" {
                    name.append(chars[i]); i += 1
                }
                tokens.append(.ident(name))
                continue
            }

            switch c {
            case "+": tokens.append(.op("+"))
            case "-", "−", "–": tokens.append(.op("-"))
            case "×", "·": tokens.append(.op("*"))
            case "÷": tokens.append(.op("/"))
            case "/": tokens.append(.op("/"))
            case "^": tokens.append(.op("^"))
            case "%": tokens.append(.percent)
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" { tokens.append(.op("^")); i += 1 }
                else { tokens.append(.op("*")) }
            default: return nil   // anything else → not math, bail fast
            }
            i += 1
        }
        return tokens.isEmpty ? nil : tokens
    }

    // MARK: Pratt parser (evaluates as it goes — no AST needed)

    private struct Parser {
        let tokens: [Token]
        var pos = 0
        var sawOperation = false   // any binary op / % / function call

        var atEnd: Bool { pos >= tokens.count }
        func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

        // + - bind at 10; * / mod "of" (and implicit mult) at 20; unary minus
        // at 25 (tighter than *, looser than ^ → -2^2 = -4); ^ at 40,
        // right-associative.
        private func precedence(of token: Token) -> Int? {
            switch token {
            case .op("+"), .op("-"): return 10
            case .op("*"), .op("/"), .ident("mod"), .ident("of"), .ident("x"): return 20
            case .op("^"): return 40
            default: return nil
            }
        }

        mutating func parseExpression(minPrecedence: Int) -> Value? {
            guard var lhs = parsePrefix() else { return nil }

            while let token = peek() {
                if let prec = precedence(of: token), prec >= minPrecedence {
                    pos += 1
                    let nextMin = (token == .op("^")) ? prec : prec + 1
                    guard let rhs = parseExpression(minPrecedence: nextMin) else { return nil }
                    guard let combined = apply(token, lhs, rhs) else { return nil }
                    lhs = combined
                    sawOperation = true
                    continue
                }
                // Implicit multiplication — `2pi`, `2(3+4)` — but never between
                // two number literals ("3 4" is not math).
                if case .ident = token, 20 >= minPrecedence {
                    guard let rhs = parseExpression(minPrecedence: 21) else { return nil }
                    lhs = Value(amount: lhs.resolved * rhs.resolved)
                    sawOperation = true
                    continue
                }
                if case .lparen = token, 20 >= minPrecedence {
                    guard let rhs = parseExpression(minPrecedence: 21) else { return nil }
                    lhs = Value(amount: lhs.resolved * rhs.resolved)
                    sawOperation = true
                    continue
                }
                break
            }
            return lhs
        }

        private mutating func parsePrefix() -> Value? {
            guard let token = peek() else { return nil }
            if token == .op("-") {
                pos += 1
                guard var v = parseExpression(minPrecedence: 25) else { return nil }
                v.amount = -v.amount
                return v
            }
            if token == .op("+") {
                pos += 1
                return parseExpression(minPrecedence: 25)
            }
            return parsePostfix()
        }

        private mutating func parsePostfix() -> Value? {
            guard var v = parsePrimary() else { return nil }
            while peek() == .percent {
                pos += 1
                guard !v.isPercent else { return nil }
                v.isPercent = true
                sawOperation = true
            }
            return v
        }

        private mutating func parsePrimary() -> Value? {
            guard let token = peek() else { return nil }
            switch token {
            case .number(let n):
                pos += 1
                return Value(amount: n)
            case .ident(let name):
                if let c = Calc.constants[name] {
                    pos += 1
                    return Value(amount: c)
                }
                if let fn = Calc.functions[name] {
                    pos += 1
                    guard peek() == .lparen else { return nil }
                    pos += 1
                    guard let arg = parseExpression(minPrecedence: 0) else { return nil }
                    guard peek() == .rparen else { return nil }
                    pos += 1
                    sawOperation = true
                    return Value(amount: fn(arg.resolved))
                }
                return nil   // unknown word → not math ("safari", "2fa")
            case .lparen:
                pos += 1
                guard let inner = parseExpression(minPrecedence: 0) else { return nil }
                guard peek() == .rparen else { return nil }
                pos += 1
                return inner
            default:
                return nil
            }
        }

        private func apply(_ token: Token, _ lhs: Value, _ rhs: Value) -> Value? {
            switch token {
            case .op("+"), .op("-"):
                let sign: Double = (token == .op("+")) ? 1 : -1
                // `100 + 10%` reads as "plus ten percent OF the left side".
                if rhs.isPercent && !lhs.isPercent {
                    return Value(amount: lhs.amount * (1 + sign * rhs.amount / 100))
                }
                return Value(amount: lhs.resolved + sign * rhs.resolved)
            case .op("*"), .ident("of"), .ident("x"):
                return Value(amount: lhs.resolved * rhs.resolved)
            case .op("/"):
                return Value(amount: lhs.resolved / rhs.resolved)
            case .op("^"):
                return Value(amount: pow(lhs.resolved, rhs.resolved))
            case .ident("mod"):
                return Value(amount: fmod(lhs.resolved, rhs.resolved))
            default:
                return nil
            }
        }
    }
}
