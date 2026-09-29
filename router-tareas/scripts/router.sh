#!/bin/bash
# router.sh — reparte una tarea ya definida a otro motor (Codex o GLM) en una copia de trabajo
# del repo (git worktree), lleva la cuenta de cómo sale cada motor y mide tu cupo semanal de Claude.
#
# Quién decide QUÉ se reparte: Claude, con las reglas de SKILL.md. Este script solo
# ejecuta, separa y apunta. Claude revisa SIEMPRE el resultado antes de aceptarlo.
#
# «Motor» = un modelo externo a Claude que este script sabe lanzar (Codex, GLM).
# «Worktree» = copia de trabajo de git en otra carpeta y otra rama; el motor edita ahí, no en tu repo.
#
# ── Reparto ────────────────────────────────────────────────────────────────────────────────
#   router.sh init [codex,glm|codex|glm|ninguno]   crea ~/.router-tareas; activa solo los motores que tengas
#   router.sh estado                               motores, cómo van y si el router está apagado
#   router.sh validar <tarea.md>                   comprueba el formato de tarea atómica
#   router.sh regla <tipo> [sensible]              motor que recomienda la tabla de reglas
#   router.sh lanzar <motor> <repo> <id> <tarea.md> [minutos-tope]
#   router.sh veredicto <id> ok|mal|nulo "<motivo>"   ok/mal puntúan; nulo = el motor no llegó a trabajar
#   router.sh limpiar [--forzar] <id>              --forzar: limpia aunque no haya veredicto
#   router.sh resumen [horas]                      tabla final: qué se mandó a cada motor y cómo salió la revisión
# ── Segunda opinión (Codex, sin permiso de escritura en el repo) ───────────────────────────
#   router.sh revisar <repo> [base|--sin-commit]       revisión de código con el revisor nativo de Codex
#   router.sh adversarial <repo> [base|--sin-commit]   Codex busca motivos para NO aceptar el cambio
# ── Control ────────────────────────────────────────────────────────────────────────────────
#   router.sh apagar | encender                    interruptor general: apagado, Claude lo hace todo
#   router.sh activar <motor> | desactivar <motor> "<motivo>"
# ── Cupo (límite semanal de tu plan de Claude; opcional) ───────────────────────────────────
#   router.sh cupo [pct-semanal]                   apunta el % de uso semanal + reparto por modelo
#   router.sh informe                              tabla de la serie de cupo
#
# Variables de entorno (todas opcionales):
#   ROUTER_HOME          dónde vive el estado (por defecto ~/.router-tareas)
#   ROUTER_STRIKES       «mal» que sacan a un motor (por defecto 3)
#   ROUTER_VENTANA_DIAS  ventana en la que se cuentan (por defecto 30)
#   ROUTER_NO_GLM        trozos de ruta separados por «:» donde GLM NUNCA trabaja
#                        (p. ej. "/clientes/:/produccion/"): sus datos salen a un tercero
#   ROUTER_CUPO_FILE     JSON con el % de uso (por defecto ~/.claude/cupo-actual.json; ver referencias/cupo-barra.md)
#   ZAI_API_KEY          clave de z.ai para GLM, o bien:
#   ROUTER_GLM_KEY_CMD   comando (lo escribes tú, se ejecuta con `eval`) que imprime la clave, p. ej. la
#                        orden de tu gestor de contraseñas; la clave solo se pasa al proceso hijo, nunca se imprime
#   ROUTER_GLM_WRAP      alternativa más segura a las dos anteriores: una orden-prefijo que lanza el proceso de GLM
#                        con la clave inyectada como ANTHROPIC_AUTH_TOKEN (p. ej. `mi-gestor run clave --as ANTHROPIC_AUTH_TOKEN --`).
#                        Así la clave no pasa ni por este script. Se separa por espacios (sin comillas dentro).
#   ROUTER_GLM_MODEL     modelo de GLM (por defecto glm-5.3)
#   ROUTER_GLM_URL       endpoint compatible con Anthropic (por defecto el de z.ai)

set -uo pipefail

# Carpeta de la skill (para las plantillas) y carpeta del estado del usuario.
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_R="${ROUTER_HOME:-$HOME/.router-tareas}"
MODELOS="$HOME_R/modelos.json"      # motores externos (antes motores.json; se migra solo)
REGLAS="$HOME_R/reglas.json"        # tabla tipo de tarea → motores recomendados
REGISTRO="$HOME_R/registro.jsonl"   # un JSON por línea: veredictos, activaciones y datos de cupo
TRABAJOS="$HOME_R/trabajos"
STRIKES="${ROUTER_STRIKES:-3}"
VENTANA_DIAS="${ROUTER_VENTANA_DIAS:-30}"
GLM_MODEL="${ROUTER_GLM_MODEL:-glm-5.3}"
GLM_URL="${ROUTER_GLM_URL:-https://api.z.ai/api/anthropic}"
CUPO_FILE="${ROUTER_CUPO_FILE:-$HOME/.claude/cupo-actual.json}"

die() { echo "router: $*" >&2; exit 1; }
py() { python3 - "$@"; }

