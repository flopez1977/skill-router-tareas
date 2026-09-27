#!/bin/bash
# router.sh — reparte una tarea ya definida a otro motor (Codex o GLM) en una copia aislada
# del repo (git worktree) y lleva la cuenta de cómo sale cada motor.
#
# Quién decide QUÉ se reparte: Claude, con las reglas de SKILL.md. Este script solo
# ejecuta, aísla y apunta. Claude revisa SIEMPRE el resultado antes de aceptarlo.
#
#   router.sh init [codex,glm|codex|glm|ninguno] # crea ~/.router-tareas; activa solo los motores que tengas
#   router.sh estado
#   router.sh lanzar <motor> <repo> <id-tarea> <fichero-prompt> [minutos-tope]
#   router.sh veredicto <id-tarea> ok|mal "<motivo>"
#   router.sh limpiar <id-tarea>
#   router.sh activar <motor>
#   router.sh desactivar <motor> "<motivo>"
#
# Variables de entorno (todas opcionales):
#   ROUTER_HOME          dónde vive el estado (por defecto ~/.router-tareas)
#   ROUTER_STRIKES       «mal» que sacan a un motor (por defecto 3)
#   ROUTER_VENTANA_DIAS  ventana en la que se cuentan (por defecto 30)
#   ZAI_API_KEY          clave de z.ai para GLM, o bien:
#   ROUTER_GLM_KEY_CMD   comando que imprime la clave (p. ej. un gestor de contraseñas);
#                        la clave solo se pasa al proceso hijo, nunca se imprime
#   ROUTER_GLM_MODEL     modelo de GLM (por defecto glm-5.3)
#   ROUTER_GLM_URL       endpoint compatible con Anthropic (por defecto el de z.ai)

set -uo pipefail

HOME_R="${ROUTER_HOME:-$HOME/.router-tareas}"
MOTORES="$HOME_R/motores.json"
REGISTRO="$HOME_R/registro.jsonl"
TRABAJOS="$HOME_R/trabajos"
STRIKES="${ROUTER_STRIKES:-3}"
VENTANA_DIAS="${ROUTER_VENTANA_DIAS:-30}"
GLM_MODEL="${ROUTER_GLM_MODEL:-glm-5.3}"
GLM_URL="${ROUTER_GLM_URL:-https://api.z.ai/api/anthropic}"

die() { echo "router: $*" >&2; exit 1; }
py() { python3 - "$@"; }
con_tope() { perl -e 'alarm shift; exec @ARGV' "$@"; } # macOS no trae `timeout`

necesita_init() { [ -f "$MOTORES" ] || die "sin configurar: ejecuta 'router.sh init'"; }

activo() {
  py "$MOTORES" "$1" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))["motores"].get(sys.argv[2])
print("si" if m and m.get("activo") else "no")
EOF
}

registrar() {
  py "$REGISTRO" "$@" <<'EOF'
import json, sys, datetime
_, f, id_, motor, res, motivo = sys.argv
with open(f, "a") as fh:
    fh.write(json.dumps({"fecha": datetime.datetime.now().isoformat(timespec="seconds"),
                         "id": id_, "motor": motor, "resultado": res, "motivo": motivo}, ensure_ascii=False) + "\n")
EOF
}

cambiar_activo() {
  py "$MOTORES" "$@" <<'EOF'
import json, sys, datetime
f, motor, valor, motivo = sys.argv[1], sys.argv[2], sys.argv[3] == "true", sys.argv[4]
d = json.load(open(f))
if motor not in d["motores"]: sys.exit(f"motor desconocido: {motor}")
d["motores"][motor]["activo"] = valor
if valor: d["desactivados"].pop(motor, None)
else: d["desactivados"][motor] = {"fecha": datetime.date.today().isoformat(), "motivo": motivo}
json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
EOF
}

clave_glm() {
  if [ -n "${ZAI_API_KEY:-}" ]; then printf '%s' "$ZAI_API_KEY"
  elif [ -n "${ROUTER_GLM_KEY_CMD:-}" ]; then eval "$ROUTER_GLM_KEY_CMD"
  else return 1; fi
}

cmd="${1:-estado}"; shift || true
case "$cmd" in

