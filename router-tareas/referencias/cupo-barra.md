# Apuntar el cupo semanal solo

`router.sh cupo` necesita el % de uso semanal de tu plan de Claude. Tienes dos formas.

## A) A mano

Mira `/usage` en Claude Code y teclea: `router.sh cupo 81`. Vale, pero te acordarás poco.

## B) Automática, con la barra de estado de Claude Code

Claude Code pasa a tu script de barra de estado (`statusLine` en `~/.claude/settings.json`) un JSON por
la entrada estándar. En planes con límite semanal incluye `rate_limits.five_hour.used_percentage` y
`rate_limits.seven_day.used_percentage`. Añade esto **al principio** de tu script de barra de estado
(necesita `jq`), tras leer la entrada en la variable `input`:

```bash
input=$(cat)
printf '%s' "$input" | jq -c '{fecha: (now|todate), cinco_h: .rate_limits.five_hour.used_percentage, siete_d: .rate_limits.seven_day.used_percentage, reset_7d: .rate_limits.seven_day.resets_at} | select(.siete_d != null)' \
  > "$HOME/.claude/cupo-actual.json.tmp" 2>/dev/null && mv "$HOME/.claude/cupo-actual.json.tmp" "$HOME/.claude/cupo-actual.json" 2>/dev/null
rm -f "$HOME/.claude/cupo-actual.json.tmp" 2>/dev/null
```

Escribe el fichero de forma atómica y falla en silencio: no rompe tu barra. Con eso,
`router.sh cupo` (sin número) lee `~/.claude/cupo-actual.json`. Si el fichero tiene más de 26 horas
(no has abierto Claude Code), se niega a apuntar un dato viejo. Otra ruta: `ROUTER_CUPO_FILE`.

Si aún no tienes barra de estado, pídele a Claude Code: «configura mi barra de estado» y añade lo anterior.

## Un apunte diario

Con `cron` (Linux/macOS), cada día a las 21:00:

```
0 21 * * * ROUTER_HOME=$HOME/.router-tareas /bin/bash /ruta/a/router-tareas/scripts/router.sh cupo >> $HOME/.router-tareas/cupo.log 2>&1
```

En macOS también vale un agente de `launchd` con `StartCalendarInterval` (Hour 21, Minute 0). Tras unas
semanas, `router.sh informe` muestra el % real junto al reparto de uso por modelo.

## Qué mide `cupo.py`

Lee los registros de sesión de `~/.claude/projects/**/*.jsonl` de los últimos 7 días, sin duplicar
mensajes, y devuelve por modelo el número de llamadas y los tokens de salida, el % de salida en modelos
Opus y el tamaño medio del contexto por llamada. **No sube nada a ningún sitio**; todo es local.