# Ejecuta una orden con tope de tiempo (macOS no trae `timeout`). Si se pasa, mata TAMBIÉN a los procesos
# hijos (tests colgados) y sale con 142.
con_tope() {
  perl -e '$s = shift; $p = fork();
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$p; sleep 2; kill "KILL", -$p; exit 142 };
    alarm $s; waitpid($p, 0); exit($? >> 8)' "$@"
}

# Un id de tarea es una sola palabra segura: nada de rutas, ni «.» ni «..».
validar_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *..* ]] \
    || die "id de tarea inválido «${1}» (letras, números, . _ - ; sin barras, sin '..', sin empezar por punto)"
}

# Tabla de reglas por defecto: para cada tipo de tarea, motores en orden de preferencia. Se edita en
# ~/.router-tareas/reglas.json, no aquí.
crear_reglas() {
  [ -f "$REGLAS" ] && return 0
  cat > "$REGLAS" <<'EOF'
{
  "comentario": "Tabla de decision rapida (sin modelo, sin coste): tipo de tarea -> motores en orden de preferencia; se usa el primero que este activo. 'claude' = no se reparte. Reglas duras del script (no se saltan): sensible=si -> nada sale; tipo dificil -> nada sale; GLM nunca en las rutas de ROUTER_NO_GLM.",
  "por_tipo": {
    "mecanica": ["glm", "codex"],
    "acotada": ["codex"],
    "multi-fichero": ["codex"],
    "dificil": ["claude"]
  }
}
EOF
}

# Migra instalaciones de la versión 1 (motores.json → modelos.json).
migrar_v1() {
  if [ ! -f "$MODELOS" ] && [ -f "$HOME_R/motores.json" ]; then
    py "$HOME_R/motores.json" "$MODELOS" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["modelos"] = d.pop("motores")
for m in d["modelos"].values(): m.setdefault("strikes", True)
json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
EOF
    mv "$HOME_R/motores.json" "$HOME_R/motores.json.migrado"
    echo "router: configuración de la versión 1 migrada a modelos.json (copia en motores.json.migrado)."
  fi
}

necesita_init() {
  migrar_v1
  [ -f "$MODELOS" ] || die "sin configurar: ejecuta 'router.sh init'"
  crear_reglas
}

# ¿Está activo el motor? Con el interruptor APAGADO, ninguno lo está.
activo() {
  [ -f "$HOME_R/APAGADO" ] && { echo no; return; }
  py "$MODELOS" "$1" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))["modelos"].get(sys.argv[2])
print("si" if m and m.get("activo") else "no")
EOF
}

# De una lista «glm,codex», el primer motor activo; «claude» si no hay ninguno o la lista dice claude.
elegir_motor() {
  local m
  for m in ${1//,/ }; do
    [ "$m" = claude ] && { echo claude; return; }
    [ "$(activo "$m")" = si ] && { echo "$m"; return; }
  done
  echo claude
}

# La regla de las 3 solo aplica a los motores con "strikes": true (por defecto sí).
con_strikes() {
  py "$MODELOS" "$1" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))["modelos"].get(sys.argv[2], {})
print("si" if m.get("strikes", True) else "no")
EOF
}

# Extrae un apartado (objetivo | ficheros) de la tarea guardada, en una línea, para el registro y el resumen.
campo_tarea() { # fichero apartado
  py "$1" "$2" <<'EOF'
import re, sys
txt = open(sys.argv[1]).read()
m = re.search(r"^## " + sys.argv[2] + r"\s*\n(.*?)(?=^## |\Z)", txt, re.S | re.M | re.I)
t = re.sub(r"<!--.*?-->", "", m.group(1), flags=re.S) if m else ""
print(" ".join(l.strip().lstrip("- ").strip() for l in t.splitlines() if l.strip())[:300])
EOF
}

registrar() { # id motor resultado motivo [objetivo] [ficheros] [segundos]
  py "$REGISTRO" "$@" <<'EOF'
import json, sys, datetime
f, id_, motor, res, motivo = sys.argv[1:6]
objetivo, ficheros, segundos = (sys.argv[6:9] + ["", "", ""])[:3]
reg = {"fecha": datetime.datetime.now().isoformat(timespec="microseconds"),
       "id": id_, "motor": motor, "resultado": res, "motivo": motivo,
       "objetivo": objetivo, "ficheros": ficheros, "segundos": int(segundos) if segundos.isdigit() else None}
with open(f, "a") as fh:
    fh.write(json.dumps(reg, ensure_ascii=False) + "\n")
EOF
}

# Anota que un motor se reactivó: la regla de las 3 cuenta solo desde ahí.
registrar_activacion() {
  py "$REGISTRO" "$1" <<'EOF'
import json, sys, datetime
with open(sys.argv[1], "a") as fh:
    fh.write(json.dumps({"tipo": "activado", "motor": sys.argv[2],
                         "fecha": datetime.datetime.now().isoformat(timespec="microseconds")}) + "\n")
EOF
}