init)
  # Motores con suscripción, separados por comas: "codex", "glm", "codex,glm" o "ninguno".
  # Los que no estén en la lista quedan creados pero FUERA, para activarlos el día que se tengan.
  CON="${1:-codex,glm}"
  mkdir -p "$TRABAJOS"
  if [ -f "$MOTORES" ]; then echo "router: ya configurado en $HOME_R (router.sh activar/desactivar para cambiarlo)"; exit 0; fi
  cat > "$MOTORES" <<'EOF'
{
  "comentario": "activo=false saca el motor del reparto. N veredictos 'mal' en la ventana lo desactivan solo. Reactivar a mano: router.sh activar <motor>.",
  "motores": {
    "codex": {
      "activo": true,
      "para": "implementacion acotada con tests; segunda opinion adversarial"
    },
    "glm": {
      "activo": true,
      "para": "trabajo mecanico en volumen: renombrados, codigo repetitivo, migrar formatos, tests simples, documentar codigo"
    }
  },
  "desactivados": {}
}
EOF
  for m in codex glm; do
    case ",$CON," in *",$m,"*) ;; *) cambiar_activo "$m" false "sin suscripción al configurar" ;; esac
  done
  echo "router: configurado en $HOME_R"
  "$0" estado
  ;;

estado)
  necesita_init
  py "$MOTORES" "$REGISTRO" "$VENTANA_DIAS" <<'EOF'
import json, sys, datetime, os
d = json.load(open(sys.argv[1])); dias = int(sys.argv[3])
regs = [json.loads(l) for l in open(sys.argv[2])] if os.path.exists(sys.argv[2]) else []
desde = datetime.datetime.now() - datetime.timedelta(days=dias)
for n, m in d["motores"].items():
    r = [x for x in regs if x["motor"] == n and datetime.datetime.fromisoformat(x["fecha"]) >= desde]
    ok = sum(x["resultado"] == "ok" for x in r); mal = sum(x["resultado"] == "mal" for x in r)
    est = "ACTIVO" if m["activo"] else f"FUERA ({d['desactivados'].get(n, {}).get('motivo', '')})"
    print(f"{n:6} {est:40} últimos {dias} días: {ok} bien · {mal} mal · para: {m['para']}")
if not any(m["activo"] for m in d["motores"].values()):
    print("\nNingún motor activo: todas las tareas las hace Claude (el router no reparte nada).")
EOF
  ;;

