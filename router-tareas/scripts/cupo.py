#!/usr/bin/env python3
"""Reparto de uso por modelo de Claude en los últimos N días, leído de los registros de sesión de Claude Code
(~/.claude/projects/**/*.jsonl). Todo es local: no sube nada a ningún sitio.

Salida (JSON en una línea): llamadas y tokens de salida por modelo, % de la salida en modelos Opus y
tamaño medio del contexto por llamada. Solo cuenta modelos cuyo nombre empieza por «claude» (los registros
de sesiones de otros motores, como GLM, se ignoran). Cualquier línea rara se salta en vez de romper todo.
Uso: cupo.py [dias]   (por defecto 7)."""
import calendar, glob, json, os, sys, time

dias = int(sys.argv[1]) if len(sys.argv) > 1 else 7
corte = time.time() - dias * 86400
vistos, por_modelo, ctx_total, llamadas = set(), {}, 0, 0

def entero(x):
    return x if isinstance(x, int) and not isinstance(x, bool) else 0

for f in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    try:
        if os.path.getmtime(f) < corte:
            continue
        fh = open(f, errors="ignore")
    except OSError:
        continue
    with fh:
        for linea in fh:
            if '"usage"' not in linea:
                continue
            try:
                d = json.loads(linea)
                m = d.get("message") or {}
                u = m.get("usage")
                modelo = m.get("model")
                if not isinstance(u, dict) or not isinstance(modelo, str) or not modelo.startswith("claude"):
                    continue
                ts = d.get("timestamp")
                if isinstance(ts, str) and calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) < corte:
                    continue          # los sellos de tiempo de Claude Code van en UTC
                k = m.get("id") or d.get("uuid")
                if k in vistos:       # Claude Code repite el mismo mensaje en varias líneas
                    continue
                vistos.add(k)
                r = por_modelo.setdefault(modelo, {"llamadas": 0, "salida": 0})
                r["llamadas"] += 1
                r["salida"] += entero(u.get("output_tokens"))
                ctx_total += sum(entero(u.get(c)) for c in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                llamadas += 1
            except Exception:
                continue

tot = sum(r["salida"] for r in por_modelo.values()) or 1
opus = sum(r["salida"] for k, r in por_modelo.items() if "opus" in k)
print(json.dumps({
    "dias": dias,
    "por_modelo": por_modelo,
    "pct_salida_opus": round(100 * opus / tot, 1),
    "llamadas": llamadas,
    "contexto_medio_por_llamada": round(ctx_total / llamadas) if llamadas else 0,
}))