cambiar_activo() { # motor true|false motivo
  py "$MODELOS" "$@" <<'EOF'
import json, sys, datetime
f, motor, valor, motivo = sys.argv[1], sys.argv[2], sys.argv[3] == "true", sys.argv[4]
d = json.load(open(f))
if motor not in d["modelos"]: sys.exit(f"motor desconocido: {motor}")
d["modelos"][motor]["activo"] = valor
if valor: d["desactivados"].pop(motor, None)
else: d["desactivados"][motor] = {"fecha": datetime.date.today().isoformat(), "motivo": motivo}
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
EOF
}

# Clave de GLM: variable de entorno o comando del usuario. Nunca se imprime.
clave_glm() {
  if [ -n "${ZAI_API_KEY:-}" ]; then printf '%s' "$ZAI_API_KEY"
  elif [ -n "${ROUTER_GLM_KEY_CMD:-}" ]; then eval "$ROUTER_GLM_KEY_CMD"
  else return 1; fi
}

# Valida el formato de tarea atómica. Si es válida imprime «sensible|tipo|motores-recomendados»;
# si no, sale con la lista de fallos. Es lo que hace que "sin criterios completos no se reparte".
validar_tarea() {
  py "$1" "$REGLAS" <<'EOF'
import json, re, sys
txt = open(sys.argv[1]).read()
tipos = json.load(open(sys.argv[2]))["por_tipo"]
sec = {}
for m in re.finditer(r"^## (.+?)\s*\n(.*?)(?=^## |\Z)", txt, re.S | re.M):
    sec[m.group(1).strip().lower()] = re.sub(r"<!--.*?-->", "", m.group(2), flags=re.S).strip()
err = []
for k in ["objetivo", "ficheros", "criterios de aceptación", "sensible", "tipo", "tope"]:
    if not sec.get(k) or sec[k].startswith("<"): err.append(f"falta o está sin rellenar: ## {k}")
lineas = lambda k: [l.strip() for l in sec.get(k, "").splitlines() if l.strip().startswith("-")]
sin_relleno = lambda l: bool(re.match(r"^-\s*(\(l[ií]mite\)\s*)?<", l))   # «- <criterio…>» = plantilla sin rellenar
fich = [l for l in lineas("ficheros") if not sin_relleno(l)]
if not 1 <= len(fich) <= 3: err.append(f"## Ficheros: entre 1 y 3 (hay {len(fich)}); si son más, se divide en tareas")
crit = [l for l in lineas("criterios de aceptación") if not sin_relleno(l)]
if len(crit) < 2: err.append("## Criterios de aceptación: mínimo 2 (sin dejar líneas de la plantilla sin rellenar)")
if not any(re.search(r"límite|limite", c, re.I) for c in crit): err.append("## Criterios de aceptación: falta un caso límite (una línea con «(límite)»)")
sens = (sec.get("sensible", "").split() or [""])[0].lower().replace("í", "i").strip(".,;:")
if sens not in ("si", "no"): err.append("## Sensible: debe empezar por sí o no")
tipo = (sec.get("tipo", "").split() or [""])[0].lower().strip(".,;:")
if tipo not in tipos: err.append(f"## Tipo: uno de {', '.join(tipos)}")
if err: sys.exit("tarea no válida:\n  - " + "\n  - ".join(err))
v = tipos[tipo]; v = [v] if isinstance(v, str) else v
print(f"{sens}|{tipo}|{','.join(v)}")
EOF
}

cmd="${1:-estado}"; shift || true
case "$cmd" in

init)
  # Motores con suscripción, separados por comas: "codex", "glm", "codex,glm" o "ninguno".
  # Los que no estén en la lista quedan creados pero FUERA, para activarlos el día que se tengan.
  CON="${1:-codex,glm}"
  for x in ${CON//,/ }; do case "$x" in codex|glm|ninguno) ;; *) die "init: «${x}» no vale (usa codex, glm, codex,glm o ninguno)" ;; esac; done
  mkdir -p "$TRABAJOS"
  migrar_v1
  if [ -f "$MODELOS" ]; then echo "router: ya configurado en $HOME_R (router.sh activar/desactivar para cambiarlo)"; exit 0; fi
  cat > "$MODELOS" <<'EOF'
{
  "comentario": "Motores EXTERNOS que router.sh lanza. Los modelos de Claude no van aqui: se eligen al abrir la sesion (referencias/politica-modelos.md). activo=false saca el motor del reparto. strikes=true: N veredictos 'mal' en la ventana lo desactivan solo. Reactivar a mano: router.sh activar <motor>. Un motor nuevo = una entrada aqui + su rama en 'lanzar'.",
  "modelos": {
    "codex": {
      "activo": true,
      "strikes": true,
      "para": "implementacion acotada con tests; segunda opinion adversarial",
      "como_se_invoca": "codex exec -s workspace-write --ephemeral (worktree)"
    },
    "glm": {
      "activo": true,
      "strikes": true,
      "para": "trabajo mecanico en volumen: renombrados, codigo repetitivo, migrar formatos, tests simples, documentar codigo",
      "como_se_invoca": "claude -p contra un endpoint compatible con Anthropic (z.ai), con HOME desechable"
    }
  },
  "desactivados": {}
}
EOF
  crear_reglas
  for m in codex glm; do
    case ",$CON," in *",$m,"*) ;; *) cambiar_activo "$m" false "sin suscripción al configurar" ;; esac
  done
  echo "router: configurado en $HOME_R"
  "$0" estado
  ;;