lanzar)
  necesita_init
  [ $# -ge 4 ] || die "uso: lanzar <motor> <repo> <id-tarea> <fichero-prompt> [minutos-tope]"
  MOTOR="$1"; REPO="$(cd "$2" && pwd)"; ID="$3"; PROMPT_F="$4"; MIN="${5:-30}"
  [ "$(activo "$MOTOR")" = "si" ] || die "el motor '$MOTOR' no está activo (router.sh estado)"
  [ -f "$PROMPT_F" ] || die "no existe el fichero de prompt $PROMPT_F"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO no es un repo git"
  [[ "$ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "id de tarea inválido (solo letras, números, . _ -)"
  if [ "$MOTOR" = glm ]; then clave_glm >/dev/null 2>&1 || die "falta la clave de GLM: ZAI_API_KEY o ROUTER_GLM_KEY_CMD"; fi
  T="$TRABAJOS/$ID"; WT="$T/wt"
  [ -e "$T" ] && die "ya existe la tarea $ID (limpiar antes)"
  mkdir -p "$T"
  git -C "$REPO" worktree add -q "$WT" -b "router/$ID" HEAD || die "no se pudo crear el worktree"
  # Nada de secretos en lo que ve el otro motor: si hay ficheros sensibles TRACKEADOS, no se lanza.
  SENS=$(git -C "$WT" ls-files | grep -Ei '(^|/)(\.env[^/]*|.*\.pem|.*\.key|id_rsa.*|id_ed25519.*|credentials[^/]*|.*secret[^/]*)$' | grep -viE '\.example$|\.sample$' | head -5)
  if [ -n "$SENS" ]; then
    git -C "$REPO" worktree remove --force "$WT"; git -C "$REPO" branch -D "router/$ID" -q; rm -rf "$T"
    die "el repo tiene ficheros sensibles trackeados, no se reparte: $SENS"
  fi
  cp "$PROMPT_F" "$T/prompt.md"; echo "$MOTOR" > "$T/motor"; echo "$REPO" > "$T/repo"
  SEG=$((MIN * 60)); INICIO=$(date +%s)
  echo "router: $ID → $MOTOR en $WT (tope $MIN min)…"
  case "$MOTOR" in
    codex)
      command -v codex >/dev/null || die "Codex CLI no instalado (npm i -g @openai/codex && codex login)"
      con_tope "$SEG" codex exec -C "$WT" -s workspace-write --ephemeral \
        -o "$T/resultado.md" "$(cat "$T/prompt.md")" > "$T/log.txt" 2>&1
      RC=$? ;;
    glm)
      command -v claude >/dev/null || die "Claude Code no instalado"
      ( cd "$WT" && unset ANTHROPIC_API_KEY
        ANTHROPIC_AUTH_TOKEN="$(clave_glm)" ANTHROPIC_BASE_URL="$GLM_URL" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="$GLM_MODEL" ANTHROPIC_DEFAULT_SONNET_MODEL="$GLM_MODEL" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$GLM_MODEL" \
        con_tope "$SEG" claude -p "$(cat "$T/prompt.md")" --permission-mode acceptEdits \
          --allowedTools "Read,Edit,Write,Glob,Grep,Bash(npm test:*),Bash(npx:*),Bash(node:*),Bash(python3:*),Bash(pytest:*),Bash(php:*),Bash(git diff:*),Bash(git status:*)" \
          > "$T/resultado.md" 2> "$T/log.txt" )
      RC=$? ;;
    *) die "motor sin lanzador en este script: $MOTOR (añádelo en el case de 'lanzar')" ;;
  esac
  echo $(( $(date +%s) - INICIO )) > "$T/segundos"
  echo "router: $MOTOR terminó (rc=$RC, $(cat "$T/segundos") s). Cambios:"
  # Lo que genera la ejecución (cachés, dependencias) no es un cambio del motor.
  git -C "$WT" add -A -- . ':(exclude,glob)**/__pycache__/**' ':(exclude,glob)**/.pytest_cache/**' \
    ':(exclude,glob)**/node_modules/**' ':(exclude,glob)**/*.pyc' >/dev/null 2>&1
  git -C "$WT" diff --cached --stat HEAD | tail -15
  echo "router: AHORA Claude revisa el diff, pasa los tests él mismo y da veredicto:"
  echo "        router.sh veredicto $ID ok|mal \"motivo\""
  ;;

veredicto)
  necesita_init
  [ $# -ge 2 ] || die "uso: veredicto <id-tarea> ok|mal \"motivo\""
  ID="$1"; RES="$2"; MOT="${3:-}"; T="$TRABAJOS/$ID"
  [ -d "$T" ] || die "no existe la tarea $ID"
  [[ "$RES" == ok || "$RES" == mal ]] || die "veredicto: ok o mal"
  [ "$RES" = mal ] && [ -z "$MOT" ] && die "un 'mal' necesita motivo"
  MOTOR="$(cat "$T/motor")"
  registrar "$ID" "$MOTOR" "$RES" "$MOT"; echo "$RES" > "$T/veredicto"
  if [ "$RES" = mal ]; then
    N=$(py "$REGISTRO" "$MOTOR" "$VENTANA_DIAS" <<'EOF'
import json, sys, datetime
desde = datetime.datetime.now() - datetime.timedelta(days=int(sys.argv[3]))
print(sum(1 for l in open(sys.argv[1]) for x in [json.loads(l)]
          if x["motor"] == sys.argv[2] and x["resultado"] == "mal" and datetime.datetime.fromisoformat(x["fecha"]) >= desde))
EOF
)
    echo "router: $MOTOR lleva $N «mal» en $VENTANA_DIAS días."
    if [ "$N" -ge "$STRIKES" ]; then
      cambiar_activo "$MOTOR" false "$N veredictos «mal» en $VENTANA_DIAS días (último: $MOT)"
      echo "router: *** $MOTOR DESACTIVADO (regla de las $STRIKES). Se reactiva a mano: router.sh activar $MOTOR ***"
    fi
  fi
  ;;

limpiar)
  necesita_init
  [ $# -ge 1 ] || die "uso: limpiar <id-tarea>"
  ID="$1"; T="$TRABAJOS/$ID"; [ -d "$T" ] || die "no existe la tarea $ID"
  [ -f "$T/veredicto" ] || die "la tarea $ID no tiene veredicto: dar veredicto antes de limpiar"
  REPO="$(cat "$T/repo")"
  git -C "$REPO" worktree remove --force "$T/wt" 2>/dev/null
  if git -C "$REPO" merge-base --is-ancestor "router/$ID" HEAD 2>/dev/null || [ "$(cat "$T/veredicto")" = mal ]; then
    git -C "$REPO" branch -D "router/$ID" -q 2>/dev/null
  else
    echo "router: la rama router/$ID no está fusionada; se conserva (bórrala a mano si no la quieres)."
  fi
  rm -rf "$T"; echo "router: $ID limpiada."
  ;;

activar)    necesita_init; [ $# -ge 1 ] || die "uso: activar <motor>"; cambiar_activo "$1" true "" && echo "router: $1 activo." ;;
desactivar) necesita_init; [ $# -ge 2 ] || die "uso: desactivar <motor> \"motivo\""; cambiar_activo "$1" false "$2" && echo "router: $1 fuera." ;;

*) die "comando desconocido: $cmd (init | estado | lanzar | veredicto | limpiar | activar | desactivar)" ;;
esac
