.pragma library
function calculate(input) {
    const tokens = input.match(/(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?|[a-z]+|[()+*/%^,-]/gi) || [];
    if (tokens.join("").toLowerCase() !== input.replace(/\s/g, "").toLowerCase()) throw Error("Unsupported expression");
    let i = 0;
    const funcs = {sqrt: Math.sqrt, abs: Math.abs, sin: Math.sin, cos: Math.cos, tan: Math.tan, log: Math.log10, ln: Math.log, round: Math.round, floor: Math.floor, ceil: Math.ceil};
    function atom() {
        const t = tokens[i++];
        if (t === "+") return atom();
        if (t === "-") return -expression(2);
        if (t === "(") { const v = expression(0); if (tokens[i++] !== ")") throw Error("Missing )"); return v; }
        if (t === "pi") return Math.PI;
        if (t === "e") return Math.E;
        if (funcs[t]) { if (tokens[i++] !== "(") throw Error("Expected ("); const v = expression(0); if (tokens[i++] !== ")") throw Error("Missing )"); return funcs[t](v); }
        if (t === undefined || !/^[0-9.]/.test(t)) throw Error("Expected number");
        return Number(t);
    }
    const prec = {"+": 1, "-": 1, "*": 2, "/": 2, "%": 2, "^": 3};
    function expression(min) {
        let v = atom();
        while ((prec[tokens[i]] || 0) > min) {
            const op = tokens[i++], p = prec[op], r = expression(op === "^" ? p - 1 : p);
            v = op === "+" ? v + r : op === "-" ? v - r : op === "*" ? v * r : op === "/" ? v / r : op === "%" ? v % r : Math.pow(v, r);
        }
        return v;
    }
    const value = expression(0);
    if (i !== tokens.length || !Number.isFinite(value)) throw Error("Invalid expression");
    return String(Number(value.toPrecision(12)));
}