estado)
  necesita_init
  [ -f "$HOME_R/APAGADO" ] && echo "*** ROUTER APAGADO: no reparte nada, Claude lo hace todo. Para volver: router.sh encender ***"
  py "$MODELOS" "$REGISTRO" "$VENTANA_DIAS" <<'EOF'
import json, sys, datetime, os
d = json.load(open(sys.argv[1])); dias = int(sys.argv[3])
regs = [json.loads(l) for l in open(sys.argv[2]) if l.strip()] if os.path.exists(sys.argv[2]) else []
desde = datetime.datetime.now() - datetime.timedelta(days=dias)
for n, m in d["modelos"].items():
    r = [x for x in regs if x.get("motor") == n and x.get("resultado") in ("ok", "mal")
         and datetime.datetime.fromisoformat(x["fecha"]) >= desde]
    ok = sum(x["resultado"] == "ok" for x in r); mal = sum(x["resultado"] == "mal" for x in r)
    est = "ACTIVO" if m["activo"] else f"FUERA ({d['desactivados'].get(n, {}).get('motivo', '')})"
    print(f"{n:6} {est:40} últimos {dias} días: {ok} bien · {mal} mal · para: {m['para']}")
if not any(m["activo"] for m in d["modelos"].values()):
    print("\nNingún motor activo: todas las tareas las hace Claude (el router no reparte nada).")
EOF
  ;;

validar)
  necesita_init
  [ $# -ge 1 ] || die "uso: validar <fichero-tarea.md>"
  V=$(validar_tarea "$1" 2>&1) || die "$V"
  IFS='|' read -r T_SENS T_TIPO T_LISTA <<< "$V"
  echo "router: tarea válida · sensible=$T_SENS · tipo=$T_TIPO · recomendado: $(elegir_motor "$T_LISTA")"
  ;;

regla)
  necesita_init
  [ $# -ge 1 ] || die "uso: regla <mecanica|acotada|multi-fichero|dificil> [sensible]"
  [ "${2:-}" = sensible ] && { echo claude; exit 0; }
  LISTA=$(py "$REGLAS" "$1" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1]))["por_tipo"].get(sys.argv[2], ["claude"])
print(",".join([v] if isinstance(v, str) else v))
EOF
)
  elegir_motor "$LISTA"
  ;;

lanzar)
  necesita_init
  [ $# -ge 4 ] || die "uso: lanzar <motor> <repo> <id-tarea> <fichero-tarea> [minutos-tope]"
  MOTOR="$1"; ID="$3"; PROMPT_F="$4"; MIN="${5:-30}"
  validar_id "$ID"
  [[ "$MIN" =~ ^[0-9]+$ ]] && [ "$MIN" -ge 1 ] || die "el tope son minutos enteros (p. ej. 30), no «${MIN}»"
  REPO="$(cd "$2" 2>/dev/null && pwd -P)" || die "no existe la carpeta $2"
  [ "$(activo "$MOTOR")" = "si" ] || die "el motor '$MOTOR' no está activo (router.sh estado)"
  [ -f "$PROMPT_F" ] || die "no existe el fichero de tarea $PROMPT_F"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO no es un repo git"
  # Reglas duras: se comprueban ANTES de crear nada.
  V=$(validar_tarea "$PROMPT_F" 2>&1) || die "$V"
  IFS='|' read -r T_SENS T_TIPO T_LISTA <<< "$V"
  [ "$T_SENS" = si ] && die "tarea marcada sensible: no sale de Claude"
  [ "$T_LISTA" = claude ] && die "tipo '$T_TIPO': lo hace Claude, no se reparte"
  T_REC=$(elegir_motor "$T_LISTA")
  if [ "$MOTOR" = glm ] && [ -n "${ROUTER_NO_GLM:-}" ]; then
    IFS=':' read -ra PROT <<< "$ROUTER_NO_GLM"
    for p in "${PROT[@]}"; do
      [ -n "$p" ] && case "$REPO/" in *"$p"*) die "regla dura: GLM no trabaja en rutas que contienen '$p' (ROUTER_NO_GLM)" ;; esac
    done
  fi
  [ "$MOTOR" != "$T_REC" ] && echo "router: aviso: la tabla de reglas recomienda '$T_REC' para el tipo '$T_TIPO'; se usa '$MOTOR' por decisión de Claude (anotar por qué)."
  # Todo lo que puede fallar por falta de algo se comprueba ANTES de crear la copia de trabajo.
  case "$MOTOR" in
    codex) command -v codex >/dev/null || die "Codex CLI no instalado (npm i -g @openai/codex && codex login)" ;;
    glm)   command -v claude >/dev/null || die "Claude Code no instalado"
           # La clave se obtiene UNA sola vez y se comprueba que no esté vacía: si fuera vacía, `claude` usaría
           # tus credenciales normales contra el endpoint de un tercero.
           if [ -n "${ROUTER_GLM_WRAP:-}" ]; then read -ra GLM_WRAP <<< "$ROUTER_GLM_WRAP"; GLM_KEY=""
           else GLM_WRAP=(); GLM_KEY="$(clave_glm 2>/dev/null)" && [ -n "$GLM_KEY" ] || die "falta la clave de GLM (o el comando que la da falló): ZAI_API_KEY, ROUTER_GLM_KEY_CMD o ROUTER_GLM_WRAP"; fi ;;
    *)     die "motor sin lanzador en este script: $MOTOR (añádelo en el case de 'lanzar')" ;;
  esac
  T="$TRABAJOS/$ID"; WT="$T/wt"
  [ -e "$T" ] && die "ya existe la tarea $ID (router.sh limpiar --forzar $ID)"
  git -C "$REPO" rev-parse --verify -q "refs/heads/router/$ID" >/dev/null && die "ya existe la rama router/$ID en $REPO: bórrala (git branch -D router/$ID) o usa otro id"
  mkdir -p "$T"
  git -C "$REPO" worktree add -q "$WT" -b "router/$ID" HEAD || { rm -rf "$T"; die "no se pudo crear la copia de trabajo"; }
  # Nada de secretos en lo que ve el otro motor: si hay ficheros sensibles TRACKEADOS, no se lanza.
  SENS=$(git -C "$WT" ls-files | grep -Ei '(^|/)(\.env(\.[^/]*)?|[^/]*\.pem|[^/]*\.key|id_rsa[^/]*|id_ed25519[^/]*|credentials(\.[^/]*)?|secrets?\.(json|ya?ml|env|toml)|[^/]*\.secret)$' | grep -viE '\.(example|sample|dist|template)$' | head -5)
  if [ -n "$SENS" ]; then
    git -C "$REPO" worktree remove --force "$WT"; git -C "$REPO" branch -D "router/$ID" -q; rm -rf "$T"
    die "el repo tiene ficheros sensibles trackeados, no se reparte: $SENS"
  fi
  cp "$PROMPT_F" "$T/prompt.md"; echo "$MOTOR" > "$T/motor"; echo "$REPO" > "$T/repo"
  SEG=$((MIN * 60)); INICIO=$(date +%s)
  echo "router: $ID → $MOTOR en $WT (tope $MIN min)…"
  case "$MOTOR" in
    codex)
      # < /dev/null: si no, Codex se queda esperando entrada por stdin cuando corre en segundo plano.
      con_tope "$SEG" codex exec -C "$WT" -s workspace-write --ephemeral \
        -o "$T/resultado.md" "$(cat "$T/prompt.md")" < /dev/null > "$T/log.txt" 2>&1
      RC=$? ;;
    glm)
      # GLM = Claude Code apuntando al endpoint de z.ai. Con un HOME desechable no ve tu memoria global
      # (~/.claude/CLAUDE.md), tus servidores MCP ni tus hooks: nada de eso viaja a z.ai. La clave solo vive
      # en el entorno de este proceso hijo. Las herramientas permitidas se limitan a leer/editar y a los
      # ejecutores de tests habituales (no `python3`, `node` ni `npx` a secas, que ejecutan cualquier cosa).
      mkdir -p "$T/home"
      ( cd "$WT" && unset ANTHROPIC_API_KEY
        [ -n "$GLM_KEY" ] && export ANTHROPIC_AUTH_TOKEN="$GLM_KEY"
        # Con ROUTER_GLM_WRAP, el prefijo (p. ej. tu gestor de contraseñas) corre con tu HOME real y `env`
        # pasa a un HOME desechable justo antes de `claude`.
        con_tope "$SEG" ${GLM_WRAP[@]+"${GLM_WRAP[@]}"} env HOME="$T/home" ANTHROPIC_BASE_URL="$GLM_URL" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="$GLM_MODEL" ANTHROPIC_DEFAULT_SONNET_MODEL="$GLM_MODEL" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$GLM_MODEL" \
        claude -p "$(cat "$T/prompt.md")" --permission-mode acceptEdits \
          --strict-mcp-config --setting-sources project \
          --allowedTools "Read,Edit,Write,Glob,Grep,Bash(python3 -m pytest:*),Bash(pytest:*),Bash(npm test:*),Bash(npm run test:*),Bash(phpunit:*),Bash(php -l:*),Bash(git diff:*),Bash(git status:*)" \
          < /dev/null > "$T/resultado.md" 2> "$T/log.txt" )
      RC=$? ;;
  esac
  echo $(( $(date +%s) - INICIO )) > "$T/segundos"
  echo "router: $MOTOR terminó (rc=$RC, $(cat "$T/segundos") s). Cambios:"
  # Lo que genera la ejecución (cachés, dependencias) no es un cambio del motor.
  git -C "$WT" add -A -- . ':(exclude,glob)**/__pycache__/**' ':(exclude,glob)**/.pytest_cache/**' \
    ':(exclude,glob)**/node_modules/**' ':(exclude,glob)**/*.pyc' >/dev/null 2>&1
  git -C "$WT" diff --cached --stat HEAD | tail -15
  if [ "$RC" -ne 0 ]; then
    if [ "$RC" -eq 142 ]; then
      echo "router: *** $MOTOR NO TERMINÓ: se alcanzó el tope de $MIN min y se le cortó. Lo hecho hasta ahí está en la copia de trabajo; revisa si sirve o da veredicto «nulo». ***"
    elif grep -qiE 'usage limit|rate limit|quota' "$T/log.txt" 2>/dev/null; then
      echo "router: *** $MOTOR NO HA TRABAJADO: límite de uso de su suscripción alcanzado (ver $T/log.txt). No es un fallo del motor: pasa la tarea a otro o hazla tú, y cierra esta con: router.sh veredicto $ID nulo \"límite de uso\" ***"
    else
      echo "router: *** $MOTOR terminó con error (rc=$RC): mira $T/log.txt antes de dar veredicto. ***"
    fi
  fi
  echo "router: AHORA Claude revisa el diff, pasa los tests él mismo y da veredicto:"
  echo "        router.sh veredicto $ID ok|mal|nulo \"motivo\""
  ;;

veredicto)
  necesita_init
  [ $# -ge 2 ] || die "uso: veredicto <id-tarea> ok|mal|nulo \"motivo\""
  ID="$1"; RES="$2"; MOT="${3:-}"; validar_id "$ID"; T="$TRABAJOS/$ID"
  [ -d "$T" ] && [ -f "$T/motor" ] || die "no existe la tarea $ID"
  [ -f "$T/veredicto" ] && die "la tarea $ID ya tiene veredicto ($(cat "$T/veredicto")): no se repite"
  [[ "$RES" == ok || "$RES" == mal || "$RES" == nulo ]] || die "veredicto: ok, mal o nulo (nulo = el motor no llegó a trabajar; no cuenta)"
  [ "$RES" != ok ] && [ -z "$MOT" ] && die "un '$RES' necesita motivo"
  MOTOR="$(cat "$T/motor")"
  registrar "$ID" "$MOTOR" "$RES" "$MOT" "$(campo_tarea "$T/prompt.md" objetivo 2>/dev/null)" "$(campo_tarea "$T/prompt.md" ficheros 2>/dev/null)" "$(cat "$T/segundos" 2>/dev/null)"
  echo "$RES" > "$T/veredicto"
  # Con «ok», los cambios (hasta ahora solo preparados en la copia de trabajo) se guardan como commit en la rama
  # router/<id>: así `git merge router/<id>` fusiona de verdad. Con «mal» o «nulo» no se guarda nada.
  if [ "$RES" = ok ] && [ -d "$T/wt" ] && ! git -C "$T/wt" diff --cached --quiet HEAD 2>/dev/null; then
    git -C "$T/wt" -c user.name="router-tareas" -c user.email="router@localhost" commit -q -m "router: $ID ($MOTOR)" \
      && echo "router: cambios de $ID guardados en la rama router/$ID (listos para: git merge router/$ID)."
  fi
  if [ "$RES" = mal ]; then
    # Cuenta los «mal» de la ventana, pero solo desde la última vez que se reactivó el motor.
    N=$(py "$REGISTRO" "$MOTOR" "$VENTANA_DIAS" <<'EOF'
import json, sys, datetime
regs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
motor = sys.argv[2]
desde = datetime.datetime.now() - datetime.timedelta(days=int(sys.argv[3]))
for x in regs:
    if x.get("tipo") == "activado" and x.get("motor") == motor:
        desde = max(desde, datetime.datetime.fromisoformat(x["fecha"]))
print(sum(1 for x in regs if x.get("motor") == motor and x.get("resultado") == "mal"
          and datetime.datetime.fromisoformat(x["fecha"]) >= desde))
EOF
)
    echo "router: $MOTOR lleva $N «mal» en la ventana de $VENTANA_DIAS días."
    if [ "$N" -ge "$STRIKES" ] && [ "$(con_strikes "$MOTOR")" = si ]; then
      cambiar_activo "$MOTOR" false "$N veredictos «mal» en $VENTANA_DIAS días (último: $MOT)"
      echo "router: *** $MOTOR DESACTIVADO (regla de las $STRIKES). Se reactiva a mano: router.sh activar $MOTOR ***"
    fi
  fi
  ;;

limpiar)
  necesita_init
  FORZAR=0; [ "${1:-}" = --forzar ] && { FORZAR=1; shift; }
  [ $# -ge 1 ] || die "uso: limpiar [--forzar] <id-tarea>"
  ID="$1"; validar_id "$ID"; T="$TRABAJOS/$ID"; [ -d "$T" ] || die "no existe la tarea $ID"
  # Última barrera: nunca se borra nada que no esté DENTRO de la carpeta de trabajos.
  case "$(cd "$T" && pwd -P)/" in "$(cd "$TRABAJOS" && pwd -P)"/?*) ;; *) die "ruta fuera de $TRABAJOS: no se borra" ;; esac
  if [ ! -f "$T/motor" ]; then rm -rf "$T"; echo "router: $ID (informe de revisión) borrado."; exit 0; fi
  [ -f "$T/veredicto" ] || [ "$FORZAR" = 1 ] || die "la tarea $ID no tiene veredicto: dar veredicto (ok, mal o nulo) o usar 'limpiar --forzar $ID'"
  REPO="$(cat "$T/repo" 2>/dev/null)"
  if [ -n "$REPO" ]; then
    git -C "$REPO" worktree remove --force "$T/wt" 2>/dev/null
    if git -C "$REPO" merge-base --is-ancestor "router/$ID" HEAD 2>/dev/null || [ "$FORZAR" = 1 ] || [ "$(cat "$T/veredicto" 2>/dev/null)" != ok ]; then
      git -C "$REPO" branch -D "router/$ID" -q 2>/dev/null
    else
      echo "router: la rama router/$ID no está fusionada; se conserva (bórrala a mano si no la quieres)."
    fi
  fi
  rm -rf "$T"; echo "router: $ID limpiada."
  ;;

resumen)
  # La tabla que se presenta AL TERMINAR un reparto: qué se mandó a cada motor, cuánto tardó y cómo salió
  # la revisión de Claude. Sin argumento, últimas 24 h; o `resumen 72` para 72 h.
  necesita_init
  py "$REGISTRO" "$TRABAJOS" "${1:-24}" <<'EOF'
import json, sys, os, datetime, glob
reg, trab, horas = sys.argv[1], sys.argv[2], float(sys.argv[3])
desde = datetime.datetime.now() - datetime.timedelta(hours=horas)
filas = []
if os.path.exists(reg):
    for l in open(reg):
        if not l.strip(): continue
        x = json.loads(l)
        if x.get("motor") and x.get("resultado") and datetime.datetime.fromisoformat(x["fecha"]) >= desde:
            filas.append(x)
cel = lambda t: (t or "—").replace("|", "/")
def corto(t, n=90):   # primera frase, máximo n caracteres: la tabla se lee de un vistazo
    t = (t or "").split(". ")[0].strip()
    return (t[: n - 1].rstrip() + "…") if len(t) > n else t
seg = lambda s: "—" if s is None else (f"{s} s" if s < 120 else f"{s // 60} min")
print(f"Reparto de las últimas {horas:g} h\n")
if filas:
    print("| Tarea | Motor | Qué se le mandó | Ficheros | Tiempo | Revisión de Claude |")
    print("|---|---|---|---|--:|---|")
    for x in filas:
        v = {"ok": "✅ bien", "mal": "❌ mal", "nulo": "⚪ no llegó a trabajar"}.get(x["resultado"], x["resultado"])
        if x.get("motivo"): v += f": {x['motivo']}"
        print(f"| {cel(x['id'])} | {x['motor']} | {cel(corto(x.get('objetivo')))} | {cel(x.get('ficheros'))} | {seg(x.get('segundos'))} | {cel(v)} |")
    ok = sum(x["resultado"] == "ok" for x in filas); mal = sum(x["resultado"] == "mal" for x in filas)
    print(f"\n{ok} bien · {mal} mal · {len(filas) - ok - mal} sin trabajar · {len(filas)} en total")
else:
    print("Ninguna tarea con veredicto en ese periodo.")
pend = [os.path.basename(d) for d in glob.glob(os.path.join(trab, "*")) if os.path.exists(os.path.join(d, "motor")) and not os.path.exists(os.path.join(d, "veredicto"))]
if pend: print("\nSin veredicto todavía (Claude debe revisarlas): " + ", ".join(sorted(pend)))
EOF
  ;;

revisar|adversarial)
  # Segunda opinión de otro fabricante. Codex corre SIN permiso de escritura (no puede cambiar tu repo).
  # No sustituye la revisión de Claude; va antes, y es barata. OJO: «sin escritura» no es «sin lectura»:
  # Codex puede leer archivos de tu disco y lo que lee puede ir a OpenAI. No lo uses en repos con datos que no deban salir.
  necesita_init
  [ $# -ge 1 ] || die "uso: $cmd <repo> [base|--sin-commit]"
  [ "$(activo codex)" = "si" ] || die "codex no está activo (o el router está apagado)"
  command -v codex >/dev/null || die "Codex CLI no instalado (npm i -g @openai/codex && codex login)"
  REPO="$(cd "$1" 2>/dev/null && pwd -P)" || die "no existe la carpeta $1"; BASE="${2:-main}"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO no es un repo git"
  T="$TRABAJOS/$cmd-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$T"
  if [ "$cmd" = revisar ]; then
    if [ "$BASE" = --sin-commit ]; then QUE=(--uncommitted); else QUE=(--base "$BASE"); fi
    con_tope 900 codex exec -C "$REPO" -s read-only --ephemeral review "${QUE[@]}" -o "$T/informe.md" < /dev/null > "$T/log.txt" 2>&1
  else
    if [ "$BASE" = --sin-commit ]; then DIFF=$(git -C "$REPO" diff HEAD); else DIFF=$(git -C "$REPO" diff "$BASE...HEAD"); fi
    [ -n "$DIFF" ] || die "no hay cambios que revisar contra $BASE"
    printf '%s' "$DIFF" | con_tope 900 codex exec -C "$REPO" -s read-only --ephemeral \
      -o "$T/informe.md" "$(cat "$SKILL_DIR/plantillas/adversarial.md")" > "$T/log.txt" 2>&1
  fi
  RC=$?
  echo "router: $cmd terminado (rc=$RC). Informe: $T/informe.md"
  [ "$RC" -ne 0 ] && echo "router: *** Codex terminó con error (rc=$RC): mira $T/log.txt; el informe puede estar vacío. ***"
  echo "router: Claude lo lee y decide qué hallazgos son reales; ninguno se aplica sin comprobarlo. (Se borra con: router.sh limpiar $(basename "$T"))"
  ;;

cupo)
  # Serie para correlacionar el % real de tu cupo semanal con el reparto de uso por modelo.
  # Con argumento: tú tecleas el % que ves en /usage. Sin argumento: lo lee de ROUTER_CUPO_FILE
  # (lo escribe tu barra de estado; ver referencias/cupo-barra.md).
  necesita_init
  if [ $# -ge 1 ]; then PCT="$1"; CINCO=null; RESET=null
  elif [ -f "$CUPO_FILE" ]; then
    [ -n "$(find "$CUPO_FILE" -mmin -1560 2>/dev/null)" ] || die "$CUPO_FILE tiene más de 26 h (sin sesión abierta): dato viejo, no se apunta"
    IFS='|' read -r PCT CINCO RESET < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = lambda k: "null" if d.get(k) is None else d[k]
print(f"{v(\"siete_d\")}|{v(\"cinco_h\")}|{v(\"reset_7d\")}")' "$CUPO_FILE") || die "no se pudo leer $CUPO_FILE"
  else die "uso: cupo <pct-semanal>  (o configura la barra de estado: referencias/cupo-barra.md)"; fi
  case "$PCT" in ''|null|*[!0-9.]*) die "pct no válido: $PCT" ;; esac
  REPARTO=$(python3 "$SKILL_DIR/scripts/cupo.py" 7) || die "no se pudo calcular el reparto"
  py "$REGISTRO" "$PCT" "$CINCO" "$RESET" "$REPARTO" <<'EOF'
import json, sys, datetime
r, pct, cinco, reset, rep = sys.argv[1:6]
def num(x):
    try: return float(x)
    except ValueError: return None
reg = {"tipo": "cupo", "fecha": datetime.datetime.now().isoformat(timespec="microseconds"),
       "pct_7d": float(pct), "pct_5h": num(cinco), "reset_7d": None if reset == "null" else reset, **json.loads(rep)}
open(r, "a").write(json.dumps(reg, ensure_ascii=False) + "\n")
print(f"router: cupo apuntado: semanal={pct} % · Opus {reg['pct_salida_opus']} % de la salida · contexto medio {reg['contexto_medio_por_llamada']:,} tok/llamada")
EOF
  ;;

informe)
  necesita_init
  py "$REGISTRO" <<'EOF'
import json, sys, os
filas = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and '"tipo": "cupo"' in l] if os.path.exists(sys.argv[1]) else []
if not filas: print("router: sin datos de cupo todavía (router.sh cupo)."); sys.exit()
print(f"{'fecha':<20}{'sem. %':>7}{'Opus %':>8}{'llamadas':>10}{'ctx medio':>11}{'salida Opus M':>15}")
for f in filas:
    op = sum(v["salida"] for k, v in f["por_modelo"].items() if "opus" in k) / 1e6
    print(f"{f['fecha']:<20}{f['pct_7d']:>7}{f['pct_salida_opus']:>8}{f['llamadas']:>10}{f['contexto_medio_por_llamada']:>11,}{op:>15.2f}")
EOF
  ;;

apagar)
  mkdir -p "$HOME_R"; touch "$HOME_R/APAGADO" && echo "router: APAGADO. Codex y GLM no reciben nada; Claude lo hace todo (como antes del router). Los datos y el registro se conservan. Volver: router.sh encender"
  ;;

encender)
  rm -f "$HOME_R/APAGADO" && echo "router: ENCENDIDO. Vuelve a repartir según los motores activos (router.sh estado)."
  ;;

activar)
  necesita_init; [ $# -ge 1 ] || die "uso: activar <motor>"
  cambiar_activo "$1" true "" && registrar_activacion "$1" && echo "router: $1 activo (la regla de las $STRIKES cuenta de cero desde ahora)."
  ;;
desactivar) necesita_init; [ $# -ge 2 ] || die "uso: desactivar <motor> \"motivo\""; cambiar_activo "$1" false "$2" && echo "router: $1 fuera." ;;

*) die "comando desconocido: $cmd (init | estado | validar | regla | lanzar | veredicto | limpiar | resumen | revisar | adversarial | cupo | informe | apagar | encender | activar | desactivar)" ;;
esac
